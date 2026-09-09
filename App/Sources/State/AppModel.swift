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

    private enum Keys {
        static let systemPrompt = "pocketd.systemPrompt"
        static let serverShouldRun = "pocketd.serverShouldRun"
    }

    init() {
        let hasEntitlement = Bundle.main.object(forInfoDictionaryKey: "PocketdHasIncreasedMemoryLimit") as? Bool ?? false
        budget = .current(hasIncreasedMemoryLimit: hasEntitlement)

        let directory = (try? ModelStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Models")
        let store = ModelStore(directory: directory, budget: budget)
        self.store = store

        let engine = LlamaEngine(fileURL: { store.fileURL(for: $0) })
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
            models: { await store.installed() }
        )

        systemPrompt = UserDefaults.standard.string(forKey: Keys.systemPrompt) ?? systemPrompt
        serverShouldRun = UserDefaults.standard.bool(forKey: Keys.serverShouldRun)
    }

    func bootstrap() async {
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
        observers.append(Task { [server, engine] in
            for await entries in await server.log.stream() {
                // The server loads models behind the app's back when a request
                // names one that is not resident, so the badge and the Chat tab
                // would otherwise keep pointing at a model that is gone.
                let resident = await engine.loadedModel()?.id
                await MainActor.run {
                    self.log = entries
                    self.syncLoadedModel(resident)
                }
            }
        })

        // Restore the previously loaded model so a relaunch does not silently
        // serve nothing to a client that was working a minute ago.
        if let first = installed.first {
            await loadModel(first)
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
        } catch {
            lastServerError = friendlyMessage(for: error)
        }
    }

    func stopServer() async {
        serverShouldRun = false
        UserDefaults.standard.set(false, forKey: Keys.serverShouldRun)
        await server.stop()
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
        // Not covered by the observer: toggling keep-awake in Settings produces
        // no server transition, so the new setting would not take hold until the
        // next start or stop.
        applyIdleTimer(running: await server.liveState().isRunning)
    }

    func clearLog() async {
        await server.log.clear()
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

    private func friendlyMessage(for error: any Error) -> String {
        let text = String(describing: error)
        if text.contains("48") || text.lowercased().contains("in use") {
            return "Port \(configuration.port) is already in use. Pick another port."
        }
        return text
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

    func loadModel(_ model: ModelRecord) async {
        isLoadingModel = true
        defer { isLoadingModel = false }
        do {
            try await engine.load(model: model)
            syncLoadedModel(model.id)
        } catch {
            syncLoadedModel(nil)
            downloadErrors[model.id] = String(describing: error)
        }
    }

    /// The single place the resident-model mirror changes. A transcript belongs
    /// to the model that produced it, so a swap — whoever caused it — clears it.
    private func syncLoadedModel(_ id: String?) {
        guard id != loadedModelID else { return }
        loadedModelID = id
        conversation.removeAll()
    }

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

        let request = GenerationRequest(
            modelID: loadedModelID ?? "",
            messages: messages,
            options: GenerationOptions(maxTokens: configuration.maxContextTokens)
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
