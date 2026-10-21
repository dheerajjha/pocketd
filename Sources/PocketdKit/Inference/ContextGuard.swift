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
/// The estimate is deliberately pessimistic, and it is measured in UTF-8 bytes.
/// Four bytes per token is the usual English average; three is closer to the
/// worst case for code, JSON and non-Latin scripts.
///
/// Bytes rather than `String.count`, which counts extended grapheme clusters
/// and would make the same three-per-token promise about a unit nothing bounds.
/// A Japanese character is three bytes and usually a token of its own, so
/// clusters divided by three price it at a third of what it costs; a ZWJ family
/// emoji is one cluster and twenty-five bytes, so it is priced at a twenty-fifth
/// of them. Both are under-reservations, and an under-reservation is the crash
/// above rather than a refusal. ASCII has one byte per character, so every
/// prose, code and JSON prompt is priced at exactly the number it was.
///
/// Refusing a borderline-valid prompt with a clear 413 is a far better outcome
/// than a process that dies, so the guard errs toward refusing.
public struct ContextGuard: Sendable, Equatable {
    /// UTF-8 bytes per token, worst case. Lower means more pessimistic.
    public static let bytesPerToken = 3

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
        (text.utf8.count + bytesPerToken - 1) / bytesPerToken
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
    ///
    /// Measured from the literal in LocalLLMClient's
    /// `StandardToolInstructionProcessor.generateToolInstructions`, with an
    /// empty tools array. The test spells that literal out again so a careless
    /// edit to this number fails — though only re-reading the dependency can
    /// catch the dependency itself changing, which no test can do for us.
    ///
    /// Characters and bytes alike: the literal is ASCII.
    public static let toolPreambleCharacters = 265

    /// What registering `toolsJSON` will cost, in guard tokens.
    ///
    /// Doubled for a tool-native chat template: the schema is rendered once by
    /// the template itself and appended again by the library's instruction
    /// processor, so a Qwen3-style model pays for it twice.
    /// Whether a chat template renders tool schemas itself.
    ///
    /// This is the library's own test, character for character:
    /// `StandardToolInstructionProcessor.hasNativeToolSupport(in:)` is
    /// `template.contains("tools")` and nothing more. It is a crude test — a
    /// template that merely says the word would pass — but a *different* crude
    /// test would be worse, because the number it feeds has to predict what
    /// that code actually does, not what it should do.
    public static func templateIsToolNative(_ template: String) -> Bool {
        template.contains("tools")
    }

    public static func toolOverhead(toolsJSON: String, templateIsToolNative: Bool) -> Int {
        guard !toolsJSON.isEmpty else { return 0 }
        return toolOverhead(schemaCharacters: toolsJSON.utf8.count, templateIsToolNative: templateIsToolNative)
    }

    /// The same price, quoted before there is a string to measure.
    ///
    /// `CapabilityBudget` has to decide which schemas will be serialised, which
    /// means pricing a set that does not exist yet. Splitting the arithmetic out
    /// rather than restating it there is not tidiness: if the budget's estimate
    /// and the guard's reservation could drift apart, the budget would admit a
    /// tool the guard then charges more for, under-reserve by the difference,
    /// and hand llama.cpp the oversized batch this whole file exists to prevent.
    ///
    /// The label still says characters because `CapabilityBudget` measures its
    /// schemas with `String.count` and the two have to remain one number. Every
    /// schema this app generates is ASCII — an identifier, an English sentence
    /// and snake_case enum values — so they are the same count today, and if one
    /// ever stops being, the budget quotes less than the guard reserves, which
    /// costs a prompt rather than the process.
    public static func toolOverhead(schemaCharacters: Int, templateIsToolNative: Bool) -> Int {
        guard schemaCharacters > 0 else { return 0 }
        let schema = ((schemaCharacters + bytesPerToken - 1) / bytesPerToken)
            * (templateIsToolNative ? 2 : 1)
        return schema + (toolPreambleCharacters + bytesPerToken - 1) / bytesPerToken
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

    // MARK: - Fitting a long conversation

    /// The newest part of `messages` that fits, for a caller who would rather
    /// lose the oldest turns than the whole conversation.
    ///
    /// This is what "long conversations never die" means in practice. The
    /// phone sends its whole history on every turn, and once that outgrew the
    /// window `check` refused it — and refused every later message too, because
    /// the history only ever grows. A person sees a conversation that worked
    /// for twenty questions and then never again.
    ///
    /// The rules, in order of what is protected:
    ///
    /// 1. **The system turns at the top stay.** They carry the date, the
    ///    instructions and the person's own Assistant instructions; dropping
    ///    them changes who is answering.
    /// 2. **The latest turn stays** — the question being asked, with anything
    ///    that came after it.
    /// 3. **Whole turns go, oldest first.** A turn is a user message and
    ///    everything up to the next one: the answer, and any tool call and its
    ///    result. Cutting inside one would hand the model a tool result with no
    ///    call, or an answer with no question, which a small model reads as an
    ///    example of how to behave.
    ///
    /// Throws `contextExhausted` only when the system turns and the latest turn
    /// do not fit on their own — a single message too long to read, which no
    /// amount of forgetting can fix.
    ///
    /// Network requests do not come through here: a client that sends a
    /// conversation too long for the window gets a 413 and decides for itself
    /// what to drop, which is what every other server does.
    public func trimmed(_ messages: [ChatMessage]) throws -> [ChatMessage] {
        if fits(messages) { return messages }

        let head = Array(messages.prefix { $0.role == .system })
        var turns = Self.turns(in: Array(messages.dropFirst(head.count)))
        guard let latest = turns.popLast() else {
            // Nothing but system turns, and they do not fit.
            throw InferenceError.contextExhausted
        }

        let fixed = Self.estimateTokens(head) + Self.estimateTokens(latest)
        guard fixed <= promptBudget else { throw InferenceError.contextExhausted }

        // Newest first, keeping each turn while there is room, and stopping at
        // the first that does not fit: skipping one to keep an older one would
        // leave a gap in the middle of the conversation.
        var room = promptBudget - fixed
        var kept: [[ChatMessage]] = []
        for turn in turns.reversed() {
            let cost = Self.estimateTokens(turn)
            guard cost <= room else { break }
            room -= cost
            kept.append(turn)
        }
        return head + kept.reversed().flatMap { $0 } + latest
    }

    /// Groups a conversation into turns: each starts at a user message and
    /// runs up to the next one. Anything before the first user message — a
    /// greeting the assistant opened with — is a turn of its own.
    static func turns(in messages: [ChatMessage]) -> [[ChatMessage]] {
        var turns: [[ChatMessage]] = []
        for message in messages {
            if message.role == .user || turns.isEmpty {
                turns.append([message])
            } else {
                turns[turns.count - 1].append(message)
            }
        }
        return turns
    }

    /// Room to hold back for the reply when a conversation is being fitted.
    ///
    /// The plain guard reserves at most 64 tokens, which is right for refusing
    /// a prompt and wrong for fitting one: a history trimmed to leave 64 tokens
    /// answers in a sentence and stops mid-word. This keeps what the caller
    /// asked for, up to a quarter of the window, and never less than the guard
    /// itself would.
    public static func replyReserve(contextTokens: Int, requestedMaxTokens: Int?) -> Int {
        let floor = min(64, max(1, contextTokens / 4))
        let wanted = requestedMaxTokens ?? 512
        return max(floor, min(wanted, contextTokens / 4))
    }
}
