#if DEBUG && targetEnvironment(simulator)
import Foundation
import PocketdKit

/// The draft-safety UI tests use a separate temporary store and one generated
/// blue PNG. They neither open real chat files nor ask for Photos access.
enum EditorUITestFixture {
    enum Mode: String { case readOnly, writable }
    static let mode: Mode? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-pocketd.editorFixture"), args.indices.contains(i + 1) else { return nil }
        return Mode(rawValue: args[i + 1])
    }()
    static let directory: URL? = {
        guard let mode else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pocketd-editor-fixture-" + mode.rawValue)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if mode == .readOnly {
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            if fm.isWritableFile(atPath: dir.path) { return dir.appendingPathComponent(UUID().uuidString) }
        }
        return dir
    }()
    static let photo = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQDd8HAAGvASspU2xoAAAAAElFTkSuQmCC")!
}

/// A simulator fixture at PhoneBrain's cloud-engine boundary. Neither reading
/// its status nor asking it a question creates an Apple model or a session.
enum CloudUITestSupport {
    private enum Scenario: String {
        case available, near, limited, unsupported, offline, requestLimit
    }

    private static let scenario: Scenario? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-pocketd.testPCC"),
              arguments.indices.contains(index + 1) else { return nil }
        return Scenario(rawValue: arguments[index + 1])
    }()

    // A reproducible reset date, shared by the quota reading and stream error.
    private static let reset = Date(timeIntervalSince1970: 1_893_456_000)

    // Status is synchronous for the picker, but the request that consumes
    // the last allowance runs on the engine actor. Only this bit is shared.
    private final class Quota: @unchecked Sendable {
        private let lock = NSLock()
        private var exhausted = false
        var isExhausted: Bool { lock.withLock { exhausted } }
        func reachLimit() { lock.withLock { exhausted = true } }
    }
    private static let quota = Quota()

    static var status: AppleCloudStatus? {
        switch scenario {
        case nil: nil
        case .available, .offline: .available
        case .near: .approachingLimit
        case .limited: .limitReached(reset: reset)
        case .unsupported: .unavailable
        case .requestLimit: quota.isExhausted ? .limitReached(reset: reset) : .available
        }
    }

    static func makeEngine() -> (any PhoneAppleInference)? {
        scenario.map { FixtureEngine(scenario: $0) }
    }

    private actor FixtureEngine: PhoneAppleInference {
        nonisolated let backendName = "PCC UI test fixture (no Apple service)"
        let scenario: Scenario
        private var loaded = false

        init(scenario: Scenario) { self.scenario = scenario }

        var toolGate: ToolGate.Decision { loaded ? .declaredCapable : .noModelLoaded }
        var capabilityPlan: CapabilityBudget.Plan? { nil }
        func updateAbilities(calendar: Bool, reminders: Bool, health: Bool) {}

        func loadedModel() -> ModelRecord? {
            loaded && status?.canChoose == true ? .privateCloudCompute : nil
        }

        func load(model: ModelRecord) throws {
            guard model.id == ModelRecord.privateCloudCompute.id else { throw InferenceError.modelNotFound(model.id) }
            try checkAvailability()
            loaded = true
        }

        func unload() { loaded = false }

        private func checkAvailability() throws {
            if let failure = AppleCloudFailure(blocking: status ?? .unavailable) {
                throw InferenceError.privateCloud(failure)
            }
        }

        func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
            try await generate(request, toolsAllowed: true)
        }

        func generate(_ request: GenerationRequest, toolsAllowed: Bool) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
            let id = ModelRecord.privateCloudCompute.id
            guard request.origin.isThisPhone else { throw InferenceError.modelNotFound(id) }
            guard request.modelID == id else { throw InferenceError.modelMismatch(requested: request.modelID, loaded: id) }
            try checkAvailability()
            guard loaded else { throw InferenceError.noModelLoaded }

            if EditorUITestFixture.mode == .writable, scenario == .available, toolsAllowed,
               request.origin == .onDeviceChat, let question = request.messages.last,
               question.role == .user, question.content == "How active was I today?", question.images.isEmpty,
               request.messages.dropLast().contains(where: { $0.role == .user && $0.content == "How did I sleep last night?" }) {
                return AsyncThrowingStream { stream in
                    stream.yield(.token("Fixture followed up on the sleep answer without photos."))
                    stream.yield(.finished(reason: .stop, usage: TokenUsage()))
                    stream.finish()
                }
            }

            // Only the test's eight-digit challenge is reflected, never arbitrary
            // prompt/history or personal data. A background brief must not
            // consume the fixture's request-time limit before the user taps Send.
            guard request.origin == .onDeviceChat, toolsAllowed,
                  let nonce = request.messages.last(where: { $0.role == .user })?.content,
                  nonce.utf8.count == 8, nonce.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw InferenceError.privateCloud(.other)
            }

            return AsyncThrowingStream { stream in
                switch scenario {
                case .available, .near:
                    stream.yield(.token("PCC test fixture replied to probe \(nonce)."))
                    stream.yield(.finished(reason: .stop, usage: TokenUsage()))
                    stream.finish()
                case .offline:
                    stream.finish(throwing: InferenceError.privateCloud(.network))
                case .requestLimit:
                    stream.yield(.token("PCC test fixture began probe \(nonce)."))
                    quota.reachLimit()
                    stream.finish(throwing: InferenceError.privateCloud(.limitReached(reset: reset)))
                case .limited, .unsupported:
                    // These states were rejected before the request started.
                    stream.finish(throwing: InferenceError.privateCloud(.unavailable))
                }
            }
        }
    }
}
#endif
