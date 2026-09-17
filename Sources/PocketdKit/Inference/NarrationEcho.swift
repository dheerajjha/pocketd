import Foundation

/// The other half of a tool round's output problem.
///
/// `ToolSyntaxScreen` catches the model getting the protocol wrong on the way
/// *in*, before any tool runs. This catches the way the same small models fail
/// on the way *out*: handed a tool result and asked to speak about it, they
/// sometimes copy it back out instead. The bubble reads
/// `{"text":"No events tomorrow."}` — the exact bytes this app put in front of
/// them a moment earlier, and the exact bytes already rendered as an
/// `AnswerCard` immediately above. It is not an answer, it is not wrong either;
/// it is the question read back, and it is the first thing a lot of new users
/// see.
///
/// The check is deliberately narrow, because the cost of a false positive here
/// is deleting somebody's real answer. It is not "does this look like JSON",
/// not "is this too structured to be prose" — it is a comparison against the
/// exact strings this app handed the model on this turn, which nothing else in
/// the world would produce verbatim. A reply that *talks about* the payload
/// ("you have no events tomorrow") shares not one substring with it at this
/// length and is never touched.
///
/// Three things make the comparison survive contact with a real model:
///
/// 1. **Normalisation.** A reasoning model wraps the turn in `<think>…</think>`
///    and often drops the copy inside a ```json fence; whitespace is reflowed
///    on the way through a chat template. The reasoning block, the fence, its
///    language tag and every run of whitespace are flattened before anything is
///    compared, on both sides.
/// 2. **A length floor.** `{"n":1}` is short enough to occur inside a sentence
///    somebody meant, so payloads below `minimumPayloadCharacters` are dropped
///    and a round that produced only those is disarmed. A false positive costs
///    an answer; a false negative costs one ugly bubble.
/// 3. **No payloads, no screen.** An empty list — no tools ran — disarms it
///    entirely, so a generation without tools behaves exactly as it did before
///    this type existed.
///
/// It is used the way `ToolSyntaxScreen` is used, and for the same reason: a
/// character that has been yielded cannot be taken back, so mid-stream it only
/// ever withholds, and the single irreversible decision is taken at the end of
/// the turn when nothing more is coming.
public struct NarrationEcho: Sendable, Equatable {

    /// Below this, a payload is too likely to collide with prose somebody
    /// meant. Counted after normalisation, because that is the form the
    /// comparison happens in.
    public static let minimumPayloadCharacters = 12

    /// What stands in for narration that was nothing but the echo.
    ///
    /// Only ever used when the round yielded no card — with a card on screen
    /// the right amount of narration is none, and the card says more than a
    /// sentence about it could. Without one, an empty bubble is
    /// indistinguishable from a crash, so the turn says the shortest true thing
    /// there is: the tool ran, and there is nothing further to report.
    public static let acknowledgement = "Done."

    /// The normalised payloads this round handed the model, `Rendered.prompt`
    /// for each call. Empty disarms.
    public let payloads: [String]

    public init(payloads: [String]) {
        self.payloads = payloads
            .map(Self.normalise)
            .filter { $0.count >= Self.minimumPayloadCharacters }
    }

    public var isArmed: Bool { !payloads.isEmpty }

    // MARK: - Mid-stream

    /// How many characters of the resume pass may be shown right now.
    ///
    /// An echo is recognisable from its first character and unmistakable by its
    /// tenth, but it is only *finished* at the end, so while what has arrived
    /// so far is still a prefix of something we handed over, the turn could
    /// still be either thing and nothing is released. The moment it diverges it
    /// is prose — the model is writing its own sentence — and everything is
    /// released at once.
    ///
    /// The withholding is therefore almost free: the first character of a real
    /// answer already diverges from a payload that opens with a brace, so an
    /// ordinary narration streams from its first token. A turn that opens with
    /// a `<think>` block stays withheld until the block closes, because until
    /// then the answer has not started and there is nothing to diverge.
    ///
    /// No `clearedThrough` hint, unlike the screen beside it: this compares
    /// normalised strings rather than scanning for markers, so there is no
    /// partial state to carry, and the resume pass is short.
    public func safeCount(in text: String) -> Int {
        guard isArmed else { return text.count }
        let sofar = Self.normalise(text)
        // `hasPrefix` is reflexive, so a completed echo with nothing after it
        // stays withheld — which is the whole case this exists for.
        if payloads.contains(where: { $0.hasPrefix(sofar) }) { return 0 }
        return text.count
    }

