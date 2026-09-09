import Foundation

/// Decides whether a prompt is small enough to hand to the model.
///
/// This exists because llama.cpp does not fail gracefully on an oversized
/// prompt: LocalLLMClient's `llama_batch.add` hits a Swift assertion and the
/// process takes SIGTRAP. A crash report from a real device confirms it —
/// `llama_batch.add(id:pos:seq_ids:logits:)` inside `Context.decode(text:)`.
/// So a single large request from any client kills the whole server, taking
/// every other client's connection with it.
///
/// The estimate is deliberately pessimistic. Four characters per token is the
/// usual English average; three is closer to the worst case for code, JSON and
/// non-Latin scripts. Refusing a borderline-valid prompt with a clear 413 is a
/// far better outcome than a process that dies, so the guard errs toward
/// refusing.
public struct ContextGuard: Sendable, Equatable {
    /// Characters per token, worst case. Lower means more pessimistic.
    public static let charactersPerToken = 3

    public var contextTokens: Int
    /// Tokens held back for the answer, so a prompt cannot fill the window and
    /// leave no room to reply.
    public var reservedForCompletion: Int

    public init(contextTokens: Int, reservedForCompletion: Int? = nil) {
        self.contextTokens = contextTokens
        // Proportional, not flat: a fixed 64-token reserve swallows a small
        // context whole and refuses prompts that would fit comfortably.
        self.reservedForCompletion = reservedForCompletion ?? min(64, max(1, contextTokens / 4))
    }

    public static func estimateTokens(_ text: String) -> Int {
        (text.count + charactersPerToken - 1) / charactersPerToken
    }

    public static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        // Four tokens per message covers the role markers and separators every
        // chat template inserts.
        messages.reduce(0) { $0 + estimateTokens($1.content) + 4 }
    }

    public var promptBudget: Int {
        max(1, contextTokens - reservedForCompletion)
    }

    public func fits(_ messages: [ChatMessage]) -> Bool {
        Self.estimateTokens(messages) <= promptBudget
    }

    /// Throws rather than returning a Bool so callers cannot forget to act.
    public func check(_ messages: [ChatMessage]) throws {
        let estimated = Self.estimateTokens(messages)
        guard estimated <= promptBudget else {
            throw InferenceError.contextExhausted
        }
    }
}
