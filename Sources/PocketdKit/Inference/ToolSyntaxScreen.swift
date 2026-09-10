import Foundation

/// The last thing between a failed tool call and the user's chat bubble.
///
/// `ToolGate` decides which models are handed tools; this decides what to do
/// when one of them gets the protocol wrong anyway. llama.cpp's own parser
/// claims the tool syntax it recognises and turns it into a call. Everything it
/// does not claim — a marker from a family it was not built for, a call the
/// model wrapped in nothing at all — falls through as ordinary text and is
/// streamed to the transcript as though the model had said it. What the user
/// reads is `<|python_tag|>{"function": {"description": …`, which is not an
/// answer, not an error, and not something they can act on.
///
/// Two rules, in order of how much they can be trusted:
///
/// 1. **Markers.** The literal control tokens the templates in this app's
///    catalogue actually emit, read out of their GGUF headers rather than
///    remembered — but only where a call could stand: opening the turn, or
///    carrying the JSON payload a call carries. A model explaining what
///    `<tool_call>` means is answering, not calling.
/// 2. **A bare blob.** Llama 3.2's template renders a tool call as
///    `{"name": "…", "parameters": …}` with no marker around it at all, so the
///    first rule cannot see it. A turn whose *answer* begins with a brace and
///    carries the shape of a call is therefore also treated as one — where the
///    answer begins after the `<think>…</think>` block a reasoning model puts
///    in front of every reply, because Qwen3 was watched emitting exactly that
///    blob one line below its own closing tag.
///
/// The second rule is the one that can be wrong, so it is fenced in three
/// ways: it is armed only when tools are actually registered, it applies only
/// when the reply opens with the brace, and it looks for a registered tool's
/// name or an unmistakable call shape. A reply that merely mentions JSON, or
/// quotes some in a fenced block, never begins with a brace and is never
/// touched. A reply that genuinely is a JSON object — because the user asked
/// for one — passes unless it also carries the name of a tool this app
/// registered, which the user's own data will not.
///
/// The same constraint governs this as governs the stop-sequence hold-back
/// beside it: a token that has been yielded cannot be taken back. So detection
/// runs against the accumulated text and reports how much of it is safe to
/// send *now*, holding back the tail that could still turn out to be a marker.
public struct ToolSyntaxScreen: Sendable, Equatable {

    /// What the user sees instead of the leak.
    ///
    /// A sentence rather than silence, and this is the one real choice in the
    /// file. Suppressing quietly leaves an empty bubble, which is
    /// indistinguishable from a crash, a hang or a model that had nothing to
    /// say — so the user retries the same question and gets the same nothing.
    /// The line says what happened and what to do about it, and it is careful
    /// not to claim the tool ran: nothing was read, and telling someone their
    /// calendar was consulted when it was not is the one failure here that
    /// would be worse than the schema dump.
    public static let notice = "The model tried to use a tool and produced something unusable, so there is no answer here. Nothing was read. A larger model handles this more reliably."

    /// Control tokens that mean a tool call is starting.
    ///
    /// Every one of these was taken from a `tokenizer.chat_template` in a GGUF
    /// header, not from documentation — including the asymmetry in Gemma 4's
    /// pair, which opens `<|tool_call>` and closes `<tool_call|>` and would be
    /// missed by anything that assumed the obvious spelling. DeepSeek appears
    /// twice because its tokenizer uses U+2581 where its documentation uses an
    /// underscore, and a model emits the byte sequence it was trained on.
    ///
    /// Openers only. A closing tag with no opener is not evidence of anything,
    /// and half of these are substrings of their own closers.
    public static let markers: [String] = [
        "<|python_tag|>",       // Llama 3.1 / 3.2
        "<tool_call>",          // Qwen3, Hermes, and most of ChatML's descendants
        "<|tool_call>",         // Gemma 4
        "[TOOL_CALLS]",         // Mistral
        "<|tool_call_begin|>",  // DeepSeek, as written
        "<|tool▁call▁begin|>",  // DeepSeek, as tokenised
        "<|tool_calls_begin|>",
        "<|tool▁calls▁begin|>",
        "<function="            // Meta's zero-shot function syntax for Llama 3.2
    ]

