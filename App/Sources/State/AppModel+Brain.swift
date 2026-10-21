import Foundation
import PocketdKit

/// The brain: the catalogue, downloads, loading and unloading, and keeping it
/// resident only while that is worth its memory.
@MainActor
extension AppModel {

    // MARK: - The catalogue

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

    /// The display name of whatever is resident, for the sentences under the
    /// capability switches. Falls back to the id: a model added through search
    /// has no curated name, and naming it badly is better than not naming it.
    var loadedModelName: String {
        guard let id = loadedModelID else { return "No model" }
        if id == ModelRecord.builtInID { return BuiltInBrainOffer.title }
        return catalog.first { $0.id == id }?.displayName ?? id
    }

    /// What the intro should have selected when it opens.
    ///
    /// The rule moved to `StarterModels` in the Kit, where it can be tested
    /// against a 4, 6 and 8 GB phone with and without the entitlement. It used
    /// to be "the middle of the list by download size", which on the 6 GB
    /// iPhone 14 this is developed against selected Llama 3.2 1B — a model
    /// whose template has no notion of tools, so the first thing the app
    /// recommended could not do the calendar, reminders or health questions it
    /// was recommending itself for.
    var recommendedStarter: ModelRecord? {
        StarterModels.recommended(budget: budget, installed: installedIDs)
    }

    /// Up to three models spanning what this phone can actually hold.
    ///
    /// Built from the same fit verdict the Models tab uses, so the intro can
    /// never offer something that will be killed on load, and it always
    /// contains `recommendedStarter`.
    var starterModels: [ModelRecord] {
        StarterModels.shortlist(budget: budget, installed: installedIDs)
    }

    /// Already-downloaded models, by id. Excluded from the intro: on a replay
    /// from Settings the list would otherwise offer to fetch things this phone
    /// has had for weeks.
    private var installedIDs: Set<String> { Set(installed.map(\.id)) }

    // MARK: - Downloads

