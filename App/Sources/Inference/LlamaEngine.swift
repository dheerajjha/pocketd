import Foundation
import PocketdKit
import LocalLLMClient
import LocalLLMClientLlama

/// `InferenceEngine` backed by llama.cpp, via LocalLLMClient.
///
/// Sampling parameters (temperature, top-k, top-p) are fixed when the model is
/// loaded, because llama.cpp binds them to the context. Per-request overrides in
/// the OpenAI and Ollama payloads are therefore honoured for `max_tokens` and
/// stop sequences, which this layer enforces itself, but not for sampling —
/// changing those means re-initialising the context, which on a phone costs more
/// than the request is worth. The server's Settings screen is where they live.
actor LlamaEngine: InferenceEngine {
    nonisolated var backendName: String { "llama.cpp" }

    private var client: AnyLLMClient?
    private var model: ModelRecord?
    private let fileURL: @Sendable (ModelRecord) -> URL
    private var sampling: SamplingProfile

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

    func updateSampling(_ profile: SamplingProfile) async throws {
        guard profile != sampling else { return }
        sampling = profile
        // Sampling lives in the context, so a change only takes effect on reload.
        if let model { try await load(model: model) }
    }

    func load(model: ModelRecord) async throws {
        let url = fileURL(model)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw InferenceError.modelNotFound(model.id)
        }
        // Drop the previous context first. Holding two sets of weights while the
        // new one loads is the single most reliable way to get jetsammed.
        client = nil
        self.model = nil

        do {
            let llama = try await LocalLLMClient.llama(
                url: url,
                parameter: .init(
                    context: min(model.contextLength, sampling.contextTokens),
                    temperature: sampling.temperature,
                    topK: sampling.topK,
                    topP: sampling.topP
                )
            )
            client = AnyLLMClient(llama)
            self.model = model
        } catch {
            throw InferenceError.backend(String(describing: error))
        }
    }

    func unload() {
        client = nil
        model = nil
    }

    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        guard let client, let model else { throw InferenceError.noModelLoaded }
        guard request.modelID.isEmpty || request.modelID == model.id else {
            throw InferenceError.modelMismatch(requested: request.modelID, loaded: model.id)
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
        let stops = request.options.stopSequences

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emitted = ""
                var reason = FinishReason.stop
                do {
                    for try await chunk in try await client.textStream(from: input) {
                        if Task.isCancelled {
                            continuation.yield(.finished(
                                reason: .cancelled,
                                usage: TokenUsage(promptTokens: promptTokens, completionTokens: estimateTokens(emitted))
                            ))
                            continuation.finish()
                            return
                        }

                        emitted += chunk

                        // Stop sequences are checked against the accumulated text
                        // rather than the chunk, because a stop string can and
                        // does straddle a token boundary.
                        if let stop = stops.first(where: { !$0.isEmpty && emitted.contains($0) }) {
                            let truncated = String(emitted.prefix(upTo: emitted.range(of: stop)!.lowerBound))
                            let tail = String(truncated.dropFirst(emitted.count - chunk.count))
                            if !tail.isEmpty { continuation.yield(.token(tail)) }
                            emitted = truncated
                            reason = .stop
                            break
                        }

                        if let limit, estimateTokens(emitted) >= limit {
                            continuation.yield(.token(chunk))
                            reason = .length
                            break
                        }

                        continuation.yield(.token(chunk))
                    }
                    continuation.yield(.finished(
                        reason: reason,
                        usage: TokenUsage(promptTokens: promptTokens, completionTokens: estimateTokens(emitted))
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: InferenceError.backend(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
