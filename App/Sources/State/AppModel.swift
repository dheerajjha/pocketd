import Foundation
import LocalLLMClient
import Observation
import PocketdKit
import SwiftUI

@MainActor
@Observable
final class AppModel {
    // MARK: Server

    private(set) var serverState: InferenceServer.State = .stopped
    private(set) var log: [RequestLogEntry] = []
    private(set) var pairing = PairingSession.Snapshot()
    private(set) var condition: ServeCondition = .ok
    /// A dimmed, burn-in-safe screen for a phone left serving on a desk. The
    /// display draws from the same thermal and power budget as the GPU, so a
    /// bright screen literally costs tokens per second.
    /// Deliberately NOT persisted. Desk mode hides the tab bar, the status bar
    /// and the home indicator, so restoring it on launch means the app opens on
    /// a black screen with no visible way out — and force-quitting, the one
    /// recovery every user knows, lands you straight back in it.
    var deskMode = false
    var configuration: ServerConfiguration {
        didSet { persistConfiguration() }
    }

    /// What the user asked for, as distinct from what the socket is doing.
    /// iOS tears the listener down on suspend, so the two diverge constantly and
    /// only this flag knows whether to put it back on the next foreground.
    private(set) var serverShouldRun = false
    private(set) var lastServerError: String?

    // MARK: Models

    private(set) var installed: [ModelRecord] = []

    /// Every model arriving on this phone, keyed by id, with the record.
    ///
    /// One dictionary rather than the three it replaced — progress, error and
    /// paused, each keyed by an id and none of them holding the model. That
    /// shape worked only because the eight curated records are compiled into
    /// the binary and could be looked up by id later. Anything from Hugging
    /// Face has no such entry, so a search download was an id with no record,
    /// and every screen here builds its list out of records. The bytes moved
    /// for minutes and not one pixel changed.
    private(set) var transfers: [String: ModelTransfer] = [:]

    /// A model that is on disk and would not load.
    ///
    /// Separate from a transfer's `.failed`, because they are separate
    /// failures with separate fixes: one means download it again, the other
    /// means this phone cannot hold it. They shared a dictionary before and
    /// the row said "download failed" about a download that had succeeded.
    private(set) var loadErrors: [String: String] = [:]

    private(set) var loadedModelID: String?
    private(set) var isLoadingModel = false
    /// Varies with the context limit: what fits depends on how much KV cache
    /// the served context will demand, so this is not a constant of the device.
    private(set) var budget: DeviceBudget

    /// The curated catalogue plus anything actually on this phone.
    ///
    /// These are not the same set and treating them as one list was a real
    /// bug: `/api/models/add` can pull any GGUF on Hugging Face, it lands in
    /// the manifest, and the Models tab — which iterated the static catalogue —
    /// never showed it. The download worked and the model was invisible.
    /// Curated entries win on id so a catalogue model that has been
    /// downloaded keeps its curated name and description.
    ///
    /// Models still arriving are in here too. They were not, and that is the
    /// whole reason a Hugging Face download had no row to draw its progress
    /// in: the row is built from this list, and this list only knew about
    /// things that were finished or compiled in.
    var catalog: [ModelRecord] {
        ModelCatalog.listing(
            installed: installed,
            transferring: transfers.values
                .map(\.record)
                .sorted { $0.displayName < $1.displayName }
        )
    }

    func transfer(for id: String) -> ModelTransfer? { transfers[id] }

    // MARK: Analytics consent

    /// Whether anonymous usage counts may be sent, as decided by the person
    /// holding the phone.
    ///
    /// Starts `.undecided` and stays there until someone is actually shown the
    /// sentence explaining it, which happens on the third onboarding screen.
    /// Nothing is sent while undecided — so a user who taps Skip before
    /// reaching that screen produces no analytics at all, which is the correct
    /// outcome even though it costs us the data.
    private(set) var analyticsConsent: AnalyticsConsent = {
        let stored = UserDefaults.standard.string(forKey: Keys.analyticsConsent)
        return stored.flatMap(AnalyticsConsent.init(rawValue:)) ?? .undecided
    }()

    func setAnalyticsConsent(_ consent: AnalyticsConsent) {
        guard consent != analyticsConsent else { return }
        analyticsConsent = consent
        UserDefaults.standard.set(consent.rawValue, forKey: Keys.analyticsConsent)
        // Refusing has to do more than stop the tap. Anything queued and not
        // yet flushed goes, and the identifier with it.
        if !consent.permitsSending { analytics.stopAndForget() }
    }

    /// Where events go.
    ///
    /// Constructed here rather than injected because there is nothing left to
    /// choose between: this is the app, and usage counts are part of it rather
    /// than a setting inside it. `NoAnalytics` is still what every test sees,
    /// and it is still a type with no code capable of transmitting rather than
    /// a flag that says not to — which is why the package's suite cannot reach
    /// a real project even by accident.
    private(set) var analytics: any AnalyticsSink = MixpanelAnalytics()

#if DEBUG
    /// Seeds transfer states for previews.
    ///
    /// The banner has six states and most of them are hard to reach on
    /// demand: waiting lasts a second, stopping a little longer, finished six,
    /// and paused and failed need a network that misbehaves on cue. A preview
    /// is how you look at all of them before a user does.
    func previewSeed(_ seeded: [ModelTransfer]) {
        transfers = Dictionary(uniqueKeysWithValues: seeded.map { ($0.id, $0) })
    }
#endif