    /// Markers that are syntax wherever they appear.
    ///
    /// The rest have to be in a position a call could occupy — see
    /// `firstMarker` — because a model can also be *talking* about them, and
    /// truncating an answer to "what does `<tool_call>` mean in Qwen?" at the
    /// word it is explaining would be its own kind of broken. `<function=` is
    /// half a tag rather than a word: nobody writes it in a sentence, and what
    /// follows it is a name rather than the brace the others carry.
    private static let unconditional: Set<String> = ["<function="]

    /// How far past a marker to look for the payload that would make it a call.
    /// A template puts one there immediately; this only has to survive the
    /// whitespace a model might indent with.
    private static let payloadLookahead = 24

    /// How much of a brace-opening turn to read before deciding what it is.
    ///
    /// The cost of this rule is that such a turn does not stream until the
    /// screen has seen this many characters — the only latency this type adds,
    /// paid only by replies that open with a brace while tools are on. A tool
    /// call names itself early or it is not a tool call, so reading further
    /// would buy nothing and delay more.
    public static let blobProbeCharacters = 240

    /// The reasoning block Qwen3 and its relatives put in front of every reply.
    /// Skipped before the blob rule is applied, and nowhere else.
    static let reasoningOpen = "<think>"
    static let reasoningClose = "</think>"

    /// The names of the tools actually registered for this generation. Empty
    /// disarms the screen entirely.
    ///
    /// Disarmed is not laziness: with no tools registered the library injects
    /// no schema, so there is nothing for the model to leak, and the same
    /// characters are far more likely to be the subject of the conversation —
    /// someone asking what `<|python_tag|>` is for deserves to be shown it.
    public let toolNames: [String]

    public init(toolNames: [String] = []) {
        self.toolNames = toolNames
    }

    public var isArmed: Bool { !toolNames.isEmpty }

    private static let longestMarker = markers.map(\.count).max() ?? 0

    // MARK: - Mid-stream

    /// How many characters of `text` may be shown right now.
    ///
    /// - Parameter clearedThrough: how many leading characters a previous call
    ///   already passed, so a growing stream is not rescanned from the top on
    ///   every token. Passing 0 is always correct and always slower; passing
    ///   more than was actually cleared is not.
    public func safeCount(in text: String, clearedThrough: Int = 0) -> Int {
        guard isArmed else { return text.count }

        // A marker cuts the turn where it starts. With none found, everything
        // is safe except a tail that has not yet had the chance to become one:
        // a marker of length m starting at index i is whole in `text` once
        // `text.count >= i + m`, so holding back `longestMarker - 1` means
        // nothing past i is ever released before the scan above can see it.
        var safe = firstMarker(in: text, from: clearedThrough)
            ?? max(0, text.count - (Self.longestMarker - 1))

        if let blob = blobStart(in: text) {
            let offset = text.distance(from: text.startIndex, to: blob)
            // Undecidable until there is enough to decide on, and a decision
            // taken early cannot be revisited once the text is out. Withholding
            // is the half that can still be undone, so that is the half done
            // while the answer is in doubt.
            if text.count - offset < Self.blobProbeCharacters || blobIsToolCall(text, from: blob) {
                safe = min(safe, offset)
            }
        }
        return safe
    }

    // MARK: - End of turn

    public enum Resolution: Sendable, Equatable {
        /// Show all of it.
        case clean
        /// Show the first `keeping` characters and then `notice`. Zero when the
        /// leak was the entire turn.
        ///
        /// The prose before a leak is kept rather than thrown away because it
        /// is usually the model saying what it is about to do, and deleting it
        /// would make a failed turn look like a turn that never happened. It is
        /// never left on its own, because on its own it is a promise of an
        /// answer that is not coming.
        case leaked(keeping: Int)
    }

