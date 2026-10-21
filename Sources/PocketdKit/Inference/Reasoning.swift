import Foundation

/// Whether a request should let the model think first, decided in one place.
///
/// The phone's own generations never think. The brief is capped at 160 tokens
/// and Qwen3 spends several hundred on working before the first word, so a
/// thinking brief ran out of room inside `<think>` and silently stayed on the
/// template; a chat answer spent tens of seconds behind a "Working…" pill on
/// "what's on today?", where there is nothing to reason about; and a routine
/// stored its working with the tags swapped for "[removed]". Other devices get
/// whatever the server's setting says, because a laptop asking for reasoning
/// may genuinely want it.
public enum ThinkingPolicy {
    /// - Parameter serverAllowsThinking: the "Let the model think first"
    ///   switch, which governs other devices only.
    public static func allowsThinking(for origin: RequestOrigin, serverAllowsThinking: Bool) -> Bool {
        origin.isThisPhone ? false : serverAllowsThinking
    }

    /// Whether the reasoning a model emits anyway is taken out of the stream.
    /// Only for the phone's own screens: a network client asked for the raw
    /// output and may well render the working itself.
    public static func stripsReasoning(for origin: RequestOrigin) -> Bool {
        origin.isThisPhone
    }
}

/// How each family of chat template is told not to think.
///
/// There is no general switch. The template flag (`enable_thinking`) would be
/// the clean one, but LocalLLMClient renders templates with a context nobody
/// outside it can add to, so what is left is what the models themselves read:
///
/// - **Qwen3** (and the templates built on it) honour a documented soft switch,
///   `/no_think`, at the end of the latest user turn, and answer with an empty
///   `<think></think>` block. Recognised by a template that knows both
///   `enable_thinking` and `<think>`.
/// - **Gemma 4** thinks only when `<|think|>` opens the system turn, and its
///   template defaults `enable_thinking` to false — so it is already off and
///   nothing is added.
/// - Templates that always reason (DeepSeek R1 distills, Qwen3's "Thinking"
///   releases) have no switch at all. Their working is removed from the output
///   instead, by `ReasoningFilter`, which is also the defence for every family
///   above that ignores its switch.
public enum ThinkingSwitch {
    /// Qwen's documented soft switch.
    public static let softSwitchOff = "/no_think"

    /// Whether this template reads the `/no_think` soft switch.
    public static func understandsSoftSwitch(chatTemplate: String?) -> Bool {
        guard let chatTemplate else { return false }
        return chatTemplate.contains("enable_thinking") && chatTemplate.contains("<think>")
    }

    /// `messages` with thinking turned off where the template has a way to say
    /// so, and unchanged otherwise.
    ///
    /// The latest user turn only, because Qwen documents the switch as per-turn
    /// and the model follows the most recent instruction; repeating it on every
    /// historical turn spends tokens restating something already obeyed.
    /// Idempotent, so a caller that still appends the switch itself does not
    /// end up sending it twice.
    public static func turningThinkingOff(_ messages: [ChatMessage], chatTemplate: String?) -> [ChatMessage] {
        guard understandsSoftSwitch(chatTemplate: chatTemplate),
              let last = messages.lastIndex(where: { $0.role == .user }),
              !messages[last].content.contains(softSwitchOff)
        else { return messages }
        var updated = messages
        updated[last].content += "\n" + softSwitchOff
        return updated
    }

    /// Whether the template's generation prompt opens a reasoning block and
    /// leaves it open, so the model's first tokens are working and the first
    /// tag it emits is the *closing* one.
    ///
    /// Read from the text after the template's last `add_generation_prompt`:
    /// an opening `<think>` there with no closing one after it. Qwen3's hybrid
    /// template does write `<think>` in that branch — and closes it at once,
    /// which is how it turns thinking off — so it answers no.
    public static func generationPromptOpensReasoning(chatTemplate: String?) -> Bool {
        guard let chatTemplate,
              let branch = chatTemplate.range(of: "add_generation_prompt", options: .backwards)
        else { return false }
        let tail = chatTemplate[branch.upperBound...]
        guard let open = tail.range(of: "<think>", options: .backwards) else { return false }
        return tail[open.upperBound...].range(of: "</think>") == nil
    }
}

