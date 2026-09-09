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
    /// Tokens this prompt will grow by AFTER the guard has seen it.
    ///
    /// Tool schemas are injected downstream, inside the inference library's own
    /// message processing, so the guard never sees them. Registering three
    /// tools adds roughly 860 tokens invisibly — which would quietly reopen the
    /// exact crash this type exists to prevent, since llama.cpp does not error
    /// on an oversized prompt, it asserts and takes the process down.
    public var fixedOverheadTokens: Int

    public init(contextTokens: Int, reservedForCompletion: Int? = nil, fixedOverheadTokens: Int = 0) {
        self.contextTokens = contextTokens
        // Proportional, not flat: a fixed 64-token reserve swallows a small
        // context whole and refuses prompts that would fit comfortably.
        self.reservedForCompletion = reservedForCompletion ?? min(64, max(1, contextTokens / 4))
        self.fixedOverheadTokens = fixedOverheadTokens
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
        max(1, contextTokens - reservedForCompletion - fixedOverheadTokens)
    }

    /// The fixed preamble the library prepends when any tool is registered.
    /// Asserted in the tests so a dependency bump that changes it fails loudly
    /// rather than silently eating budget.
    public static let toolPreambleCharacters = 264

    /// What registering `toolsJSON` will cost, in guard tokens.
    ///
    /// Doubled for a tool-native chat template: the schema is rendered once by
    /// the template itself and appended again by the library's instruction
    /// processor, so a Qwen3-style model pays for it twice.
    public static func toolOverhead(toolsJSON: String, templateIsToolNative: Bool) -> Int {
        guard !toolsJSON.isEmpty else { return 0 }
        let schema = estimateTokens(toolsJSON) * (templateIsToolNative ? 2 : 1)
        return schema + (toolPreambleCharacters + charactersPerToken - 1) / charactersPerToken
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
