import Foundation
import PocketdKit
import LocalLLMClient
import LocalLLMClientLlama

/// `InferenceEngine` backed by llama.cpp, via LocalLLMClient.
///
/// Everything that touches the underlying `llama_context` is serialised through
/// one gate. This is not tidiness: `llama_context` is not thread-safe, and the
/// app has two independent callers — the Chat tab and the HTTP server — sharing
/// a single engine instance. Worse, dropping the client while a generation is in
/// flight runs `llama_free` on a context another thread is inside, which is a
/// hard crash rather than garbled output. Loading, unloading and generating all
/// take the gate for exactly that reason.
///
/// Sampling parameters (temperature, top-k, top-p) are fixed when the model is
/// loaded, because llama.cpp binds them to the context. Per-request overrides in
/// the OpenAI and Ollama payloads are therefore honoured for `max_tokens` and
/// stop sequences, which this layer enforces itself, but not for sampling.
actor LlamaEngine: InferenceEngine {
    nonisolated var backendName: String { "llama.cpp" }

    private var client: AnyLLMClient?
    private var model: ModelRecord?
    /// Set when a generation was cancelled part-way. llama.cpp keeps a KV cache
    /// and LocalLLMClient keeps a prompt cache on top of it, and a generation
    /// that stops mid-decode leaves both describing tokens that were never
    /// finished. The next request reuses that prefix and the model emits
    /// garbage — verified on a device: a clean context answers "Hello! I am
    /// Smol LM…", and after one abandoned stream the same prompt returns an
    /// empty string. Context.clear() would fix it in one call but is not
    /// reachable outside LocalLLMClient's own DEBUG builds, so the context is
    /// rebuilt instead, lazily, on the next request that needs it.
    private var contextIsDirty = false
    private let fileURL: @Sendable (ModelRecord) -> URL
    private var sampling: SamplingProfile

    /// Who holds the context right now, and who is queued for it.
    private var holder: UUID?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waitOrder: [UUID] = []

    struct SamplingProfile: Sendable, Equatable {
        var temperature: Float = 0.8
        var topK: Int = 40
        var topP: Float = 0.95
        var contextTokens: Int = 4096
    }

    init(fileURL: @escaping @Sendable (ModelRecord) -> URL, sampling: SamplingProfile = SamplingProfile()) {
        self.fileURL = fileURL
        self.sampling = sampling
    }

    func loadedModel() -> ModelRecord? { model }

    // MARK: - The gate

    private func acquire(_ token: UUID) async throws {
        guard holder != nil else {
            holder = token
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checked here as well as by the handler: a task cancelled before
                // its continuation is stored would otherwise queue forever.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[token] = continuation
                waitOrder.append(token)
            }
        } onCancel: {
            Task { await self.abandon(token) }
        }
        holder = token
    }

    /// Idempotent: a second release with the same token is a no-op, which is what
    /// lets both a `defer` and a stream's `onTermination` call it safely.
    private func release(_ token: UUID) {
        guard holder == token else { return }
        holder = nil
        while let next = waitOrder.first {
            waitOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: next) {
                continuation.resume()
                return
            }
        }
    }

    /// A queued waiter whose task was cancelled removes itself, or the gate
    /// hands the slot to a dead task and everything after it hangs.
    private func abandon(_ token: UUID) {
        guard let continuation = waiters.removeValue(forKey: token) else { return }
        waitOrder.removeAll { $0 == token }
        continuation.resume(throwing: CancellationError())
    }

    // MARK: - Residency

    func updateSampling(_ profile: SamplingProfile) async throws {
        guard profile != sampling else { return }
        sampling = profile
        // Sampling lives in the context, so a change only takes effect on reload.
        if let model { try await load(model: model) }
    }

    func load(model: ModelRecord) async throws {
        let token = UUID()
        try await acquire(token)
        defer { release(token) }
        try await loadHoldingGate(model)
    }

    /// The load itself, for callers that already hold the gate. Taking it twice
    /// would deadlock the actor against itself.
    private func loadHoldingGate(_ model: ModelRecord) async throws {
        let url = fileURL(model)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw InferenceError.modelNotFound(model.id)
        }
        // Drop the previous context first. Holding two sets of weights while the
        // new one loads is the most reliable way to get jetsammed. Safe only
        // because the gate guarantees nothing is decoding right now.
        client = nil
        self.model = nil

        do {
            let llama = try await LocalLLMClient.llama(
                url: url,
                parameter: .init(
                    context: min(model.contextLength, sampling.contextTokens),
                    temperature: sampling.temperature,
                    topK: sampling.topK,
                    topP: sampling.topP,
                    // LocalLLMClient defaults to pausing generation on
                    // UIApplication.willResignActive, checked before every
                    // single token. That is right for a chat app and ruinous
                    // for a server: a notification banner, a Control Center
                    // swipe or the app switcher freezes an in-flight stream
                    // with the socket still open and no error, so the client
                    // hangs until its own read timeout. A server must fail
                    // loudly or not at all — never stall silently.
                    options: .init(disableAutoPause: true)
                )
            )
            client = AnyLLMClient(llama)
            self.model = model
            contextIsDirty = false
        } catch {
            throw InferenceError.backend(String(describing: error))
        }
    }

    func unload() async {
        let token = UUID()
        // If acquisition is cancelled the caller is going away anyway, and
        // freeing the context regardless is the crash this gate exists to stop.
        guard (try? await acquire(token)) != nil else { return }
        defer { release(token) }
        client = nil
        model = nil
    }

    // MARK: - Generation

    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, any Error>.makeStream()
        let token = UUID()

        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }
            await self.run(request, token: token, continuation: continuation)
        }
        // An HTTP client that disconnects mid-stream drops the sequence without
        // draining it, so the slot has to be freed from here too.
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            Task { await self?.release(token) }
        }
        return stream
    }

    private func run(
        _ request: GenerationRequest,
        token: UUID,
        continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation
    ) async {
        do {
            try await acquire(token)
        } catch {
            continuation.finish(throwing: InferenceError.cancelled)
            return
        }
        defer { release(token) }

        // Read residency AFTER acquiring: a load may have swapped the model
        // while this request was queued.
        guard var client = self.client, let model else {
            continuation.finish(throwing: InferenceError.noModelLoaded)
            return
        }

        // Pay for a previous cancellation now, once, rather than serving
        // garbage from a poisoned cache.
        if contextIsDirty {
            do {
                try await loadHoldingGate(model)
                guard let rebuilt = self.client else {
                    continuation.finish(throwing: InferenceError.noModelLoaded)
                    return
                }
                client = rebuilt
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }
        guard request.modelID.isEmpty || request.modelID == model.id else {
            continuation.finish(throwing: InferenceError.modelMismatch(requested: request.modelID, loaded: model.id))
            return
        }

        // Defence in depth: the Chat tab calls the engine directly, so the
        // route-layer guard does not cover it, and an oversized prompt here is a
        // process-killing trap inside llama.cpp rather than a thrown error.
        do {
            try ContextGuard(contextTokens: min(model.contextLength, sampling.contextTokens))
                .check(request.messages)
        } catch {
            continuation.finish(throwing: InferenceError.contextExhausted)
            return
        }

        let input = LLMInput.chat(request.messages.map { message in
            switch message.role {
            case .system: .system(message.content)
            case .assistant: .assistant(message.content)
            case .user, .tool: .user(message.content)
            }
        })
        let promptTokens = estimateTokens(request.messages.map(\.content).joined(separator: "\n"))
        let limit = request.options.maxTokens
        let stops = request.options.stopSequences.filter { !$0.isEmpty }
        // Withhold the last `maxStop` characters so a stop sequence can never be
        // partially shipped before it completes. Holding back `maxStop - 1`
        // would be off by one: a stop of exactly that length starting at the
        // boundary would have its first character already sent.
        let holdBack = stops.map(\.count).max() ?? 0

        var produced = ""     // everything the model emitted, truncated at a stop
        var sent = 0          // characters already yielded downstream
        var reason = FinishReason.stop

        func offset(_ count: Int) -> String.Index {
            produced.index(produced.startIndex, offsetBy: count, limitedBy: produced.endIndex) ?? produced.endIndex
        }
        /// Yields everything not yet sent. Every exit from the loop must call
        /// this, or the withheld tail is silently dropped from the response.
        func flush() {
            guard sent < produced.count else { return }
            continuation.yield(.token(String(produced[offset(sent)...])))
            sent = produced.count
        }

        do {
            for try await chunk in try await client.textStream(from: input) {
                if Task.isCancelled {
                    reason = .cancelled
                    break
                }
                produced += chunk

                // Earliest match across all stops, not the first stop in the
                // array — otherwise a later-listed stop that occurs sooner is
                // missed and text past it is emitted.
                if let hit = stops.compactMap({ produced.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                    produced = String(produced[..<hit.lowerBound])
                    sent = min(sent, produced.count)
                    flush()
                    reason = .stop
                    break
                }

                if let limit, estimateTokens(produced) >= limit {
                    flush()
                    reason = .length
                    break
                }

                if holdBack > 0 {
                    let safe = max(sent, produced.count - holdBack)
                    if safe > sent {
                        continuation.yield(.token(String(produced[offset(sent)..<offset(safe)])))
                        sent = safe
                    }
                } else {
                    flush()
                }
            }
            flush()
            // Any generation that did not run to its natural end leaves the
            // caches describing tokens that were never decoded.
            if reason == .cancelled || Task.isCancelled { contextIsDirty = true }
            continuation.yield(.finished(
                reason: reason,
                // Counted from what was actually sent, so usage never describes
                // text the client did not receive.
                usage: TokenUsage(promptTokens: promptTokens, completionTokens: estimateTokens(produced))
            ))
            continuation.finish()
        } catch {
            contextIsDirty = true
            continuation.finish(throwing: InferenceError.backend(String(describing: error)))
        }
    }
}

/// Four characters per token is the usual English approximation. The exact count
/// would need the model's own tokenizer, which LocalLLMClient does not surface;
/// the number exists so that `usage` is populated rather than zero, and the
/// README says as much rather than letting anyone bill against it.
private func estimateTokens(_ text: String) -> Int {
    max(0, (text.count + 3) / 4)
}
