import Foundation

/// A deterministic engine used by the test suite and by the app's simulator
/// builds, where no real weights are available.
///
/// It exists so the entire HTTP surface can be exercised without a GPU: the
/// route tests are about status codes, SSE framing, and auth, and none of that
/// should depend on a 2 GB download.
public actor EchoEngine: InferenceEngine {
    public nonisolated var backendName: String { "echo" }

    private var model: ModelRecord?
    private let chunkSize: Int
    private let delay: Duration
    private let announcesToolCall: String?

    public let defaultSampling: SamplingParameters

    /// Every sampler this engine has been asked for, oldest first.
    ///
    /// Nothing here samples anything, so this is the only evidence that a
    /// `temperature` in a request body survived decoding, merging and the trip
    /// across the engine seam. Recorded rather than merely last-written so a
    /// test can assert that two identical requests really did resolve
    /// identically — which is the property `LlamaEngine` skips a rebuild on.
    public private(set) var receivedSampling: [SamplingParameters] = []

    public var lastSampling: SamplingParameters? { receivedSampling.last }

    /// The messages of the most recent request, exactly as the route layer built
    /// them.
    ///
    /// Here for the same reason `receivedSampling` is: a prompt the server
    /// rewrites on its way through — a date prepended, a system turn invented —
    /// is invisible in the response body, because nothing here reads the prompt
    /// to answer. The only place such a change shows up is what the engine was
    /// handed.
    public private(set) var receivedMessages: [ChatMessage] = []

    /// - Parameter announcesToolCall: When set, the stream opens with a
    ///   `.toolCallStarted` event naming this tool. Nothing here executes a
    ///   tool; the point is that every consumer of a `GenerationEvent` stream —
    ///   the two wire protocols especially — can be tested against an engine
    ///   that emits one, without a real model that decides to call one.
    /// - Parameter defaultSampling: stands in for what an operator set in
    ///   Settings, so the inheritance rule — a request keeps the server's value
    ///   for every field it stays silent about — is testable without weights.
    public init(
        model: ModelRecord? = .echo,
        chunkSize: Int = 4,
        delay: Duration = .zero,
        announcesToolCall: String? = nil,
        defaultSampling: SamplingParameters = .default
    ) {
        self.model = model
        self.chunkSize = chunkSize
        self.delay = delay
        self.announcesToolCall = announcesToolCall
        self.defaultSampling = defaultSampling
    }

    public func loadedModel() async -> ModelRecord? { model }

    public func load(model: ModelRecord) async throws { self.model = model }

    public func unload() async { model = nil }

    public func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        guard let model else { throw InferenceError.noModelLoaded }
        guard request.modelID.isEmpty || request.modelID == model.id else {
            throw InferenceError.modelMismatch(requested: request.modelID, loaded: model.id)
        }
        // Recorded before the rejections above would matter, but after them, so
        // the log describes requests that were actually served.
        receivedSampling.append(request.resolvedSampling(defaults: defaultSampling))
        receivedMessages = request.messages

        // Echo the last user turn back, which makes assertions in tests read as
        // "what went in came out" rather than depending on sampled text.
        let reply = request.messages.last(where: { $0.role == .user })?.content ?? ""
        let promptTokens = request.messages.reduce(0) { $0 + $1.content.count / 4 }
        let limited = request.options.maxTokens.map { String(reply.prefix($0)) } ?? reply
        let chunks = limited.chunked(into: chunkSize)
        let delay = self.delay
        let announcesToolCall = self.announcesToolCall

        return AsyncThrowingStream { continuation in
            let task = Task {
                if let announcesToolCall {
                    continuation.yield(.toolCallStarted(name: announcesToolCall))
                }
                for chunk in chunks {
                    if Task.isCancelled {
                        continuation.finish(throwing: InferenceError.cancelled)
                        return
                    }
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    continuation.yield(.token(chunk))
                }
                let reason: FinishReason = limited.count < reply.count ? .length : .stop
                continuation.yield(.finished(
                    reason: reason,
                    usage: TokenUsage(promptTokens: promptTokens, completionTokens: limited.count / 4)
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }
    }
}