    /// The verdict on a finished turn, once nothing more is coming.
    public func resolve(_ text: String) -> Resolution {
        guard isArmed else { return .clean }

        var leak = firstMarker(in: text, from: 0)
        if let blob = blobStart(in: text), blobIsToolCall(text, from: blob) {
            let offset = text.distance(from: text.startIndex, to: blob)
            // The earlier of the two, so a turn that leaks twice is cut at the
            // first place it stopped being an answer.
            leak = leak.map { min($0, offset) } ?? offset
        }
        return leak.map { Resolution.leaked(keeping: $0) } ?? .clean
    }

    // MARK: - The two rules

    private func firstMarker(in text: String, from clearedThrough: Int) -> Int? {
        // Back up far enough that a marker straddling the previously cleared
        // boundary is still seen whole.
        let floor = max(0, min(clearedThrough, text.count) - (Self.longestMarker - 1))
        let start = text.index(text.startIndex, offsetBy: floor, limitedBy: text.endIndex) ?? text.endIndex
        var earliest: Int?
        for marker in Self.markers {
            guard let found = text.range(of: marker, range: start..<text.endIndex) else { continue }
            guard isCall(marker, in: text, at: found) else { continue }
            let offset = text.distance(from: text.startIndex, to: found.lowerBound)
            earliest = earliest.map { min($0, offset) } ?? offset
        }
        return earliest
    }

    /// Whether an occurrence of a marker is the model calling a tool rather
    /// than the model writing about one.
    ///
    /// A marker that opens the turn is a call: nothing else starts a reply. One
    /// that appears later has to carry the payload a call carries, which is
    /// always a JSON object or array. Anything else is a mention, and a mention
    /// is somebody's answer.
    ///
    /// Undecidable reads as a call, which mid-stream simply means the text
    /// stays withheld until the next character settles it — the one direction
    /// that can still be taken back. At the end of a turn there is no next
    /// character, and a turn that ends on a bare marker is broken output
    /// whichever way it is read.
    private func isCall(_ marker: String, in text: String, at range: Range<String.Index>) -> Bool {
        if Self.unconditional.contains(marker) { return true }
        if text[text.startIndex..<range.lowerBound].allSatisfy(\.isWhitespace) { return true }
        guard let next = text[range.upperBound...]
            .prefix(Self.payloadLookahead)
            .drop(while: \.isWhitespace)
            .first
        else { return true }
        return next == "{" || next == "["
    }

    /// Where the JSON of a brace-first turn starts, if the turn has one.
    ///
    /// Not simply the first character. A reasoning model opens every reply with
    /// a `<think>…</think>` block, and that block is not the answer: Qwen3 1.7B
    /// was watched putting a bare `{"name": …, "arguments": …}` on the line
    /// after its own closing tag, which anything looking only at the first
    /// character would wave through. Nothing else is skipped — a brace in the
    /// middle of a sentence is a sentence.
    private func blobStart(in text: String) -> String.Index? {
        var start = text.startIndex
        if text.drop(while: \.isWhitespace).hasPrefix(Self.reasoningOpen),
           let close = text.range(of: Self.reasoningClose) {
            start = close.upperBound
        }
        guard let first = text[start...].firstIndex(where: { !$0.isWhitespace }) else { return nil }
        return text[first] == "{" || text[first] == "[" ? first : nil
    }

    /// Whether the opening of a brace-first turn carries the shape of a call.
    private func blobIsToolCall(_ text: String, from start: String.Index) -> Bool {
        let probe = String(text[start...].prefix(Self.blobProbeCharacters))
        // The strongest signal there is: a tool this app registered a moment
        // ago, named inside a JSON object the model produced. No reply that is
        // legitimately about the user's own data contains one.
        if toolNames.contains(where: { probe.contains($0) }) { return true }
        // Failing that, the two shapes a leak takes. `name`+`parameters` is
        // what Llama 3.2's template renders a call as, `name`+`arguments` is
        // OpenAI's spelling of the same thing, and `parameters`+`properties` is
        // not a call at all but the schema copied back out of the prompt —
        // which is the failure that started this.
        let keys = [
            ["\"name\"", "\"parameters\""],
            ["\"name\"", "\"arguments\""],
            ["\"parameters\"", "\"properties\""]
        ]
        return keys.contains { required in required.allSatisfy(probe.contains) }
    }
}
