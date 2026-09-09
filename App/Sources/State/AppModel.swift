import Foundation
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
    private(set) var downloads: [String: DownloadProgress] = [:]
    private(set) var downloadErrors: [String: String] = [:]
    private(set) var loadedModelID: String?
    private(set) var isLoadingModel = false
    let budget: DeviceBudget

    var catalog: [ModelRecord] { ModelCatalog.all }

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
    private var generationTask: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []
    private let bonjour = BonjourAdvertiser()
    private var governor: DeviceGovernor?

    private enum Keys {
        static let loadedModel = "pocketd.loadedModel"
        static let systemPrompt = "pocketd.systemPrompt"
        static let serverShouldRun = "pocketd.serverShouldRun"
    }

    init() {
        budget = .current(hasIncreasedMemoryLimit: Entitlements.hasIncreasedMemoryLimit)

        let directory = (try? ModelStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Models")
        let store = ModelStore(directory: directory, budget: budget)
        self.store = store

        let engine = LlamaEngine(
            fileURL: { store.fileURL(for: $0) },
            projectorURL: { store.projectorURL(for: $0) },
            // Empty by default, and that is the shipping configuration:
            // registering any tool injects a schema preamble into every prompt,
            // whether or not the user ever asks for one. Launch with
            // `-pocketd-selftest-tool` to exercise the tool-calling loop on a
            // device without needing EventKit, a permission prompt or a
            // calendar with anything in it.
            tools: ProcessInfo.processInfo.arguments.contains("-pocketd-selftest-tool") ? [EchoTool()] : []
        )
        self.engine = engine

        // load() persists a freshly generated configuration on the spot. Relying
        // on the didSet below would not: property observers do not run during
        // initialisation, so the API key would be new on every launch.
        let configurationStore = ServerConfigurationStore()
        self.configurationStore = configurationStore
        let configuration = configurationStore.load()
        self.configuration = configuration

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
            }
        )

        systemPrompt = UserDefaults.standard.string(forKey: Keys.systemPrompt) ?? systemPrompt
        serverShouldRun = UserDefaults.standard.bool(forKey: Keys.serverShouldRun)
    }

    func bootstrap() async {
        let governor = DeviceGovernor(batteryFloor: configuration.pauseBelowBatteryLevel) { [weak self] condition in
            guard let self else { return }
            self.condition = condition
            Task { await self.server.setCondition(condition) }
        }
        self.governor = governor
        governor.start()

        await store.load()
        installed = await store.installed()

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

    func download(_ model: ModelRecord, allowingOversized: Bool = false) {
        guard downloadTasks[model.id] == nil else { return }
        downloadErrors[model.id] = nil
        downloads[model.id] = DownloadProgress(modelID: model.id, receivedBytes: 0, totalBytes: model.sizeBytes)

        downloadTasks[model.id] = Task { [store] in
            do {
                for try await progress in await store.download(model, allowingOversized: allowingOversized) {
                    await MainActor.run { self.downloads[model.id] = progress }
                }
                let list = await store.installed()
                await MainActor.run {
                    self.installed = list
                    self.downloads[model.id] = nil
                    self.downloadTasks[model.id] = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.downloads[model.id] = nil
                    self.downloadTasks[model.id] = nil
                }
            } catch {
                await MainActor.run {
                    self.downloadErrors[model.id] = String(describing: error)
                    self.downloads[model.id] = nil
                    self.downloadTasks[model.id] = nil
                }
            }
        }
    }

    func cancelDownload(_ model: ModelRecord) {
        downloadTasks[model.id]?.cancel()
        downloadTasks[model.id] = nil
        downloads[model.id] = nil
    }

    func delete(_ model: ModelRecord) async {
        if loadedModelID == model.id {
            await engine.unload()
            syncLoadedModel(nil)
        }
        try? await store.delete(model)
        installed = await store.installed()
    }

    /// `remember: false` for the restore at launch — reloading what was already
    /// chosen should not overwrite the choice, and a fallback certainly should
    /// not silently become the new preference.
    func loadModel(_ model: ModelRecord, remember: Bool = true) async {
        isLoadingModel = true
        defer { isLoadingModel = false }
        do {
            try await engine.load(model: model)
            syncLoadedModel(model.id)
            if remember { UserDefaults.standard.set(model.id, forKey: Keys.loadedModel) }
        } catch {
            syncLoadedModel(nil)
            downloadErrors[model.id] = String(describing: error)
        }
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
        if userInitiated {
            conversation.removeAll()
            modelSwitchNotice = nil
        } else if previous != nil, !conversation.isEmpty {
            modelSwitchNotice = "A request from another device loaded \(id ?? "another model"). This conversation was started with \(previous ?? "a different model")."
        }
    }

    /// Shown in Chat when the resident model changed underneath the user.
    private(set) var modelSwitchNotice: String?

    func dismissModelSwitchNotice() { modelSwitchNotice = nil }

    // MARK: - Chat

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating, loadedModelID != nil else { return }
        draft = ""
        conversation.append(.user(text))
        conversation.append(.assistant(""))
        isGenerating = true

        var messages: [ChatMessage] = []
        if !systemPrompt.isEmpty { messages.append(.system(systemPrompt)) }
        messages.append(contentsOf: conversation.dropLast())

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
                    guard case let .token(chunk) = event else { continue }
                    await MainActor.run {
                        if !self.conversation.isEmpty {
                            self.conversation[self.conversation.count - 1].content += chunk
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if !self.conversation.isEmpty {
                        self.conversation[self.conversation.count - 1].content += "\n\n_Error: \(error)_"
                    }
                }
            }
            await MainActor.run { self.isGenerating = false }
        }
    }

    func stopGenerating() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    func resetConversation() {
        stopGenerating()
        conversation.removeAll()
    }
}
