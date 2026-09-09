import Foundation

public struct GenerationRequest: Sendable, Equatable {
    /// The model the client asked for. An engine may reject a request whose
    /// model is not the one currently resident, rather than silently answering
    /// with whatever happens to be loaded.
    public var modelID: String
    public var messages: [ChatMessage]
    public var options: GenerationOptions
    /// Defaults to the restricted case on purpose: a call site that forgets to
    /// set this gets the path with no access to personal data, not the
    /// privileged one. Fail closed.
    public var origin: RequestOrigin

    public init(
        modelID: String,
        messages: [ChatMessage],
        options: GenerationOptions = .default,
        origin: RequestOrigin = .network(host: "unknown", port: 0)
    ) {
        self.modelID = modelID
        self.messages = messages
        self.options = options
        self.origin = origin
    }
}

public enum FinishReason: String, Sendable, Codable {
    case stop
    case length
    case cancelled
}

public struct TokenUsage: Sendable, Codable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int { promptTokens + completionTokens }

    public init(promptTokens: Int = 0, completionTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum GenerationEvent: Sendable, Equatable {
    /// One or more characters of new assistant text. Engines are free to emit
    /// whatever granularity is natural for them; nothing downstream assumes a
    /// chunk is exactly one token.
    case token(String)
    /// A tool is about to run, and after it the model will be re-prompted from
    /// the beginning.
    ///
    /// This exists because a tool turn is slow in a way the user cannot see.
    /// The backend surfaces tool calls only once its token loop has fully
    /// drained, and resuming then re-renders and re-prefills the entire
    /// conversation — two complete prefills per tool turn. At the ~29 tok/s a
    /// phone manages that is seconds of nothing, which reads as a hang. A UI
    /// can show this as "checking…" and clear it on the next `.token`.
    ///
    /// Deliberately not on the wire: neither the OpenAI nor the Ollama
    /// streaming schema has a field for "the server is running a tool on your
    /// behalf", and inventing one breaks clients that parse strictly.
    case toolCallStarted(name: String)
    case finished(reason: FinishReason, usage: TokenUsage)
}

public enum InferenceError: Error, Sendable, Equatable {
    case noModelLoaded
    case modelNotFound(String)
    case modelMismatch(requested: String, loaded: String)
    case contextExhausted
    case cancelled
    case backend(String)
}

/// The seam between the HTTP surface and whatever actually runs the weights.
///
/// Everything above this protocol is plain Swift and unit-tested; everything
/// below it is llama.cpp, MLX, or Apple's Foundation Models. Keeping the seam
/// this narrow is what lets the server ship a new backend without the route
/// layer noticing.
public protocol InferenceEngine: Sendable {
    /// Short name for the backend, surfaced in `/health` so a client can tell
    /// what it is talking to. e.g. `"llama.cpp"`.
    var backendName: String { get }

    /// The model currently resident in memory, if any.
    func loadedModel() async -> ModelRecord?

    /// Tokens the loaded client will add to every prompt after the guard has
    /// checked it — tool schemas, mostly. Zero when nothing is registered.
    var promptOverheadTokens: Int { get async }

    /// Bring a model into memory, evicting whatever was there. On a phone there
    /// is only ever room for one.
    func load(model: ModelRecord) async throws

    func unload() async

    /// Stream a completion. The stream must terminate with exactly one
    /// `.finished` event, or throw.
    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error>
}

public extension InferenceEngine {
    /// Most engines add nothing.
    var promptOverheadTokens: Int { get async { 0 } }

    /// Convenience for non-streaming callers: drain the stream into one string.
    func complete(_ request: GenerationRequest) async throws -> (text: String, reason: FinishReason, usage: TokenUsage) {
        var text = ""
        var reason = FinishReason.stop
        var usage = TokenUsage()
        for try await event in try await generate(request) {
            switch event {
            case .token(let chunk):
                text += chunk
            case .toolCallStarted:
                // A buffered caller sees only the answer. The announcement
                // exists to fill the silence of a stream, and there is no
                // silence to fill here.
                break
            case .finished(let r, let u):
                reason = r
                usage = u
            }
        }
        return (text, reason, usage)
    }
}