/// Removes reasoning blocks from a stream of text, chunk by chunk.
///
/// What a person reads is the answer. The working — `<think>…</think>` from
/// Qwen3 and most reasoning models, `<|channel>thought…<channel|>` from Gemma 4
/// — is held back and dropped, and so is a block that never closes, because a
/// generation that ran out of tokens mid-thought has no answer in it at all.
///
/// Streaming is the hard part and the reason this is a type: a tag can arrive
/// split across two chunks ("<th", "ink>"), so a trailing fragment that could
/// still become a tag is held until the next chunk says what it was. Only
/// fragments of a tag are ever held, so ordinary prose streams exactly as fast
/// as before; a reply ending in a bare `<` waits for `finish()`.
public struct ReasoningFilter: Sendable, Equatable {

    /// Opening tag and its closing partner.
    public static let blocks: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<|channel>", "<channel|>"),
    ]

    private var pending = ""
    private var closing: String?
    /// Set after a block is dropped, so the blank lines that followed it do
    /// not open the answer.
    private var trimsLeadingWhitespace = false
    private var emittedAnything = false

    /// - Parameter startsInsideReasoning: the template opened the block itself
    ///   (`ThinkingSwitch.generationPromptOpensReasoning`), so the output
    ///   begins as working and ends it with a bare closing tag.
    public init(startsInsideReasoning: Bool = false) {
        closing = startsInsideReasoning ? Self.blocks[0].close : nil
    }

    /// Takes the next chunk and returns whatever of it can be shown now.
    public mutating func feed(_ chunk: String) -> String {
        pending += chunk
        var shown = ""
        while true {
            if let close = closing {
                guard let end = pending.range(of: close) else {
                    // All working so far. Keep only what could be the start of
                    // the closing tag.
                    pending = String(pending.suffix(close.count - 1))
                    return shown
                }
                pending = String(pending[end.upperBound...])
                closing = nil
                trimsLeadingWhitespace = true
                continue
            }
            if let (range, close) = earliestOpening(in: pending) {
                shown += visible(pending[..<range.lowerBound])
                pending = String(pending[range.upperBound...])
                closing = close
                continue
            }
            // A closing tag with no opening one: a template that prefilled the
            // block without saying so. What came before it was working, but it
            // may already be on screen, so only the tag itself goes.
            for block in Self.blocks {
                pending = pending.replacingOccurrences(of: block.close, with: "")
            }
            let held = heldBackCount(in: pending)
            shown += visible(pending.dropLast(held))
            pending = String(pending.suffix(held))
            return shown
        }
    }

    /// Everything left, at the end of the stream. A block still open is
    /// dropped; a fragment that never became a tag was prose after all.
    public mutating func finish() -> String {
        defer { pending = "" }
        guard closing == nil else { return "" }
        return visible(Substring(pending))
    }

    /// The whole of `text` with its reasoning removed, for a caller holding a
    /// finished string.
    public static func strip(_ text: String, startsInsideReasoning: Bool = false) -> String {
        var filter = ReasoningFilter(startsInsideReasoning: startsInsideReasoning)
        return filter.feed(text) + filter.finish()
    }

    /// Text that is not working, with the whitespace a dropped block left
    /// behind taken off its front.
    private mutating func visible(_ text: Substring) -> String {
        var text = text
        if trimsLeadingWhitespace || !emittedAnything {
            // At the very start too: a reasoning model's answer opens with the
            // blank lines its block left behind, even when the block itself
            // arrived in an earlier chunk.
            text = text.drop { $0.isWhitespace }
            if text.isEmpty { return "" }
            trimsLeadingWhitespace = false
        }
        emittedAnything = true
        return String(text)
    }

    private func earliestOpening(in text: String) -> (Range<String.Index>, String)? {
        Self.blocks
            .compactMap { block in text.range(of: block.open).map { ($0, block.close) } }
            .min { $0.0.lowerBound < $1.0.lowerBound }
    }

    /// The length of the longest tail of `text` that is the start of a tag, so
    /// it is not shown before the next chunk decides what it is.
    private func heldBackCount(in text: String) -> Int {
        let tags = Self.blocks.flatMap { [$0.open, $0.close] }
        let longest = tags.map(\.count).max() ?? 0
        for length in stride(from: min(longest - 1, text.count), to: 0, by: -1) {
            let tail = text.suffix(length)
            if tags.contains(where: { $0.hasPrefix(tail) }) { return length }
        }
        return 0
    }
}