    /// The downloads worth mentioning, in a stable order.
    ///
    /// Active first: a download in progress outranks a notice about one that
    /// finished, and the order must not depend on dictionary iteration or a
    /// row swaps places at random while someone is reading it.
    var visibleTransfers: [ModelTransfer] {
        transfers.values
            .filter { $0.isWorthShowing() }
            .sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                return $0.record.displayName < $1.record.displayName
            }
    }

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
                    await MainActor.run { self.publishProgress(progress) }
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
                    // that was wanted. The same when what is resident cannot
                    // read the day and this one can — the reason anybody fetches
                    // a second brain — so "tap the name to load it" is never
                    // the last step of an upgrade. A brain that already reads
                    // the day is not swapped out from under a conversation —
                    // unless it is the brain the person chose: picked in the
                    // intro over Apple's model, the download is the choice and
                    // Apple's model only stood in while it arrived, so it takes
                    // over the moment it lands rather than at the next launch.
                    let arrived = self.catalog.first { $0.id == model.id } ?? model
                    let wasChosen = self.brainChoice == .downloaded(id: model.id)
                    return wasChosen || BrainStatus.shouldLoadArrival(
                        current: self.brainStatus,
                        arrivedReadsYourDay: arrived.dayAccess().readsYourDay
                    )
                }
                if shouldLoad {
                    // Not in the middle of somebody's reply: a brain switch
                    // stops it, and an upgrade is not worth an answer cut off
                    // halfway. Replies on this phone take seconds.
                    while await MainActor.run(body: { self.isGenerating }) {
                        try? await Task.sleep(for: .seconds(1))
                    }
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
        if await engine.loadedModel()?.id == model.id {
            // The file is about to go, not just the memory. A scheduled run
            // reading through it would be decoding from a deleted mapping —
            // unless the phone is on Apple's model, where no run is.
            if !isUsingBuiltInBrain { await cancelScheduleSweep() }
            await engine.unload()
            await recalibrateAfterUnload()
        }
        try? await store.delete(model)
        installed = await store.installed()
        // The phone's own brain may have been the one removed: decided again,
        // which is Apple's model where this phone has it, else the next
        // download — never a phone left with no brain while one could answer.
        await applyEffectiveBrain()
    }

    private static let rateWindow: TimeInterval = 8

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
        lastPublishedProgress[id] = nil
    }

    /// Puts one progress report on screen — or does not.
    ///
    /// URLSession reports many times a second, and every report used to move
    /// `transfers`: the banner, Today's card and the intro all redrew, and the
    /// Live Activity was updated, on each one. On a slow screen two of those
    /// redraws could land between the banner's number and the card's, which is
    /// how one screenshot showed 62% and 71% for the same download. Now a
    /// report is shown when the whole percentage has moved and a quarter of a
    /// second has passed, or every two seconds regardless — so a long, slow
    /// download still visibly moves — and always for the first and the last.
    /// The rate is sampled from every report; only what is drawn is thinned.
    private func publishProgress(_ progress: DownloadProgress) {
        let id = progress.modelID
        recordSample(progress)
        let now = Date()
        let percent = Int((progress.fraction * 100).rounded(.down))
        var isFirst = true
        if case .running = transfers[id]?.state { isFirst = false }
        let isLast = progress.totalBytes > 0 && progress.receivedBytes >= progress.totalBytes
        if !isFirst, !isLast, let last = lastPublishedProgress[id] {
            let elapsed = now.timeIntervalSince(last.at)
            guard (percent != last.percent && elapsed >= 0.25) || elapsed >= 2 else { return }
        }
        lastPublishedProgress[id] = (now, percent)
        transfers[id]?.advance(to: .running(progress))
    }

    // MARK: - Loading and unloading

    /// `remember: false` for the restore at launch — reloading what was already
    /// chosen should not overwrite the choice, and a fallback certainly should
    /// not silently become the new preference.
    func loadModel(_ model: ModelRecord, remember: Bool = true) async {
        // Somebody picking a download is also picking it over Apple's model,
        // so the choice is recorded and the phone switches before the load.
        // A load the app makes on its own (`remember: false`) never changes
        // the choice — and while the phone is on Apple's model, such a load
        // only ever serves other devices.
        if remember {
            brainChoice = .downloaded(id: model.id)
            brainChoice?.save()
            await phoneBrain.use(.downloaded(id: model.id))
        }
        // The same argument as the reply below, for the run nobody can see. A
        // scheduled generation holds the engine's gate exactly as a chat one
        // does, so a load issued under it blocks for as long as it takes — and
        // it is decoding against weights this call is about to unmap. Awaited,
        // so the gate is genuinely free by the time `engine.load` asks for it.
        await cancelScheduleSweep()
        // The engine serialises everything that touches the llama context,
        // so a load issued mid-generation simply blocked — for minutes, with
        // every button greyed and nothing on screen explaining why. The reply
        // is stopped first and says "Stopped." itself; the brief, which holds
        // the same gate, is stopped with it.
        if isGenerating { stopGenerating() }
        cancelBriefGeneration()
        isLoadingModel = true
        loadingModelID = model.id
        // Everything still holding the engine — a reply winding down after
        // Stop, a request from another device, anything queued behind them —
        // is stopped now rather than finished first. Cancelling a task only
        // asks; this is the engine being told, so the switch is not a minute
        // of waiting on a brain that is on its way out.
        await engine.interrupt()
        // Read once for both outcomes, because the question these two events
        // exist to answer is asked along that axis — whether 4 GB phones can
        // hold 3B models is not visible in any single device's failure.
        let ramClass = AnalyticsMapping.ramClass(bytes: budget.physicalMemoryBytes)
        // Monotonic rather than Date: a load is tens of seconds of memory
        // pressure on a phone, and a clock correction during one would put a
        // negative duration in a column that cannot mean anything by it.
        let started = ContinuousClock.now
        var loaded = false
        do {
            try await engine.load(model: model)
            loaded = true
            analytics.record(.modelLoadSucceeded(
                modelID: model.id,
                ramClass: ramClass,
                loadMilliseconds: Int(started.duration(to: .now) / .milliseconds(1))
            ))
            // The engine's verdict before the id, so nothing reading
            // `brainStatus` sees a brain that reads the day reported, for a
            // moment, as one that cannot — and the brief, which decides on the
            // same verdict, does not decide on a stale one.
            await refreshToolGate()
            // From the engines rather than `model.id`: while the phone is on
            // Apple's model this download is the server's, not the phone's.
            await syncResidency()
            loadErrors[model.id] = nil
            lastLoadFailure = nil
            // This model is resident right now, so its estimate is no longer a
            // prediction — it is a measurement of what this device tolerates.
            // Recording it is what makes the next verdict better than a guess.
            budget.recordSuccessfulLoad(of: model)
            // And take a live reading while the model is resident, which is the
            // only moment the pressure signal is worth anything. It moves
            // `budget.pressure` and deliberately nothing else — the fit badges
            // on the Models tab do not shift because a model loaded.
            budget.refreshHeadroom()
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
            await syncResidency()
            loadErrors[model.id] = (error as? LocalizedError)?.errorDescription
                ?? "Could not load \(model.displayName)."
            // The engine's text stays on the Brain page; the status everyone
            // else reads gets a sentence a person can act on.
            lastLoadFailure = (model.id, BrainStatus.loadFailureSentence(for: AnalyticsMapping.loadReason(for: error)))
        }
        // Here and not in a `defer`: what follows has to see the load as over.
        isLoadingModel = false
        loadingModelID = nil
        guard loaded else { return }
        // A question asked while this brain was on its way goes now.
        sendWaitingQuestionIfReady()
        // A brain has just arrived, and this morning's brief is still the
        // template one. Rewriting it in the model's own words here is the
        // whole payoff of the download, and nothing else in the app would
        // notice the moment it became possible. Not awaited: a load during
        // launch must not wait on EventKit.
        Task { await refreshBriefIfStillTemplate() }
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
        guard await engine.loadedModel() != nil else { return }
        // Freeing the memory means unmapping weights a scheduled run may be
        // decoding through. Same reason as the reply below, and the same
        // reason `loadModel` does it. On Apple's model the phone's own work
        // is not running through these weights, so it is left alone.
        if !isUsingBuiltInBrain {
            await cancelScheduleSweep()
            if isGenerating { stopGenerating() }
            cancelBriefGeneration()
        }
        await engine.unload()
        await recalibrateAfterUnload()
        await syncResidency()
        offloadNotice = serverShouldRun
            ? "Memory freed. The next request from a connected device loads it again."
            : "Memory freed. The brain is still on this phone."
    }

    func dismissOffloadNotice() { offloadNotice = nil }

    /// Takes a memory reading now that nothing is resident.
    ///
    /// Only ever called straight after an unload. A reading taken with a model
    /// in memory measures the model rather than the device, and the running
    /// maximum this feeds is only meaningful if every sample is comparable.
    private func recalibrateAfterUnload() async {
        budget.recordCleanStateMemory()
        await store.updateBudget(budget)
    }

    /// The single place the resident-model mirror changes.
    ///
    /// The transcript is never touched here. This method used to clear it on
    /// any change — and the server loads a brain on demand whenever a request
    /// names one, so a curl from anywhere on the network could erase the
    /// phone user's conversation. It then said "Switched to smollm2-360m…",
    /// raw ids and all; a brain changing is not something a conversation needs
    /// to be told, so it says nothing.
    func syncLoadedModel(_ id: String?) {
        guard id != loadedModelID else { return }
        loadedModelID = id
        modelSwitchNotice = nil
        // Whether the assistant tools are live is a property of the resident
        // model, so it is re-read exactly where the resident model changes —
        // which includes the swaps this app did not initiate. A network client
        // loading Llama 3.2 1B silently turns the tools off, and the Settings
        // row has to say so rather than keep showing the last model's answer.
        Task {
            await refreshToolGate()
            sendWaitingQuestionIfReady()
        }
    }

    // MARK: - Status

    /// Where the brain stands, as every screen should read it — see
    /// `BrainStatus`. Read this instead of combining `loadedModelID`,
    /// `isLoadingModel`, the downloads and the tool gate.
    var brainStatus: BrainStatus {
        var inputs = BrainStatus.Inputs(
            resident: loadedModelID.map { id in
                BrainStatus.Resident(
                    choice: id == ModelRecord.builtInID ? .builtIn : .downloaded(id: id),
                    readsYourDay: residentReadsYourDay(id)
                )
            },
            // A download loading for other devices is not the phone's brain
            // loading, and must not turn a ready Apple model into "getting
            // ready" for as long as it takes.
            isLoading: isLoadingModel && !isUsingBuiltInBrain,
            arriving: arrivingBrain,
            hasDownloaded: !installed.isEmpty,
            loadFailure: lastLoadFailure?.sentence
        )
        // Apple's model chosen and not answering yet: arriving while Apple
        // downloads it (no fraction — iOS does not say), or one plain sentence
        // naming the one thing the user can do about it.
        if isUsingBuiltInBrain, inputs.resident == nil {
            switch builtInAvailability {
            case .gettingReady:
                inputs.arriving = inputs.arriving ?? BrainStatus.Arrival()
            case .turnedOff:
                inputs.loadFailure = SystemModelFailure.turnedOff.sentence
            case .unsupportedLanguage:
                inputs.loadFailure = SystemModelFailure.unsupportedLanguage.sentence
            case .available, .notEligible:
                break
            }
        }
        return BrainStatus.derive(inputs)
    }

    /// The engine's verdict once it has one, the catalogue's until then.
    private func residentReadsYourDay(_ id: String) -> Bool {
        // Apple's model is always handed the tools.
        if id == ModelRecord.builtInID { return true }
        guard let record = catalog.first(where: { $0.id == id }) else {
            return personalDataToolGate.registersTools
        }
        return record.dayAccess(resident: personalDataToolGate).readsYourDay
    }

    /// The download that would bring a brain, if one is running.
    private var arrivingBrain: BrainStatus.Arrival? {
        guard let transfer = transfers.values
            .filter(\.isActive)
            .min(by: { $0.record.displayName < $1.record.displayName })
        else { return nil }
        return BrainStatus.Arrival(
            fraction: transfer.progress?.fraction,
            secondsLeft: pace(for: transfer.id)?.secondsRemaining
        )
    }

    /// Puts a downloaded brain into memory when nothing is answering and
    /// nothing is on its way in — the remembered one first, and never the one
    /// that has just failed to load, which would fail the same way.
    func loadDownloadedBrainIfIdle() {
        // On Apple's model a question waits for Apple's model — it may be
        // arriving, or one switch away in Settings — and a gigabyte of weights
        // is not loaded behind the user's choice to answer it.
        guard !isUsingBuiltInBrain else { return }
        guard loadedModelID == nil, !isLoadingModel else { return }
        let remembered = UserDefaults.standard.string(forKey: Keys.loadedModel)
        let candidates = installed
            .filter { $0.id != lastLoadFailure?.id }
            .sorted { first, _ in first.id == remembered }
        guard let pick = candidates.first else { return }
        Task { await loadModel(pick, remember: false) }
    }

    // MARK: - Residency

    /// Called whenever this device generates something itself. Requests from
    /// the network are noticed separately, from the request log — the server
    /// talks to the engine directly and never comes through here.
    func noteActivity() { lastLocalActivity = Date() }

    func restartIdleWatch() {
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
        // The download in memory, whoever it serves. Apple's model is the OS's
        // to keep or release, so only these weights are ever ours to free.
        guard let resident = await engine.loadedModel()?.id else { return }

        // The later of the two clocks. Serving a laptop all afternoon without
        // touching the phone still counts as being in use, and unloading
        // underneath a working coding agent would be the exact opposite of
        // what this setting is for.
        let lastServed = await server.log.all().last?.date ?? .distantPast
        let lastAny = max(lastLocalActivity, lastServed)
        guard Date().timeIntervalSince(lastAny) >= Double(idleOffloadSeconds) else { return }

        await engine.unload()
        await recalibrateAfterUnload()
        await syncResidency()
        // Put back on the next visit only if it was the phone's brain; one
        // held for other devices reloads on their next request by itself.
        if !isUsingBuiltInBrain { autoReleased = (resident, .idle) }
    }

    func suppressAutoRelease(_ reason: String) { releaseSuppressions.insert(reason) }
    func resumeAutoRelease(_ reason: String) { releaseSuppressions.remove(reason) }

    func releaseForBackground() async {
        // Before anything else: suspension is the last moment this process is
        // guaranteed to run again, and the debounced save may still be pending.
        await flushConversation()

        // The timer first, then the run it may have started. A `.deskMode`
        // sweep asserts that a model may run here, and in the background that
        // assertion is false — Metal refuses a backgrounded app's command
        // buffers, so an unattended generation does not get slower, it fails.
        // Cancelling turns that into a firing that stays owed and is retried on
        // the way back, rather than a dead run nothing explains; and it is
        // awaited so the record lands before the process is suspended.
        deskSweep?.cancel()
        deskSweep = nil
        await cancelScheduleSweep()
        // Same argument, one screen up: a brief being written when the app is
        // suspended is a generation Metal will refuse rather than slow down,
        // and the template it would have replaced is already published.
        cancelBriefGeneration()

        guard autoOffloadInBackground, releaseSuppressions.isEmpty else { return }
        // The download in memory, whoever it serves; Apple's model is the OS's.
        guard let resident = await engine.loadedModel()?.id else { return }
        // The socket does not survive suspension either, so nothing can arrive
        // to be served while the weights are gone. Holding them costs the app
        // its life: a suspended process sitting on two gigabytes is the first
        // thing the kernel reclaims, and the user experiences that as the app
        // having quit itself.
        let wasPhoneBrain = !isUsingBuiltInBrain
        if wasPhoneBrain, isGenerating { stopGenerating() }
        await engine.unload()
        await recalibrateAfterUnload()
        await syncResidency()
        if wasPhoneBrain { autoReleased = (resident, .background) }
    }

    /// Puts back what the app took away, and nothing else.
    func restoreAutoReleasedModel() async {
        guard let released = autoReleased else { return }
        guard loadedModelID == nil else { autoReleased = nil; return }
        guard let record = catalog.first(where: { $0.id == released.id }) else {
            autoReleased = nil
            return
        }
        autoReleased = nil
        await loadModel(record, remember: false)
    }

    // MARK: - Which brain: built into iPhone, or downloaded

    /// The brain answering the phone today: the user's choice where it can
    /// answer, otherwise the fallback `BrainChoice.effective` defines — and on
    /// a fresh install with nothing chosen, Apple's model whenever this phone
    /// has it.
    var effectiveBrain: BrainChoice? {
        BrainChoice.effective(chosen: brainChoice, builtIn: builtInAvailability, installed: installedPreferenceOrder)
    }

    var isUsingBuiltInBrain: Bool { effectiveBrain == .builtIn }

    /// How the Brain page and onboarding present Apple's model on this phone.
    var builtInOffer: BuiltInBrainOffer { .make(for: builtInAvailability) }

    /// The brain to pre-select and mark "Recommended": Apple's model when it
    /// is ready, otherwise the download chosen for this phone, and only ever
    /// one that reads the day.
    var recommendedBrain: BrainChoice? {
        BrainChoice.recommended(builtIn: builtInAvailability, download: BrainRecommendation.recommended(for: budget))
    }

    /// Chooses Apple's model for the phone.
    ///
    /// The answer being written comes from the brain being left, so it is
    /// stopped, as switching between downloads stops it. A download held only
    /// for the phone is then a gigabyte or two doing nothing, and is let go;
    /// one the server is using stays where it is.
    func useBuiltInBrain() async {
        brainChoice = .builtIn
        BrainChoice.builtIn.save()
        if isGenerating { stopGenerating() }
        cancelBriefGeneration()
        await applyEffectiveBrain()
        if isUsingBuiltInBrain, !serverShouldRun, await engine.loadedModel() != nil {
            await engine.unload()
            await recalibrateAfterUnload()
            await syncResidency()
        }
    }

    /// Chooses a downloaded brain for the phone and puts it in memory.
    func useDownloadedBrain(id: String) async {
        guard let record = installed.first(where: { $0.id == id }) else { return }
        await loadModel(record)
    }

    /// Puts the brain that should answer the phone in charge, and in memory.
    ///
    /// For a download, the chosen one first and then the rest, which is the
    /// launch behaviour this replaces: a remembered download can stop being
    /// loadable — a vision model on a simulator, a file that went missing —
    /// and sitting with nothing resident means every question fails while the
    /// Brain page shows a healthy row.
    func applyEffectiveBrain() async {
        let effective = effectiveBrain
        await phoneBrain.use(effective)
        switch effective {
        case .builtIn:
            await loadBuiltInBrain()
        case let .downloaded(id):
            // Already in memory — the server may have put it there — costs
            // nothing.
            if await engine.loadedModel()?.id == id {
                await refreshToolGate()
                await syncResidency()
                sendWaitingQuestionIfReady()
                return
            }
            var candidates = installed
            if let index = candidates.firstIndex(where: { $0.id == id }) {
                candidates.insert(candidates.remove(at: index), at: 0)
            }
            for candidate in candidates {
                await loadModel(candidate, remember: false)
                if loadedModelID != nil { break }
            }
        case nil:
            await refreshToolGate()
            await syncResidency()
        }
    }

    /// Re-reads Apple's model's availability off the main thread, remembers
    /// it for the next launch's first frame, and says whether it moved.
    @discardableResult
    func refreshBuiltInAvailability() async -> Bool {
        let now = await Task.detached(priority: .userInitiated) { SystemModelEngine.availability }.value
        UserDefaults.standard.set(now.rawValue, forKey: Self.builtInAvailabilityKey)
        guard now != builtInAvailability else { return false }
        builtInAvailability = now
        return true
    }

    /// Last launch's answer, so the first frame of the Brain page and the
    /// intro is right before the real read lands.
    nonisolated static func rememberedBuiltInAvailability() -> BuiltInBrainAvailability {
        UserDefaults.standard.string(forKey: builtInAvailabilityKey)
            .flatMap(BuiltInBrainAvailability.init(rawValue:)) ?? .notEligible
    }

    nonisolated static let builtInAvailabilityKey = "pocketd.builtInAvailability"

    /// Both residencies, from the engines: the phone's brain into
    /// `loadedModelID`, the server's download into `downloadedResidentID`.
    func syncResidency() async {
        syncLoadedModel(await phoneBrain.loadedModel()?.id)
        downloadedResidentID = await engine.loadedModel()?.id
    }

    /// Apple's model in charge. Cheap — the OS holds the model — and it
    /// succeeds while Apple Intelligence is off or still arriving, so the
    /// choice takes and starts answering the moment it can; only a phone that
    /// can never run it refuses.
    private func loadBuiltInBrain() async {
        do {
            try await phoneBrain.load(model: .builtIn)
            if lastLoadFailure?.id == ModelRecord.builtInID { lastLoadFailure = nil }
        } catch {
            lastLoadFailure = (ModelRecord.builtInID, BuiltInBrainOffer.unavailableFootnote)
        }
        await refreshToolGate()
        await syncResidency()
        sendWaitingQuestionIfReady()
        // The template brief upgrades itself, as it does when a download
        // finishes loading.
        Task { await refreshBriefIfStillTemplate() }
    }

    /// Installed downloads, the remembered one first.
    private var installedPreferenceOrder: [String] {
        let remembered = UserDefaults.standard.string(forKey: Keys.loadedModel)
        var ids = installed.map(\.id)
        if let remembered, let index = ids.firstIndex(of: remembered) {
            ids.insert(ids.remove(at: index), at: 0)
        }
        return ids
    }
}