    /// What the banner above the tabs should be showing, in a stable order.
    ///
    /// Active first: a download in progress outranks a notice about one that
    /// finished, and the order must not depend on dictionary iteration or the
    /// banner swaps rows at random while someone is reading it.
    var visibleTransfers: [ModelTransfer] {
        transfers.values
            .filter { !dismissedDownloads.contains($0.id) && $0.isWorthShowing() }
            .sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                return $0.record.displayName < $1.record.displayName
            }
    }

    // MARK: Chat

    var conversation: [ChatMessage] = []
    var draft = ""
    private(set) var isGenerating = false
    var systemPrompt: String = "You are a helpful assistant." {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Keys.systemPrompt) }
    }

    // MARK: Internals

    private let store: ModelStore
    private let configurationStore: ServerConfigurationStore
    private let engine: LlamaEngine
    private let server: InferenceServer
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// One per finished transfer, counting down its completion notice.
    private var noticeTimers: [String: Task<Void, Never>] = [:]
    private var generationTask: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []
    private let bonjour = BonjourAdvertiser()
    private var governor: DeviceGovernor?

    /// When the listener came up, for the served seconds `serverStopped`
    /// carries. Nil whenever this app is not the one serving.
    ///
    /// Deliberately not "when the app was opened". iOS closes the socket on
    /// suspend without telling anyone, so the two clocks differ by every minute
    /// the phone spent in a pocket, and only one of them is about the product.
    private var servingSince: Date?

    private enum Keys {
        static let loadedModel = "pocketd.loadedModel"
        static let systemPrompt = "pocketd.systemPrompt"
        static let serverShouldRun = "pocketd.serverShouldRun"
        static let autoOffloadInBackground = "pocketd.autoOffloadInBackground"
        static let idleOffloadSeconds = "pocketd.idleOffloadSeconds"
        static let calendarTools = "pocketd.calendarTools"
        static let reminderTools = "pocketd.reminderTools"
        /// The switch that governed both of the two above. Read once, at the
        /// first launch of a build that has them, and removed on the spot —
        /// nothing writes it any more. See `PersonalDataToolsMigration`.
        static let legacyPersonalDataTools = "pocketd.personalDataTools"
        static let healthTools = "pocketd.healthTools"
        static let completedOnboarding = "pocketd.completedOnboarding"
        static let analyticsConsent = "pocketd.analyticsConsent"
    }

    init() {
        // The configuration comes first because the memory budget depends on
        // it: how much KV cache a model needs is set by the context this
        // server creates, so "will it fit" cannot be answered until the served
        // context is known.
        //
        // load() persists a freshly generated configuration on the spot.
        // Relying on the didSet below would not: property observers do not run
        // during initialisation, so the API key would be new on every launch.
        let configurationStore = ServerConfigurationStore()
        self.configurationStore = configurationStore
        let configuration = configurationStore.load()
        self.configuration = configuration

        let budget = DeviceBudget.current(
            hasIncreasedMemoryLimit: Entitlements.hasIncreasedMemoryLimit,
            servedContextTokens: configuration.maxContextTokens
        )
        self.budget = budget

        let directory = (try? ModelStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Models")
        let store = ModelStore(directory: directory, budget: budget)
        self.store = store

        self.conversations = ConversationStore(
            directory: (try? ConversationStore.defaultDirectory())
                ?? directory.appendingPathComponent("Conversations")
        )

        // Read before the engine exists rather than from the stored properties,
        // because property observers do not run during initialisation: reading
        // `calendarToolsEnabled` here would see its declared default and launch
        // with the tools off for someone who turned them on.
        //
        // `object(forKey:)` and not `bool(forKey:)` for the three that feed the
        // migration: it needs "never written" and `false` to be different
        // answers, and `bool(forKey:)` collapses them into one. Health is not
        // in the migration and keeps the simpler read.
        let defaults = UserDefaults.standard
        let personalData = PersonalDataToolsMigration.resolve(
            .init(
                legacy: defaults.object(forKey: Keys.legacyPersonalDataTools) as? Bool,
                calendar: defaults.object(forKey: Keys.calendarTools) as? Bool,
                reminders: defaults.object(forKey: Keys.reminderTools) as? Bool
            )
        )
        if personalData.shouldPersist {
            // The removal last. Either write failing on its own leaves the old
            // key as the answer, which is recoverable; losing it first leaves
            // an upgraded user with no answer at all.
            defaults.set(personalData.calendar, forKey: Keys.calendarTools)
            defaults.set(personalData.reminders, forKey: Keys.reminderTools)
            defaults.removeObject(forKey: Keys.legacyPersonalDataTools)
        }
        let healthEnabled = defaults.bool(forKey: Keys.healthTools)
        let engine = LlamaEngine(
            fileURL: { store.fileURL(for: $0) },
            projectorURL: { store.projectorURL(for: $0) },
            tools: Self.registrations(
                calendar: personalData.calendar,
                reminders: personalData.reminders,
                health: healthEnabled
            ),
            exempt: Self.selfTestTools()
        )
        self.engine = engine

        self.server = InferenceServer(
            configuration: configuration,
            engine: engine,
            models: { await store.installed() },
            puller: { record in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            for try await progress in await store.download(record) {
                                continuation.yield(progress)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            deviceBudget: budget
        )

        systemPrompt = UserDefaults.standard.string(forKey: Keys.systemPrompt) ?? systemPrompt
        serverShouldRun = UserDefaults.standard.bool(forKey: Keys.serverShouldRun)
        // `object(forKey:)` rather than `bool(forKey:)`: an absent key reads as
        // false, which would turn the default off for everyone who has never
        // touched the switch.
        autoOffloadInBackground = UserDefaults.standard.object(forKey: Keys.autoOffloadInBackground) as? Bool ?? true
        idleOffloadSeconds = UserDefaults.standard.integer(forKey: Keys.idleOffloadSeconds)
        calendarToolsEnabled = personalData.calendar
        reminderToolsEnabled = personalData.reminders
        healthToolsEnabled = healthEnabled
    }

    func bootstrap() async {
        let governor = DeviceGovernor(
            batteryFloor: configuration.pauseBelowBatteryLevel,
            tolerance: configuration.thermalTolerance
        ) { [weak self] condition in
            guard let self else { return }
            self.condition = condition
            Task { await self.server.setCondition(condition) }
        }
        self.governor = governor
        governor.start()

        await store.load()
        await engine.updateDefaultSampling(configuration.sampling)
        installed = await store.installed()
        settleOnboardingForExistingInstall()

        // After the onboarding flag has been settled, not before. That flag is
        // the trace an earlier build leaves behind, and it is the only thing
        // separating a genuinely new install from someone updating into the
        // first version that had any analytics in it. Recorded a line earlier,
        // every existing user reports a first launch on release day.
        analytics.record(.appOpened(
            isFirstLaunch: FirstLaunch.claim(evidenceOfPriorUse: hasCompletedOnboarding)
        ))

        // Reopen what was on screen last time. Coming back to a blank Chat tab
        // after a force-quit reads as data loss even when the transcript is
        // safely on disk one tap away in the history.
        await loadHistory()
        if let latest = history.first {
            conversation = latest.messages
            draft = latest.draft
            currentConversationID = latest.id
            conversationStartedAt = latest.createdAt
        }

        // Driving the idle timer from the observer is what also catches the
        // transitions the app did not initiate — a failed bind, or iOS
        // reclaiming the socket.
        observers.append(Task { [server] in
            for await state in await server.stateStream() {
                await MainActor.run {
                    self.serverState = state
                    self.applyIdleTimer(running: state.isRunning)
                }
            }
        })
        observers.append(Task { [server] in
            for await snapshot in await server.pairing.stream() {
                await MainActor.run { self.pairing = snapshot }
            }
        })
        observers.append(Task { [server, engine] in
            for await entries in await server.log.stream() {
                // The server loads models behind the app's back when a request
                // names one that is not resident, so the badge and the Chat tab
                // would otherwise keep pointing at a model that is gone.
                let resident = await engine.loadedModel()?.id
                await MainActor.run {
                    self.log = entries
                    // Not user-initiated: this fires because some client asked
                    // for a different model.
                    self.syncLoadedModel(resident, userInitiated: false)
                }
            }
        })

        // Genuinely the previously loaded model. This used to take
        // `installed.first`, which is the alphabetically first — so downloading
        // one model to try it meant every later launch quietly loaded that one
        // instead, and wiped the chat on the way.
        // Falls back rather than giving up. A remembered model can stop being
        // loadable — a vision model on a simulator, a file that went missing —
        // and sitting with nothing resident means every request 404s while the
        // Models tab shows a perfectly healthy row. Found by accidentally
        // leaving a vision model remembered and watching the app come up empty.
        let remembered = UserDefaults.standard.string(forKey: Keys.loadedModel)
        var candidates = installed
        if let id = remembered, let index = candidates.firstIndex(where: { $0.id == id }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        for candidate in candidates {
            await loadModel(candidate, remember: false)
            if loadedModelID != nil { break }
        }
        if serverShouldRun {
            await startServer()
        }
    }

    // MARK: - Server control

    func startServer() async {
        serverShouldRun = true
        UserDefaults.standard.set(true, forKey: Keys.serverShouldRun)
        lastServerError = nil
        do {
            try await server.apply(configuration)
            try await server.start()
            servingSince = Date()
            // On this line and not at the top of the method, because a bind
            // that fails throws above: a port already in use would otherwise be
            // counted as the server having started. The count does include the
            // restart after every suspension — iOS closes the socket without
            // telling anyone and `reconcileAfterForeground` puts it back — and
            // "the listener came up" is what this event honestly means.
            analytics.record(.serverStarted)
            // A code is only worth showing until someone has used one. After
            // that the laptop has the key and the phone should stop displaying
            // six digits it no longer needs.
            if await server.pairing.snapshot().hasPaired == false {
                await server.openPairing()
            }
            await advertise()
        } catch {
            lastServerError = friendlyMessage(for: error)
        }
    }

    func stopServer() async {
        serverShouldRun = false
        UserDefaults.standard.set(false, forKey: Keys.serverShouldRun)
        // Only where this app is the one ending it. A suspension kills the
        // listener without running this method, so a stop recorded later would
        // be measured across hours of a phone in a pocket — app-open time,
        // which `serverStopped` documents itself as deliberately not being.
        // The price is that starts outnumber stops, and the difference is
        // suspensions rather than anything anyone did.
        if let since = servingSince {
            analytics.record(.serverStopped(servedSeconds: Date().timeIntervalSince(since)))
            servingSince = nil
        }
        await server.stop()
        await server.closePairing()
        bonjour.stop()
    }

    /// Called on every return to the foreground. iOS closes the listening socket
    /// when the app suspends without telling anyone, so the only correct thing to
    /// do is re-establish it and let the user see the address again.
    func reconcileAfterForeground() async {
        guard serverShouldRun else { return }
        // liveState() reconciles against the socket. currentState() would report
        // the `.running` we last wrote, which is exactly the stale value this
        // method exists to repair — it would early-return in the only case that
        // matters.
        if await server.liveState().isRunning {
            applyIdleTimer(running: true)
            return
        }
        await server.stop()   // release any half-dead socket and reset admission counters
        await startServer()
    }

    func applyConfiguration(_ new: ServerConfiguration) async {
        configuration = new
        // The context limit moves the memory ceiling, so every fit badge and
        // the download gate have to be recomputed against the new one.
        governor?.updateThermalTolerance(new.thermalTolerance)
        budget.servedContextTokens = new.maxContextTokens
        await store.updateBudget(budget)
        await engine.updateDefaultSampling(new.sampling)
        do {
            try await server.apply(new)
            lastServerError = nil
        } catch {
            lastServerError = friendlyMessage(for: error)
        }
        governor?.updateBatteryFloor(new.pauseBelowBatteryLevel)
        // Not covered by the observer: toggling keep-awake in Settings produces
        // no server transition, so the new setting would not take hold until the
        // next start or stop.
        applyIdleTimer(running: await server.liveState().isRunning)
        await advertise()
    }

    func clearLog() async {
        await server.log.clear()
    }

    /// Publishes the service once the listener is actually up, so browsers are
    /// never pointed at a port nothing is bound to.
    private func advertise() async {
        guard case let .running(_, port) = await server.liveState() else { return }
        #if canImport(UIKit)
        let name = UIDevice.current.name
        #else
        let name = "Pocketd"
        #endif
        bonjour.start(
            port: port,
            name: name,
            model: loadedModelID,
            requiresAuth: configuration.requiresAuth
        )
    }

    func newPairingCode() async {
        await server.openPairing()
    }

    /// What a laptop should be told to open. The setup path is spelled out
    /// because the bare address answers the Ollama probe string to anything
    /// that is not a browser, and that reads like a broken server.
    var setupURL: URL? {
        guard case let .running(host, port) = serverState else { return nil }
        return URL(string: "http://\(host):\(port)/setup")
    }

    var serverURL: URL? {
        guard case let .running(host, port) = serverState else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    /// `serverState` is a mirror updated asynchronously by the observer, so every
    /// caller that reads it here would set the flag from the pre-transition
    /// value — backwards, every time. Callers pass the truth instead.
    private func applyIdleTimer(running: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = configuration.keepAwakeWhileServing && running
        #endif
    }

    private func persistConfiguration() {
        configurationStore.save(configuration)
    }

    /// Errors reach the Server tab, so they are written for whoever is holding
    /// the phone. The previous version matched on the substring "48" — which
    /// never fired for the case it was written for, because a busy port
    /// surfaces as a five-second timeout rather than EADDRINUSE, and would
    /// false-positive on any error containing those digits.
    private func friendlyMessage(for error: any Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("timed out") || text.contains("timeout") {
            return "Could not start on port \(configuration.port) — nothing answered within five seconds. Another app is probably using it. Try a different port in Settings."
        }
        if text.contains("in use") || text.contains("eaddrinuse") {
            return "Port \(configuration.port) is already in use. Pick another port in Settings."
        }
        if text.contains("permission") || text.contains("denied") {
            return "iOS refused the connection. Check that Local Network access is allowed for Pocketd in the Settings app."
        }
        return "Could not start the server: \(error)"
    }

    // MARK: - Models

    func fit(for model: ModelRecord) -> DeviceBudget.Fit { budget.fit(for: model) }

    func isInstalled(_ model: ModelRecord) -> Bool {
        installed.contains { $0.id == model.id }
    }

    /// What the manifest says is installed, read now rather than remembered.
    ///
    /// `installed` is a snapshot, written at launch and after this app's own
    /// downloads and deletes. A model a paired device pulled over the HTTP API
    /// lands in the manifest and is served by `/v1/models` without ever
    /// touching it, so anything that decides what a file on disk *is* has to
    /// ask the manifest or it will call that model's weights a stray.
    func manifestInstalled() async -> [ModelRecord] {
        await store.installed()
    }

    /// Every model with a transfer running right now, from either door.
    ///
    /// `downloads` holds only what this app's own UI started. `ModelStore` sees
    /// those and the server's pulls, which is why the authoritative answer
    /// comes from there rather than from here.
    func transfersInFlight() async -> Set<String> {
        await store.downloadsInFlight()
    }

    func download(_ model: ModelRecord, allowingOversized: Bool = false) {
        guard downloadTasks[model.id] == nil else { return }
        // Both of these sit after the guard, so a second tap on a download
        // already running is not a second download. A resume is one: it comes
        // back through here, and the pause that preceded it was reported as a
        // failure, so the two sides of the funnel count the same attempts.
        //
        // The override reads the argument rather than the transfer's own flag,
        // which a resume inherits from the attempt before it. What is worth
        // counting is the moment someone was told this model will not fit on
        // their phone and said go ahead anyway, and that only ever arrives
        // through the parameter.
        if allowingOversized { analytics.record(.oversizeOverride(modelID: model.id)) }
        // The total rather than the weights alone: the projector comes down
        // with them, and a vision model without one is a text model. It is the
        // figure `/api/pull` reports, for the same reason.
        analytics.record(.modelDownloadStarted(
            modelID: model.id,
            sizeBytes: model.totalDownloadBytes
        ))
        loadErrors[model.id] = nil
        // A banner hidden during the last attempt should not hide this one.
        dismissedDownloads.remove(model.id)
        // `.waiting`, not zero-of-total. The gap between tapping Download and
        // the first byte is a DNS lookup, a redirect to Hugging Face's CDN and
        // a TLS handshake — a second or two on a phone, longer on a bad
        // network — and a progress bar pinned at 0% for that long is the
        // picture of an app that has hung.
        transfers[model.id] = ModelTransfer(
            record: model,
            state: .waiting,
            // A resume starts from the bytes already on disk, so the bar
            // belongs where the pause left it rather than back at zero.
            lastProgress: transfers[model.id]?.lastProgress,
            allowingOversized: allowingOversized || transfers[model.id]?.allowingOversized == true
        )

        // Monotonic, and scoped to this attempt. A resumed download measures
        // only the leg that finished it, which is the honest number available:
        // counting from the first attempt would include however long the phone
        // spent switched off in between.
        let started = ContinuousClock.now
        downloadTasks[model.id] = Task { [store] in
            do {
                let permitted = await MainActor.run { self.transfers[model.id]?.allowingOversized ?? allowingOversized }
                for try await progress in await store.download(model, allowingOversized: permitted) {
                    await MainActor.run {
                        self.transfers[model.id]?.advance(to: .running(progress))
                        self.recordSample(progress)
                    }
                }
                let list = await store.installed()
                // A stream that ends without throwing is not proof of success.
                // Cancelling this task makes the iterator finish rather than
                // throw, so control reaches here for a download that stopped
                // at three percent — and the old code's only reaction was to
                // clear an invisible progress bar, which hid it. Now that the
                // same line announces "Downloaded", the lie is on screen: Stop
                // on a 3% download said it had finished, offered Load, and the
                // file was 120 MB of a 3.11 GB model.
                //
                // The manifest is the one witness that cannot be wrong about
                // this: `ModelStore` writes an entry only after verifying the
                // bytes on disk against the size that was promised.
                guard list.contains(where: { $0.id == model.id }) else {
                    await MainActor.run {
                        // `cancelDownload` has usually already recorded a pause
                        // with the bytes it kept; anything still calling itself
                        // active here ended for a reason nobody stated.
                        if self.transfers[model.id]?.isActive == true {
                            // A reason nobody stated is still a failure, and it
                            // is the one kind nothing else here can see: the
                            // stream ended without throwing and the bytes are
                            // not in the manifest. Stop has already moved the
                            // transfer out of active by the time it lands here,
                            // so a cancelled download is not also counted as a
                            // failed one.
                            self.analytics.record(.modelDownloadFailed(modelID: model.id, reason: .other))
                            self.transfers[model.id] = nil
                        }
                        self.downloadTasks[model.id] = nil
                        self.clearSamples(model.id)
                    }
                    return
                }
                let shouldLoad = await MainActor.run {
                    self.installed = list
                    // The manifest's record, not the one we started with: the
                    // store verifies the sizes on the way in, and for a search
                    // download those were an API's claim until now.
                    self.transfers[model.id]?.record = list.first { $0.id == model.id } ?? model
                    self.transfers[model.id]?.advance(to: .finished(at: Date()))
                    // On the far side of the manifest check above rather than
                    // where the stream ended, for the reason that check exists:
                    // a stream that finishes without throwing is not proof that
                    // anything arrived.
                    self.analytics.record(.modelDownloadCompleted(
                        modelID: model.id,
                        durationSeconds: started.duration(to: .now) / .seconds(1)
                    ))
                    self.downloadTasks[model.id] = nil
                    self.clearSamples(model.id)
                    self.expireNotice(for: model.id)
                    // Nothing resident means the app cannot answer anything, so
                    // a download that just finished is unambiguously the model
                    // that was wanted. Without this the intro ends on a screen
                    // telling you to go and press Load — one more step, for a
                    // decision with exactly one option.
                    return self.loadedModelID == nil && !self.isLoadingModel
                }
                if shouldLoad {
                    await self.loadModel(model, remember: true)
                }
            } catch is CancellationError {
                await MainActor.run {
                    // `cancelDownload` has already decided whether there were
                    // bytes worth keeping and said so. This callback lands
                    // afterwards, so clearing unconditionally would delete the
                    // paused state a quarter-second after writing it.
                    if self.transfers[model.id]?.isActive == true {
                        self.transfers[model.id] = nil
                    }
                    self.downloadTasks[model.id] = nil
                    self.clearSamples(model.id)
                }
            } catch {
                await MainActor.run {
                    // Through the mapping, which is the only bridge in this app
                    // from an error to something transmittable. An interruption
                    // counts as a failure here: `offline` and `timed_out` are
                    // in the taxonomy because the Wi-Fi going is how this
                    // usually fails, not because it is an edge case.
                    self.analytics.record(.modelDownloadFailed(
                        modelID: model.id,
                        reason: AnalyticsMapping.downloadReason(for: error)
                    ))
                    // Never String(describing:) a URL error here: its userInfo
                    // carries the signed CDN URL and the entire resume blob,
                    // and all of it landed on screen.
                    if let paused = DownloadInterruption.from(error) {
                        self.transfers[model.id]?.advance(to: .paused(paused.message))
                    } else {
                        self.transfers[model.id]?.advance(to: .failed(
                            (error as? LocalizedError)?.errorDescription ?? "The download failed."
                        ))
                    }
                    self.downloadTasks[model.id] = nil
                    self.clearSamples(model.id)
                }
            }
        }
    }

    /// Clears a finished transfer once its notice has been on screen long
    /// enough to read.
    ///
    /// A timer rather than `isWorthShowing` alone, because that reads the
    /// clock and nothing re-renders a SwiftUI view when a clock passes a
    /// number. Removing the entry is what tells the banner to go.
    private func expireNotice(for id: String) {
        noticeTimers[id]?.cancel()
        noticeTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            let stillLoading = await MainActor.run { self?.loadingModelID == id }
            // A download that finishes with nothing resident loads itself, and
            // that takes far longer than the notice does. Pulling the banner
            // out from under it would leave the phone visibly busy with no
            // word anywhere about what it is busy with.
            if stillLoading {
                await MainActor.run { self?.expireNotice(for: id) }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.noticeTimers[id] = nil
                if case .finished = self.transfers[id]?.state {
                    self.transfers[id] = nil
                }
            }
        }
    }

    func cancelDownload(_ model: ModelRecord) {
        let kept = transfers[model.id]?.bytesSoFar?.receivedBytes ?? 0
        // Before the cancel, while the transfer still knows how far it got.
        // A percentage rather than the byte count beside it: the question is
        // how much of a download someone tolerated before giving up, and that
        // is the same question whether the file was 300 MB or 3 GB.
        analytics.record(.modelDownloadCancelled(
            modelID: model.id,
            percentComplete: Int((transfers[model.id]?.fraction ?? 0) * 100)
        ))
        downloadTasks[model.id]?.cancel()
        downloadTasks[model.id] = nil
        guard kept > 0 else {
            transfers[model.id] = nil
            return
        }
        // Cancelling usually keeps the bytes so the next tap resumes. That is
        // the right behaviour and it was completely invisible: the row
        // reverted to a plain Download button, indistinguishable from never
        // having started, while hundreds of megabytes sat on disk with no way
        // to reclaim them short of deleting the app.
        //
        // "Usually", though, and the gap is the whole reason for this state.
        // Whether those bytes are recoverable is not known when Stop is
        // tapped — it is known when URLSession finishes writing its resume
        // blob, seconds later. Announcing "kept" and offering Resume before
        // then meant a prompt tap started the download again from zero,
        // immediately after the screen had promised it would not.
        transfers[model.id]?.advance(to: .stopping)
        Task { [store] in
            let resumable = await store.awaitResumeData(for: model)
            await MainActor.run {
                guard case .stopping = self.transfers[model.id]?.state else { return }
                self.transfers[model.id]?.advance(to: .paused(
                    resumable
                    ? "Paused — \(ByteCountFormatter.string(fromByteCount: kept, countStyle: .file)) kept. Resume picks up where it stopped."
                    : "Stopped. This one cannot be continued, so Resume starts it again."
                ))
            }
        }
    }

    /// Stops showing a finished, failed or paused transfer.
    func clearTransfer(_ id: String) {
        noticeTimers[id]?.cancel()
        noticeTimers[id] = nil
        guard transfers[id]?.isActive == false else { return }
        transfers[id] = nil
    }

    /// Throws away a paused download's bytes.
    func discardPartialDownload(_ model: ModelRecord) async {
        await store.discardPartial(model)
        transfers[model.id] = nil
    }

    func delete(_ model: ModelRecord) async {
        if loadedModelID == model.id {
            await engine.unload()
            syncLoadedModel(nil)
            await recalibrateAfterUnload()
        }
        try? await store.delete(model)
        installed = await store.installed()
    }

    /// `remember: false` for the restore at launch — reloading what was already
    /// chosen should not overwrite the choice, and a fallback certainly should
    /// not silently become the new preference.
    /// The id currently being loaded, so the row can say so. `isLoadingModel`
    /// alone greyed out every Load button in the list with no indication of
    /// which one was working, or that anything was happening at all.
    private(set) var loadingModelID: String?

    func loadModel(_ model: ModelRecord, remember: Bool = true) async {
        // The engine serialises everything that touches the llama context,
        // so a load issued mid-generation simply blocked — for minutes, with
        // every button greyed and nothing on screen explaining why. Cancel
        // the reply first and say that is what happened.
        if isGenerating {
            stopGenerating()
            generationError = "Stopped the reply to load \(model.displayName)."
        }
        isLoadingModel = true
        loadingModelID = model.id
        defer { isLoadingModel = false; loadingModelID = nil }
        // Read once for both outcomes, because the question these two events
        // exist to answer is asked along that axis — whether 4 GB phones can
        // hold 3B models is not visible in any single device's failure.
        let ramClass = AnalyticsMapping.ramClass(bytes: budget.physicalMemoryBytes)
        // Monotonic rather than Date: a load is tens of seconds of memory
        // pressure on a phone, and a clock correction during one would put a
        // negative duration in a column that cannot mean anything by it.
        let started = ContinuousClock.now
        do {
            try await engine.load(model: model)
            analytics.record(.modelLoadSucceeded(
                modelID: model.id,
                ramClass: ramClass,
                loadMilliseconds: Int(started.duration(to: .now) / .milliseconds(1))
            ))
            syncLoadedModel(model.id)
            // This model is resident right now, so its estimate is no longer a
            // prediction — it is a measurement of what this device tolerates.
            // Recording it is what makes the next verdict better than a guess.
            budget.recordSuccessfulLoad(of: model)
            await store.updateBudget(budget)
            if remember { UserDefaults.standard.set(model.id, forKey: Keys.loadedModel) }
        } catch {
            // What this cannot see is the load that took the process with it:
            // running out of memory on a phone usually presents as a kill
            // rather than as a throw, so `out_of_memory` here undercounts and
            // the missing cases are invisible by construction. See
            // `AnalyticsMapping.loadReason`.
            analytics.record(.modelLoadFailed(
                modelID: model.id,
                ramClass: ramClass,
                reason: AnalyticsMapping.loadReason(for: error)
            ))
            syncLoadedModel(nil)
            loadErrors[model.id] = (error as? LocalizedError)?.errorDescription
                ?? "Could not load \(model.displayName)."
        }
    }

    /// Drops the resident model and frees its memory, keeping the file.
    ///
    /// Deleting was the only way to reclaim the memory, which meant paying for
    /// the download again. On a phone that is serving, this is the more useful
    /// half of the pair: a 4-bit 3B model holds well over a gigabyte resident,
    /// and that is a gigabyte the phone cannot spend on anything else.
    ///
    /// The remembered choice is deliberately kept. A server that has been told
    /// to run should still answer the next request, and answering it means
    /// loading this model again — offload frees the memory now, it does not
    /// resign from serving.
    func offloadModel() async {
        guard loadedModelID != nil else { return }
        if isGenerating {
            stopGenerating()
            generationError = "Stopped the reply to offload the model."
        }
        await engine.unload()
        await recalibrateAfterUnload()
        syncLoadedModel(nil)
        offloadNotice = serverShouldRun
            ? "Memory freed. The next request from a connected device loads it again."
            : "Memory freed. The model is still on this phone."
    }

    /// Shown after an offload, because otherwise the row simply reverts to
    /// "Load" and nothing says the memory actually came back.
    private(set) var offloadNotice: String?

    func dismissOffloadNotice() { offloadNotice = nil }

    // MARK: - Conversations

    private let conversations: ConversationStore
    /// Every saved conversation, newest first. Kept in memory so the history
    /// list is instant; the store is the source of truth on disk.
    private(set) var history: [Conversation] = []
    private(set) var currentConversationID = UUID()
    private var conversationStartedAt = Date()

    /// Writes are debounced rather than done per token: a reply arrives at
    /// dozens of tokens a second and each one would otherwise re-encode and
    /// re-write the entire transcript.
    private var saveTask: Task<Void, Never>?

    func loadHistory() async {
        history = await conversations.all()
    }

    private func snapshotConversation() -> Conversation {
        Conversation(
            id: currentConversationID,
            title: history.first(where: { $0.id == currentConversationID })?.title ?? "",
            createdAt: conversationStartedAt,
            updatedAt: Date(),
            modelID: loadedModelID,
            messages: conversation,
            draft: draft
        )
    }

    private var lastCheckpoint = Date.distantPast

    /// Writes the transcript mid-generation, at most every few seconds.
    ///
    /// Deliberately not `scheduleConversationSave`: that is a debounce, so
    /// calling it per token restarts its timer per token and it never fires at
    /// all for the whole of a continuous stream — the exact case it would be
    /// called for. This is the other shape, a throttle with a floor, and the
    /// floor is what keeps a long reply from rewriting the file sixty times a
    /// second.
    func checkpointConversation() {
        guard Date().timeIntervalSince(lastCheckpoint) >= 3 else { return }
        lastCheckpoint = Date()
        let snapshot = snapshotConversation()
        Task { [conversations] in try? await conversations.save(snapshot) }
    }

    /// Persists the current transcript shortly after it stops changing.
    func scheduleConversationSave() {
        saveTask?.cancel()
        let snapshot = snapshotConversation()
        saveTask = Task { [conversations] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? await conversations.save(snapshot)
            let all = await conversations.all()
            await MainActor.run { self.history = all }
        }
    }

    /// Saves immediately, for the paths where there may be no later chance —
    /// backgrounding, or switching away from a conversation.
    func flushConversation() async {
        saveTask?.cancel()
        try? await conversations.save(snapshotConversation())
        history = await conversations.all()
    }

    func newConversation() async {
        await flushConversation()
        conversation.removeAll()
        draft = ""
        generationError = nil
        modelSwitchNotice = nil
        currentConversationID = UUID()
        conversationStartedAt = Date()
    }

    func openConversation(_ id: UUID) async {
        guard id != currentConversationID else { return }
        await flushConversation()
        guard let found = history.first(where: { $0.id == id }) else { return }
        // Stopped for the same reason `loadModel` and `offloadModel` stop: the
        // transcript the reply is being written into is about to be replaced,
        // and a generation that outlived the swap has nowhere honest to put the
        // rest of its answer. Placed after the guard above so a conversation
        // that could not be opened costs nobody a reply, and before the swap so
        // the save it schedules still describes the transcript being left.
        let interrupted = isGenerating
        if interrupted { stopGenerating() }
        conversation = found.messages
        draft = found.draft
        currentConversationID = found.id
        conversationStartedAt = found.createdAt
        // Said on the screen the user ends up on, because that is the only
        // screen there is to say it on — the partial reply is back in the
        // conversation they left, where nothing would explain why it stops.
        generationError = interrupted ? "The reply in the conversation you left was stopped." : nil
        modelSwitchNotice = nil
    }

    func deleteConversation(_ id: UUID) async {
        // Before the file goes, so the reply cannot be writing into a
        // transcript whose only copy is being deleted underneath it — and the
        // pending write goes with it, or the debounced save lands 600ms after
        // the delete and puts the whole conversation back.
        if id == currentConversationID {
            if isGenerating { stopGenerating() }
            saveTask?.cancel()
        }
        await conversations.delete(id)
        history = await conversations.all()
        // Deleting what you are looking at has to leave you somewhere, and an
        // emptied-but-still-current transcript would be saved straight back.
        if id == currentConversationID {
            conversation.removeAll()
            draft = ""
            currentConversationID = UUID()
            conversationStartedAt = Date()
        }
    }

    func renameConversation(_ id: UUID, to title: String) async {
        guard var found = history.first(where: { $0.id == id }) else { return }
        found.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await conversations.save(found)
        history = await conversations.all()
    }

    // MARK: - Download rate

    /// A short history of (when, how many bytes) per download, used to quote a
    /// rate and a time remaining.
    ///
    /// Instantaneous rate — bytes since the last callback over the time since
    /// the last callback — is useless to read: it swings by an order of
    /// magnitude between callbacks and the ETA flickers between "2 minutes"
    /// and "40 minutes". Averaging over a window instead means the number
    /// moves slowly enough to be worth looking at, at the cost of lagging a
    /// genuine change in speed by a few seconds. That trade is the right way
    /// round for something a person is watching.
    private var downloadSamples: [String: [(at: Date, bytes: Int64)]] = [:]
    private static let rateWindow: TimeInterval = 8

    /// Downloads the user has swiped away. Cleared when the download finishes,
    /// so dismissing the progress does not also hide the finished state.
    private(set) var dismissedDownloads: Set<String> = []

    func dismissDownloadBanner(_ id: String) { dismissedDownloads.insert(id) }

    struct DownloadPace: Sendable, Equatable {
        var bytesPerSecond: Double
        var secondsRemaining: TimeInterval?
    }

    func pace(for id: String) -> DownloadPace? {
        guard let samples = downloadSamples[id], samples.count >= 2,
              let first = samples.first, let last = samples.last else { return nil }
        let seconds = last.at.timeIntervalSince(first.at)
        guard seconds > 0.5 else { return nil }
        let rate = Double(last.bytes - first.bytes) / seconds
        guard rate > 0 else { return DownloadPace(bytesPerSecond: 0, secondsRemaining: nil) }

        var remaining: TimeInterval?
        if let progress = transfers[id]?.progress, progress.totalBytes > progress.receivedBytes {
            remaining = Double(progress.totalBytes - progress.receivedBytes) / rate
        }
        return DownloadPace(bytesPerSecond: rate, secondsRemaining: remaining)
    }

    private func recordSample(_ progress: DownloadProgress) {
        let now = Date()
        var samples = downloadSamples[progress.modelID] ?? []
        samples.append((now, progress.receivedBytes))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.rateWindow }
        downloadSamples[progress.modelID] = samples
    }

    private func clearSamples(_ id: String) {
        downloadSamples[id] = nil
        dismissedDownloads.remove(id)
    }

    // MARK: - Assistant tools

    /// Whether the calendar tool is registered with the engine.
    ///
    /// Off by default, and it has to be a decision rather than a nicety.
    /// Registering a tool does not wait to be useful: the library appends every
    /// schema plus a fixed instruction preamble to the system message of
    /// *every* prompt, so a question about pasta is charged for a calendar the
    /// model was never going to open. `LlamaEngine.promptOverheadTokens`
    /// measures that and `ContextGuard` reserves it, which on a 4K window is a
    /// few hundred tokens of conversation the user no longer has.
    ///
    /// Split from `reminderToolsEnabled`, which it used to share a switch with.
    /// Both halves of that were wrong: the cost above is charged per tool, so
    /// somebody who only wanted their week read paid for a shopping list they
    /// never asked about, and iOS asked them for both permissions to get one.
    var calendarToolsEnabled = false {
        didSet {
            guard calendarToolsEnabled != oldValue else { return }
            UserDefaults.standard.set(calendarToolsEnabled, forKey: Keys.calendarTools)
            Task { await applyPersonalDataTools() }
        }
    }

    /// Whether the reminders tool is registered with the engine.
    ///
    /// Its own switch, its own key and its own iOS grant; the schema cost that
    /// makes this a decision rather than a default is described on
    /// `calendarToolsEnabled` and is charged separately here.
    var reminderToolsEnabled = false {
        didSet {
            guard reminderToolsEnabled != oldValue else { return }
            UserDefaults.standard.set(reminderToolsEnabled, forKey: Keys.reminderTools)
            Task { await applyPersonalDataTools() }
        }
    }

    /// Whether either of the two is on, for the callers that genuinely mean
    /// "personal data at all" — a section header, or a notice that describes
    /// the pair. Not a setting: nothing writes through it, because writing
    /// through it is what made the two capabilities inseparable.
    var anyPersonalDataToolEnabled: Bool { calendarToolsEnabled || reminderToolsEnabled }

    /// The switch governing one entity, so that the loops over
    /// `PersonalDataEntity.allCases` do not each carry their own `switch` over
    /// which property holds which. Adding a third entity should break in one
    /// place, not in three.
    func isEnabled(_ entity: PersonalDataEntity) -> Bool {
        switch entity {
        case .calendar: calendarToolsEnabled
        case .reminders: reminderToolsEnabled
        }
    }

    /// What the engine did with the switches, and why.
    ///
    /// Settings needs this because a switch is one thing and the effect is
    /// another: the switches above say what the user asked for, and this says
    /// what the model currently in memory will actually be given. The two
    /// disagreed silently before, which is how a user ends up with a switch
    /// that is on, a calendar that is never read, and no way to find out why.
    private(set) var personalDataToolGate: ToolGate.Decision = .noModelLoaded

    /// What the budget did with what the gate allowed.
    ///
    /// The second half of the same answer, and it was the half nobody could
    /// see. The gate decides whether this model gets tools at all; the context
    /// window then decides how many of them fit, and at a 1,024-token limit it
    /// quietly keeps the calendar and refuses reminders — while the only
    /// sentence on the screen was the gate's, which says both are registered.
    /// The plan holds the honest version, priced, and `CapabilityNotice` is
    /// where the two are stopped from contradicting each other.
    private(set) var capabilityPlan: CapabilityBudget.Plan?

    /// The display name of whatever is resident, for the sentences under the
    /// capability switches. Falls back to the id: a model added through search
    /// has no curated name, and naming it badly is better than not naming it.
    var loadedModelName: String {
        guard let id = loadedModelID else { return "No model" }
        return catalog.first { $0.id == id }?.displayName ?? id
    }

    /// The one thing Settings prints under the two switches.
    ///
    /// One sentence and not two, because two deciders can answer this question
    /// and only the last one to run is the reason. See `CapabilityNotice`.
    var capabilityNotice: CapabilityNotice? {
        CapabilityNotice.decide(
            gate: personalDataToolGate,
            plan: capabilityPlan,
            modelName: loadedModelName
        )
    }

    /// The health switch's own row, for the two things `capabilityNotice` is
    /// not in a position to say.
    ///
    /// Availability comes first because it outranks everything above it: on a
    /// device with no Health store the tool is never registered at all, so
    /// there is no budget verdict to report and the notice would be describing
    /// the calendar pair beside a switch about sleep. The refusal below it is
    /// only reached when the notice is absent — with either personal data
    /// switch on it is already printing health's line, and printing it twice
    /// reads as two separate problems.
    var healthCapabilityNote: String? {
        if let unavailable = healthAvailability.explanation { return unavailable }
        guard !anyPersonalDataToolEnabled else { return nil }
        return capabilityPlan?.shortfall(for: .health)
    }

    /// Health is a separate switch from the calendar, deliberately.
    ///
    /// It is a separate grant, a separate iOS sheet, and its own schema cost on
    /// every prompt — and someone who is relaxed about the app reading their
    /// week is often not relaxed about it reading their heart.
    var healthToolsEnabled = false {
        didSet {
            guard healthToolsEnabled != oldValue else { return }
            UserDefaults.standard.set(healthToolsEnabled, forKey: Keys.healthTools)
            Task { await applyPersonalDataTools() }
        }
    }

    /// What iOS said when the switch was flipped — never a claim about whether
    /// a read was granted. HealthKit does not report that, and any UI implying
    /// otherwise is a lie the app cannot substantiate.
    ///
    /// Shown under the switch through `HealthAvailability.explanation`, because
    /// the cases that are not `.available` are the ones where the switch is on
    /// and nothing will ever be read: `registrations` skips the tool outright on
    /// a device with no Health store, so without a sentence here the user is
    /// left with a switch that is on, a heart rate that is never read, and no
    /// way to find out why — the exact failure `personalDataToolGate` exists to
    /// end, one switch further down.
    private(set) var healthAvailability: HealthAvailability = .available

    private func refreshToolGate() async {
        personalDataToolGate = await engine.toolGate
        capabilityPlan = await engine.capabilityPlan
    }

    /// What iOS says about each entity right now, for Settings to show.
    ///
    /// Kept rather than read on demand because `EKEventStore.authorizationStatus`
    /// is a synchronous TCC lookup that a SwiftUI body would run on every
    /// redraw, and because the interesting transitions — the prompt being
    /// answered, the user coming back from iOS Settings — are events, not
    /// polling.
    private(set) var personalDataAuthorization: [PersonalDataEntity: PersonalDataAuthorization] = [:]

    /// What gets registered for a given state of the switches.
    ///
    /// The self-test tool is independent of them: `-pocketd-selftest-tool`
    /// exercises the tool-calling loop on a device without needing EventKit, a
    /// permission prompt or a calendar with anything in it, and it has to keep
    /// working whether or not the real tools are on.
    /// The tools the product registers, each tagged with the capability it
    /// belongs to so the engine's budget can drop a whole capability rather
    /// than an arbitrary tool.
    ///
    /// Priority is the array order, and it is a product judgement: the calendar
    /// answers the question people actually ask most, and health is the largest
    /// schema of the three, so on a window too small for everything health is
    /// the one that goes.
    ///
    /// One parameter per tool rather than one for the pair. The budget has
    /// always dropped these two independently — `CapabilityGroup` has separate
    /// cases for exactly that reason — and it was only the switch above it that
    /// could not express a calendar without reminders.
    private static func registrations(
        calendar: Bool,
        reminders: Bool,
        health: Bool
    ) -> [(tool: any LLMTool, group: CapabilityGroup)] {
        var registered: [(tool: any LLMTool, group: CapabilityGroup)] = []
        if calendar {
            registered.append((CalendarEventsTool(), .calendar))
        }
        if reminders {
            registered.append((RemindersTool(), .reminders))
        }
        // Availability-guarded so a device with no Health store never pays
        // schema tokens for a tool that could only ever refuse.
        if health, HealthAccess.isAvailable {
            registered.append((HealthSummaryTool(), .health))
        }
        return registered
    }

    /// Outside the budget on purpose: a diagnostic is not a capability, and
    /// charging it against the ceiling would let the self-test alter the thing
    /// it exists to test.
    private static func selfTestTools() -> [any LLMTool] {
        ProcessInfo.processInfo.arguments.contains("-pocketd-selftest-tool") ? [EchoTool()] : []
    }

    /// Asks for the permissions, then tells the engine what it is carrying.
    ///
    /// The prompt goes here, at the switch, and not at first tool use. iOS puts
    /// it up as a modal alert, and first use is in the middle of a generation:
    /// the engine is holding its gate, the stream is open and producing
    /// nothing, and the user is being asked a question about their calendar
    /// with no visible connection to the sentence they typed. Whatever they tap
    /// under those conditions is not really a decision. At the switch it is one
    /// — they have just said the word "calendar" themselves — and it is also
    /// the only moment that leaves Settings able to show what iOS decided.
    ///
    /// The tools still ask again at use, because `EventAccess.requestReadAccess`
    /// is where a permission that changed while the app was backgrounded gets
    /// noticed. Asking twice costs nothing: iOS shows its prompt once, and
    /// every later call returns the standing answer without any UI.
    private func applyPersonalDataTools() async {
        // Only the entity whose switch is on, which is the point of there
        // being two of them. The one switch asked iOS for both grants, so
        // somebody who wanted their shopping list read got a calendar prompt
        // too — and an app that asks for a permission nobody asked it to want
        // is how it ends up denied the one it needed.
        //
        // An entity that is already settled is asked again on the way past,
        // which costs nothing — iOS answers a settled question without any UI
        // — and refreshes what Settings shows for it.
        for entity in PersonalDataEntity.allCases {
            guard isEnabled(entity) else {
                // Dropped, not kept. These entries are what Settings turns into
                // "Pocketd cannot read your calendar" warnings, and with two
                // switches one of them can go off while the screen stays up:
                // leaving the last answer behind means complaining about a
                // permission for a capability the user has just switched off.
                personalDataAuthorization[entity] = nil
                continue
            }
            personalDataAuthorization[entity] = await EventAccess.shared.requestReadAccess(to: entity)
        }
        // Not a reload. The engine records the new set and rebuilds its client
        // on the next request that needs one, so a user who flips the switch
        // and puts the phone down pays nothing at all.
        if healthToolsEnabled {
            // At the switch, not at first use. iOS puts the Health sheet up as
            // a modal, and first use is mid-generation — the stream open, the
            // gate held, and nothing on screen connecting the sheet to what the
            // user typed. Whatever they tap there is not a decision.
            healthAvailability = await HealthAccess.shared.requestAllReadAccess()
        }
        await engine.updateTools(
            Self.registrations(
                calendar: calendarToolsEnabled,
                reminders: reminderToolsEnabled,
                health: healthToolsEnabled
            ),
            exempt: Self.selfTestTools()
        )
        // The switch is what changed what the budget was asked to carry, so it
        // is also the moment the answer changes. Without this the refusal only
        // appeared after the next model load, which is to say on the screen the
        // user was already looking at, several minutes late.
        await refreshToolGate()
    }

    /// Re-reads what iOS thinks, without prompting.
    ///
    /// Settings calls this on appear: the one way a granted permission becomes
    /// a denied one is the user leaving for iOS Settings and coming back, and
    /// nothing about that trip tells this process anything.
    func refreshPersonalDataAuthorization() {
        // The gate is re-read whether or not either switch is on: it is what
        // the row shows to explain an inert switch, and the trip to iOS
        // Settings is not the only thing that can have happened while this
        // screen was away.
        Task { await refreshToolGate() }
        // A device with no Health store at all is a fact about the device, not
        // an answer iOS gave: it is true at launch, before anything has asked
        // for anything, and a switch left on from a previous install would
        // otherwise sit here explaining nothing until the user toggled it. Only
        // ever set in the direction the read supports — `.available` here would
        // overwrite a `.requestFailed` reason with a shrug.
        if healthToolsEnabled, !HealthAccess.isAvailable {
            healthAvailability = .noHealthData
        }
        // Per entity, because the switches now are. Gating the whole loop on
        // "is either of them on" would have been the smaller edit and it reads
        // the wrong thing: with the calendar on and reminders off it fetches a
        // reminders status nobody asked for, and this dictionary is what
        // Settings turns into warnings.
        //
        // What the split does not fix is the entity whose own switch is off: it
        // gets no entry, so its authorization is unknown for as long as it
        // stays off. That behaviour is inherited from the single switch, not
        // solved here. `EventAccess.authorization(for:)` prompts nobody and is
        // cheap enough to run for both unconditionally, so the obstacle is not
        // the read — it is that no screen can currently show a status for a
        // capability that is off without it reading as a complaint. That is the
        // capability hub's call, and it belongs in the change that builds it.
        for entity in PersonalDataEntity.allCases {
            guard isEnabled(entity) else {
                personalDataAuthorization[entity] = nil
                continue
            }
            personalDataAuthorization[entity] = EventAccess.authorization(for: entity)
        }
    }


    /// Takes a memory reading now that nothing is resident.
    ///
    /// Only ever called straight after an unload. A reading taken with a model
    /// in memory measures the model rather than the device, and the running
    /// maximum this feeds is only meaningful if every sample is comparable.
    private func recalibrateAfterUnload() async {
        budget.recordCleanStateMemory()
        await store.updateBudget(budget)
    }

    // MARK: - Idle residency

    /// Release the model when the app is backgrounded. On by default: a
    /// suspended process holding gigabytes is the first thing the kernel
    /// reclaims, and the socket is closed then anyway, so nothing is lost.
    var autoOffloadInBackground = true {
        didSet { UserDefaults.standard.set(autoOffloadInBackground, forKey: Keys.autoOffloadInBackground) }
    }

    /// Seconds of quiet before the model is released, or 0 to keep it resident.
    ///
    /// This is `keep_alive`, and it exists here for the reason it exists in
    /// Ollama: a server is idle most of the time, and a phone has other things
    /// to do with two gigabytes. It defaults to off rather than to Ollama's
    /// five minutes because the reload is not free here — a desktop refills
    /// from page cache in about a second, a phone takes appreciably longer, and
    /// silently adding that to someone's first request after lunch is a worse
    /// surprise than the memory.
    var idleOffloadSeconds = 0 {
        didSet {
            UserDefaults.standard.set(idleOffloadSeconds, forKey: Keys.idleOffloadSeconds)
            restartIdleWatch()
        }
    }

    private var idleWatch: Task<Void, Never>?
    private var lastLocalActivity = Date()

    /// Called whenever this device generates something itself. Requests from
    /// the network are noticed separately, from the request log — the server
    /// talks to the engine directly and never comes through here.
    func noteActivity() { lastLocalActivity = Date() }

    private func restartIdleWatch() {
        idleWatch?.cancel()
        guard idleOffloadSeconds > 0 else { idleWatch = nil; return }
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.releaseIfIdle()
            }
        }
    }

    private func releaseIfIdle() async {
        guard idleOffloadSeconds > 0, !isGenerating, releaseSuppressions.isEmpty else { return }
        guard let resident = loadedModelID else { return }

        // The later of the two clocks. Serving a laptop all afternoon without
        // touching the phone still counts as being in use, and unloading
        // underneath a working coding agent would be the exact opposite of
        // what this setting is for.
        let lastServed = await server.log.all().last?.date ?? .distantPast
        let lastAny = max(lastLocalActivity, lastServed)
        guard Date().timeIntervalSince(lastAny) >= Double(idleOffloadSeconds) else { return }

        await engine.unload()
        await recalibrateAfterUnload()
        syncLoadedModel(nil, userInitiated: false)
        autoReleased = (resident, .idle)
    }

    // MARK: - First run

    /// Whether the intro has been seen.
    ///
    /// Read once at launch rather than observed: flipping it mid-session is
    /// what dismisses the intro, and a stored value that changed underneath
    /// would put it back.
    private(set) var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Keys.completedOnboarding)

    var needsOnboarding: Bool { !hasCompletedOnboarding }

    /// Settles the flag for an install that predates the intro existing.
    ///
    /// Called once at launch. Someone updating into this build already knows
    /// what the app is, so they are marked done rather than shown it — but the
    /// test has to be *here*, not folded into `needsOnboarding`, because
    /// otherwise "Show the introduction again" would be dead for exactly the
    /// people who have used the app enough to want it. That is the shape of
    /// bug where a button exists, does nothing, and nobody notices for months.
    private func settleOnboardingForExistingInstall() {
        guard !hasCompletedOnboarding, !installed.isEmpty else { return }
        completeOnboarding()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Keys.completedOnboarding)
    }

    /// Replays the intro from Settings. Deliberately does not undo anything
    /// else — this is "show me that again", not "reset the app".
    func replayOnboarding() {
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: Keys.completedOnboarding)
    }

    /// What the intro should have selected when it opens.
    ///
    /// The middle tier, not the smallest. A 360M model downloads in seconds and
    /// is barely coherent, so defaulting to it makes the first answer someone
    /// ever sees the worst one this app can produce — a fast route to deciding
    /// the whole idea does not work. The bigger download is the better trade,
    /// and the smaller option is still right there for anyone on a slow
    /// connection.
    var recommendedStarter: ModelRecord? {
        let starters = starterModels
        guard !starters.isEmpty else { return nil }
        return starters[starters.count / 2]
    }

    /// Up to three models spanning what this phone can actually hold.
    ///
    /// Built from the same fit estimate the Models tab uses, so the intro can
    /// never offer something that will be killed on load. Comfortable entries
    /// only, unless nothing is comfortable — on a small device an honest
    /// "tight" beats an empty screen with nothing to choose.
    var starterModels: [ModelRecord] {
        // Already-downloaded models are excluded: on a replay from Settings the
        // list would otherwise offer to fetch things this phone has had for
        // weeks.
        let installable = ModelCatalog.all.filter {
            !$0.declaredCapabilities.vision.isYes && !isInstalled($0)
        }
        var usable = installable.filter { fit(for: $0) == .comfortable }
        if usable.isEmpty {
            usable = installable.filter { fit(for: $0) != .willNotFit }
        }
        let ordered = usable.sorted { $0.totalDownloadBytes < $1.totalDownloadBytes }
        guard ordered.count > 3 else { return ordered }
        // Smallest, middle and largest: the choice being offered is "how much
        // of this phone do you want to spend", and three points make that
        // legible where eight would not.
        return [ordered[0], ordered[ordered.count / 2], ordered[ordered.count - 1]]
    }

    // MARK: - Residency

    /// Why the model left memory, when it was not the user's doing.
    ///
    /// The distinction decides whether it comes back on its own. A model the
    /// user offloaded stays offloaded; one the app released to survive
    /// backgrounding, or to stop holding a gigabyte hostage while idle, is
    /// restored the moment it is wanted again.
    enum ReleaseReason: String, Sendable {
        case background
        case idle
    }

    private(set) var autoReleased: (id: String, reason: ReleaseReason)?

    /// Reasons the app is currently forbidden from auto-releasing.
    ///
    /// A set rather than a flag because the suppressions nest: the photo
    /// picker can be open while a download completes. Clearing a boolean at
    /// the end of one of those would re-arm release while the other was still
    /// in progress.
    private var releaseSuppressions: Set<String> = []

    func suppressAutoRelease(_ reason: String) { releaseSuppressions.insert(reason) }
    func resumeAutoRelease(_ reason: String) { releaseSuppressions.remove(reason) }

    /// Scene-phase handling, and the reason it is not a two-state check.
    ///
    /// `.inactive` is not "leaving". It fires for a notification banner, the
    /// app switcher, Control Centre, an incoming call sheet, and every system
    /// permission prompt. Unloading a multi-gigabyte model there would mean a
    /// notification arriving mid-conversation costs a full reload — so
    /// `.inactive` is deliberately ignored and only `.background` releases.
    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            await releaseForBackground()
        case .active:
            await reconcileAfterForeground()
            await restoreAutoReleasedModel()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func releaseForBackground() async {
        // Before anything else: suspension is the last moment this process is
        // guaranteed to run again, and the debounced save may still be pending.
        await flushConversation()

        guard autoOffloadInBackground, releaseSuppressions.isEmpty else { return }
        guard let resident = loadedModelID else { return }
        // The socket does not survive suspension either, so nothing can arrive
        // to be served while the weights are gone. Holding them costs the app
        // its life: a suspended process sitting on two gigabytes is the first
        // thing the kernel reclaims, and the user experiences that as the app
        // having quit itself.
        if isGenerating { stopGenerating() }
        await engine.unload()
        await recalibrateAfterUnload()
        syncLoadedModel(nil, userInitiated: false)
        autoReleased = (resident, .background)
    }

    /// Puts back what the app took away, and nothing else.
    private func restoreAutoReleasedModel() async {
        guard let released = autoReleased else { return }
        guard loadedModelID == nil else { autoReleased = nil; return }
        guard let record = catalog.first(where: { $0.id == released.id }) else {
            autoReleased = nil
            return
        }
        autoReleased = nil
        await loadModel(record, remember: false)
    }

    /// The single place the resident-model mirror changes.
    ///
    /// `userInitiated` matters: the server loads a model on demand whenever a
    /// request names one, so a curl from anywhere on the network could swap the
    /// resident model — and this method used to clear the transcript on any
    /// change. A stranger could erase the phone user's conversation, silently,
    /// with no undo. Now a swap the user did not ask for keeps the transcript
    /// and says what happened.
    private func syncLoadedModel(_ id: String?, userInitiated: Bool = true) {
        guard id != loadedModelID else { return }
        let previous = loadedModelID
        loadedModelID = id
        // Whether the assistant tools are live is a property of the resident
        // model, so it is re-read exactly where the resident model changes —
        // which includes the swaps this app did not initiate. A network client
        // loading Llama 3.2 1B silently turns the tools off, and the Settings
        // row has to say so rather than keep showing the last model's answer.
        Task { await refreshToolGate() }
        if userInitiated {
            // Kept, not cleared. Deleting a model asks for confirmation
            // because the download is expensive; the transcript was thrown
            // away silently, and it is the thing that cannot be recovered.
            if previous != nil, !conversation.isEmpty {
                modelSwitchNotice = "Switched to \(id ?? "another model"). "
                    + "This conversation was started with \(previous ?? "a different model")."
            } else {
                modelSwitchNotice = nil
            }
        } else if previous != nil, !conversation.isEmpty {
            modelSwitchNotice = "A request from another device loaded \(id ?? "another model"). This conversation was started with \(previous ?? "a different model")."
        }
    }

    /// Shown in Chat when the resident model changed underneath the user.
    private(set) var modelSwitchNotice: String?
    /// Transport failures live here rather than in the transcript, so they
    /// are never sent back to the model as prior context.
    private(set) var generationError: String?

    func dismissModelSwitchNotice() { modelSwitchNotice = nil }

    // MARK: - Chat

    /// Images waiting to go with the next message.
    ///
    /// Held here rather than in the view so that switching tabs mid-compose
    /// does not silently drop a photo someone has already chosen — the same
    /// reason the text draft lives here.
    private(set) var attachments: [Data] = []

    /// Whether the resident model can see, which is the only honest basis for
    /// offering the camera button.
    ///
    /// A vision model whose projector never downloaded loads and cannot see:
    /// `ModelStore` refuses to mark such a model installed for exactly that
    /// reason, so `declaredCapabilities` is trustworthy by the time a model is
    /// loadable at all.
    var loadedModelSeesImages: Bool {
        guard let id = loadedModelID else { return false }
        return catalog.first { $0.id == id }?.declaredCapabilities.vision.isYes ?? false
    }

    func attach(_ image: Data) {
        // Four is what the context can carry: each image is hundreds of tokens
        // of projector output before a word of the question is read.
        guard attachments.count < 4 else { return }
        attachments.append(image)
    }

    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    func clearAttachments() { attachments.removeAll() }

    func send() {
        noteActivity()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A picture with no words is a question — "what is this" is implied —
        // so an empty draft is allowed once something is attached.
        guard !text.isEmpty || !attachments.isEmpty, !isGenerating, loadedModelID != nil else { return }
        // After the guard rather than at the top of the method: a tap with an
        // empty draft, or with nothing resident to answer it, sends no message.
        analytics.record(.chatMessageSent(modelID: loadedModelID ?? ""))
        let images = attachments
        draft = ""
        attachments = []
        generationError = nil
        conversation.append(ChatMessage(role: .user, content: text, images: images))
        conversation.append(.assistant(""))
        isGenerating = true
        // Both written weeks ago and never called. A generation is exactly the
        // case they exist for: the idle timer was driven only by the server, so
        // a phone answering a question in Chat locked its screen mid-reply, and
        // the lock backgrounds the app, and backgrounding unloads the model.
        UIApplication.shared.isIdleTimerDisabled = true
        suppressAutoRelease("generating")
        // Before a single token exists. Until now the only saves were after a
        // generation ended, so a force-quit or a memory kill during the 60-90
        // seconds a phone takes to answer lost the question as well as the
        // reply — and the app's own recovery from a hang is a force-quit.
        scheduleConversationSave()

        // What this reply is being written into, stamped before a single token
        // exists, because from here on every event arrives across an actor hop
        // that a tap on History can slip between. See `GenerationTarget`.
        let target = GenerationTarget(conversation: currentConversationID, slot: conversation.count - 1)

        var messages: [ChatMessage] = []
        if !systemPrompt.isEmpty { messages.append(.system(systemPrompt)) }
        messages.append(contentsOf: conversation.dropLast())
        // On the last user turn only, because Qwen documents the switch as
        // per-turn and says the model follows the most recent instruction —
        // repeating it on every historical turn would spend tokens restating
        // something already obeyed. Appended to the copy the model reads and
        // never to the transcript: the user did not type it, and a conversation
        // reopened later must not show it.
        if !configuration.reasoningEnabled, let last = messages.indices.last, messages[last].role == .user {
            messages[last].content += "\n/no_think"
        }
        // Unconditional, unlike the tools, because it is nearly free and
        // because without it the assistant is wrong rather than merely
        // unhelpful: a model that does not know the date answers "what's on
        // tomorrow" from whenever its training data stopped, and says it with
        // the same confidence as everything else. See `DateContext` for why
        // this is a sentence and not a `get_current_datetime` tool.
        //
        // It does cost one thing, and it is worth naming: the string carries a
        // clock time, so it changes between turns, and LocalLLMClient's prompt
        // cache is a prefix match on the rendered text. Crossing a minute
        // boundary mid-conversation therefore re-prefills what was already
        // decoded. Prefill is the cheap half of a generation and the trade is
        // an obviously right one — an answer that is a second slower against an
        // answer that is wrong about what day it is.
        messages = DateContext.inject(into: messages)

        // The Chat tab is a human holding the phone, which is the one origin
        // allowed to reach personal data. Every other path — including the
        // /chat page this app serves, which is indistinguishable from curl at
        // the route layer — stays on the network default.
        let request = GenerationRequest(
            modelID: loadedModelID ?? "",
            messages: messages,
            options: GenerationOptions(maxTokens: configuration.maxContextTokens),
            origin: .onDeviceChat
        )

        generationTask = Task { [engine] in
            do {
                for try await event in try await engine.generate(request) {
                    switch event {
                    case .token(let chunk):
                        await MainActor.run {
                            self.checkpointConversation()
                            guard target.canWrite(to: self.currentConversationID, messages: self.conversation) else { return }
                            self.conversation[target.slot].content += chunk
                        }
                    case .answerCard(let card):
                        // The tool's own output, not the model's account of it.
                        // It arrives before the narration and is what the reader
                        // should believe if the two ever disagree.
                        await MainActor.run {
                            guard target.canWrite(to: self.currentConversationID, messages: self.conversation) else { return }
                            self.conversation[target.slot].cards.append(card)
                        }
                    case .toolCallStarted, .finished:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    // Kept OUT of the message. Appending it made the error
                    // part of the assistant's turn, and the next send
                    // replayed it as something the model had said — so it
                    // would then explain its own transport failure back to
                    // the user as though it were a reply.
                    guard self.currentConversationID == target.conversation else { return }
                    self.discardEmptyReply()
                    self.generationError = (error as? LocalizedError)?.errorDescription
                        ?? "The reply could not be completed."
                }
            }
            await MainActor.run {
                self.isGenerating = false
                self.resumeAutoRelease("generating")
                self.applyIdleTimer(running: self.serverShouldRun)
                // The transcript this reply belongs to, or nothing at all.
                // Whatever is on screen instead was saved on the way out of
                // the one being left, and writing it again here is how a
                // conversation acquires the tail of another one's answer.
                if self.currentConversationID == target.conversation { self.scheduleConversationSave() }
            }
        }
    }

    /// Removes an assistant turn that never said anything.
    ///
    /// `send()` appends `.assistant("")` before a token exists so there is a
    /// slot to stream into. If the generation then fails or is stopped before
    /// the first token, nothing removed it: the transcript kept a permanent
    /// "…" bubble, the save wrote it to disk, and the next send replayed it to
    /// the model as a turn in which the assistant had said nothing — which a
    /// small model reads as an example of how to answer.
    ///
    /// Cards count as having said something: a tool can return a card and the
    /// narration fail afterwards, and the card is the part worth keeping.
    private func discardEmptyReply() {
        guard let last = conversation.indices.last,
              conversation[last].role == .assistant,
              conversation[last].content.isEmpty,
              conversation[last].cards.isEmpty
        else { return }
        conversation.remove(at: last)
    }

    func stopGenerating() {
        // A stopped reply is still a reply: the partial text is on screen and
        // has to survive the same way a finished one does.
        defer { scheduleConversationSave() }
        resumeAutoRelease("generating")
        applyIdleTimer(running: serverShouldRun)
        discardEmptyReply()
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    /// Starts a new conversation, keeping the old one.
    ///
    /// This used to be `removeAll()`, which was the only destructive action in
    /// the app that asked for no confirmation — deleting a *model* prompts,
    /// because the download is expensive, while the transcript, which is the
    /// one thing here that cannot be re-fetched, went silently.
    func resetConversation() {
        stopGenerating()
        Task { await newConversation() }
    }
}