    // MARK: - End of turn

    /// The narration this turn should keep, or `nil` if it never echoed.
    ///
    /// `nil` means "clean" rather than "empty" so a caller can tell a turn this
    /// type has no opinion about — which must be left byte for byte alone,
    /// including its reasoning block and its line breaks — from one it rewrote.
    /// The rewrite returns the normalised remainder, which may be the empty
    /// string when the echo was the entire turn.
    public func resolve(_ text: String) -> String? {
        guard isArmed else { return nil }
        var working = Self.normalise(text)
        guard payloads.contains(where: { working.contains($0) }) else { return nil }

        for payload in payloads {
            working = working.replacingOccurrences(of: payload, with: Self.sentinel)
        }
        // A language tag whose fence has been removed and whose payload has
        // just gone with it is debris, not a word the model wrote.
        working = working.replacingOccurrences(
            of: "\(Self.languageTag) \(Self.sentinel)",
            with: Self.sentinel,
            options: .caseInsensitive
        )
        working = working.replacingOccurrences(of: Self.fence, with: " ")
        working = working.replacingOccurrences(of: Self.sentinel, with: " ")
        return Self.collapse(working)
    }

    // MARK: - Normalisation

    static let reasoningOpen = "<think>"
    static let reasoningClose = "</think>"
    static let fence = "```"
    static let languageTag = "json"
    /// Stands in for a removed payload while the debris around it is swept up.
    /// U+FFFC is not something a chat model emits, and it is replaced by a
    /// space before anything is returned either way.
    private static let sentinel = "\u{FFFC}"

    /// The form both sides are compared in: no reasoning, no fences, one space
    /// between words, no ends.
    static func normalise(_ text: String) -> String {
        collapse(stripFences(stripReasoning(text)))
    }

    /// Removes every `<think>…</think>` block.
    ///
    /// Plural, because a turn that used a tool ran the model twice and carries
    /// one block per pass. An *unterminated* block takes everything after it:
    /// mid-stream that is the honest reading — the model is still working and
    /// has not begun its answer — and it is also the safe one, since an empty
    /// normalisation withholds rather than releases.
    private static func stripReasoning(_ text: String) -> String {
        var kept = ""
        var rest = Substring(text)
        while let open = rest.range(of: reasoningOpen) {
            kept += rest[..<open.lowerBound]
            guard let close = rest.range(of: reasoningClose, range: open.upperBound..<rest.endIndex) else {
                return kept
            }
            rest = rest[close.upperBound...]
        }
        return kept + rest
    }

    /// Removes ``` fences, and the language tag that belongs to an opening one.
    ///
    /// The tag is dropped only where a fence just was, so a sentence containing
    /// the word "json" keeps it.
    private static func stripFences(_ text: String) -> String {
        var kept = ""
        var rest = Substring(text)
        while let marker = rest.range(of: fence) {
            kept += rest[..<marker.lowerBound]
            var after = rest[marker.upperBound...]
            let tagged = after.drop { $0 == " " || $0 == "\t" }
            if tagged.lowercased().hasPrefix(languageTag) {
                let remainder = tagged.dropFirst(languageTag.count)
                // Only when the tag is the whole word — `jsonl` is a different
                // language and `jsonish` is somebody talking.
                if remainder.first.map({ !$0.isLetter && !$0.isNumber }) ?? true {
                    after = remainder
                }
            }
            rest = after
        }
        return kept + rest
    }

    /// Every run of whitespace becomes one space, and the ends lose theirs.
    private static func collapse(_ text: String) -> String {
        var collapsed = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !collapsed.isEmpty
                continue
            }
            if pendingSpace {
                collapsed.append(" ")
                pendingSpace = false
            }
            collapsed.append(character)
        }
        return collapsed
    }
}
