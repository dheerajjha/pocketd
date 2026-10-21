import Foundation

/// Finds the instructions a small model copied into its answer, and takes them
/// out.
///
/// The walkthrough caught this twice on the first afternoon. SmolLM2 360M,
/// asked for the morning brief, wrote the brief's own system prompt back as the
/// brief — "Warm and plain, and easy to read aloud. No lists, no markdown, no
/// headings, no emoji. Open by greeting them for the afternoon, by name: Sam.
/// Never mention yourself, a model, or how this was written." — and the app
/// cached it and read it out on every launch. Asked what was on next, the same
/// model ended its answer with "The user's locale is en_IN and the week starts
/// on Sunday. You are a helpful assistant." A brain that small cannot always
/// tell the instructions from the material, and nothing downstream could tell
/// either.
///
/// So this compares the answer against what the model was told, sentence by
/// sentence, and drops a sentence when:
///
/// - it *is* an instruction sentence (same words, any punctuation or case);
/// - it is mostly made of one — 80% of its words come from a single
///   instruction sentence and it covers at least half of that sentence, which
///   is what a near-verbatim copy with a word changed looks like;
/// - it carries an identifier only the machinery could have supplied — a time
///   zone id like `Asia/Kolkata`, an offset like `UTC+05:30`, a locale id like
///   `en_IN` — which no answer to a person ever needs;
/// - it narrates the prompt in the third person ("The user is asking…",
///   "The user's locale…"), the other tell of a model reading its own context
///   aloud. The assistant speaks *to* the person; it never has a reason to
///   describe them as "the user".
///
/// Only the **system** turns count as instructions. The user's turn is the
/// material — for the brief it is the day itself, which the answer is supposed
/// to repeat — and the date paragraph `DateContext` writes into the system turn
/// is facts, not instructions: "Tomorrow is Thursday, 22 October 2026." is the
/// right answer to "what's the date tomorrow?" and must survive. That paragraph
/// contributes its identifiers and nothing else.
///
/// Pure and conservative. A sentence is only removed when it matches, so an
/// answer with no echo comes back byte for byte. `isMostlyEcho` is for the
/// brief: when most of what came back was instructions, what is left is not a
/// brief, and the template is the better thing to show.
public struct PromptEcho: Sendable, Equatable {

    /// What one cleaning found.
    public struct Cleaned: Sendable, Equatable {
        /// The answer without the echoed sentences, whitespace tidied where
        /// something was removed and untouched where nothing was.
        public var text: String
        /// The sentences taken out, in order, as they appeared.
        public var echoed: [String]
        /// Share of the answer's words that were echo, 0…1.
        public var echoFraction: Double
        /// Most of the answer was instructions, or too little is left to be an
        /// answer. The brief falls back to its template on this.
        public var isMostlyEcho: Bool

        /// Nothing was removed.
        public var isClean: Bool { echoed.isEmpty }
    }

    /// Lines every chat template or default prompt in this app can carry,
    /// checked whatever the request said. The first is the default Assistant
    /// instructions; the second is what SmolLM2's own template injects when a
    /// conversation has no system turn.
    public static let boilerplate = [
        "You are a helpful assistant.",
        "You are a helpful AI assistant named SmolLM, trained by Hugging Face.",
    ]

    /// Above this share of echoed words the answer is mostly echo.
    public static let mostlyEchoFraction = 0.5
    /// Fewer words than this left after cleaning is not an answer either.
    public static let minimumWordsLeft = 3

    private let sentences: [Fingerprint]
    private let identifiers: Set<String>

    /// - Parameter instructions: the text the model was told and must not
    ///   repeat — the system turns of the request. A paragraph opening with
    ///   `DateContext.lead` is read as facts: only its identifiers are kept.
    public init(instructions: [String]) {
        var prose: [String] = Self.boilerplate
        var identifiers: Set<String> = []
        for text in instructions {
            for paragraph in text.components(separatedBy: "\n\n") {
                identifiers.formUnion(Self.machineIdentifiers(in: paragraph))
                if paragraph.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(DateContext.lead) { continue }
                prose.append(paragraph)
            }
        }
        sentences = prose
            .flatMap(Self.sentences(in:))
            .map(Fingerprint.init)
            .filter { !$0.words.isEmpty }
        self.identifiers = identifiers
    }

    /// The system turns of `messages` as instructions; every other turn is
    /// material and is ignored.
    public init(messages: [ChatMessage]) {
        self.init(instructions: messages.filter { $0.role == .system }.map(\.content))
    }

    /// One call for a caller holding the request it sent.
    public static func clean(_ output: String, against messages: [ChatMessage]) -> Cleaned {
        PromptEcho(messages: messages).clean(output)
    }

    public func clean(_ output: String) -> Cleaned {
        let segments = Self.segments(of: output)
        var kept = ""
        var echoed: [String] = []
        var echoWords = 0
        var totalWords = 0

        for segment in segments {
            let words = Fingerprint.words(in: segment.sentence)
            totalWords += words.count
            if isEcho(segment.sentence, words: words) {
                echoed.append(segment.sentence.trimmingCharacters(in: .whitespacesAndNewlines))
                echoWords += words.count
            } else {
                kept += segment.sentence + segment.separator
            }
        }

        guard !echoed.isEmpty else {
            return Cleaned(text: output, echoed: [], echoFraction: 0, isMostlyEcho: false)
        }
        let text = Self.tidy(kept)
        let fraction = totalWords > 0 ? Double(echoWords) / Double(totalWords) : 0
        let left = Fingerprint.words(in: text).count
        return Cleaned(
            text: text,
            echoed: echoed,
            echoFraction: fraction,
            isMostlyEcho: fraction >= Self.mostlyEchoFraction || left < Self.minimumWordsLeft
        )
    }

    // MARK: - The tests a sentence has to pass

    private func isEcho(_ sentence: String, words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        if identifiers.contains(where: { sentence.contains($0) }) { return true }
        if Self.narratesThePrompt(words) { return true }

        let distinct = Set(words)
        let normalised = words.joined(separator: " ")
        for instruction in sentences {
            if instruction.normalised == normalised { return true }
            // Below three words the overlap test is noise: "Good afternoon,
            // Sam" shares two of its three words with the greeting rule.
            guard distinct.count >= 3 else { continue }
            let shared = distinct.intersection(instruction.words).count
            if Double(shared) >= 0.8 * Double(distinct.count),
               Double(shared) >= 0.5 * Double(instruction.words.count) {
                return true
            }
        }
        return false
    }

    /// "The user is asking about…", "The user's locale is…". Matched on the
    /// opening words only, so a sentence that mentions a user guide later on is
    /// left alone.
    private static func narratesThePrompt(_ words: [String]) -> Bool {
        guard words.count >= 3, words[0] == "the", words[1] == "user" else { return false }
        return ["is", "s", "has", "wants", "asked", "asks", "would", "was", "will", "might", "may"].contains(words[2])
    }

    // MARK: - Text handling

    /// A sentence of the answer and whatever separated it from the next one,
    /// kept so an answer nothing was removed from could be put back exactly.
    private struct Segment {
        var sentence: String
        var separator: String
    }

    /// Splits after `.`, `!`, `?` or `…` when whitespace follows, and at line
    /// breaks. Abbreviations split too, which only ever makes a fragment
    /// shorter and therefore less likely to match.
    private static func segments(of text: String) -> [Segment] {
        var result: [Segment] = []
        var sentence = ""
        var separator = ""
        var previous: Character?

        func close() {
            if !sentence.isEmpty || !separator.isEmpty {
                result.append(Segment(sentence: sentence, separator: separator))
            }
            sentence = ""
            separator = ""
        }

        for character in text {
            if character.isWhitespace {
                let ends = character.isNewline || previous.map { ".!?…".contains($0) } == true
                if ends || !separator.isEmpty {
                    separator.append(character)
                } else {
                    sentence.append(character)
                }
            } else {
                if !separator.isEmpty { close() }
                sentence.append(character)
                previous = character
            }
        }
        close()
        return result
    }

    private static func sentences(in text: String) -> [String] {
        segments(of: text).map(\.sentence).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Collapses the gaps a removal leaves: no run of more than one blank line,
    /// no trailing whitespace.
    private static func tidy(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    /// Strings no person-facing answer contains: time zone ids, UTC offsets,
    /// locale ids. Taken from what the model was actually shown, so a sentence
    /// is only dropped for repeating *this* prompt's machinery.
    static func machineIdentifiers(in text: String) -> Set<String> {
        let patterns = [
            #"\b[A-Z][A-Za-z]+/[A-Z][A-Za-z_]+(?:/[A-Z][A-Za-z_]+)?\b"#,   // Asia/Kolkata, America/Argentina/Buenos_Aires
            #"UTC[+-]\d{2}:\d{2}"#,                                          // UTC+05:30
            #"\b[a-z]{2,3}_[A-Z]{2}\b"#,                                     // en_IN
        ]
        var found: Set<String> = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let swiftRange = Range(match.range, in: text) { found.insert(String(text[swiftRange])) }
            }
        }
        return found
    }

    /// A sentence reduced to what matters for the comparison: lowercased
    /// words, punctuation gone.
    private struct Fingerprint: Sendable, Equatable {
        let normalised: String
        let words: Set<String>

        init(_ sentence: String) {
            let words = Self.words(in: sentence)
            normalised = words.joined(separator: " ")
            self.words = Set(words)
        }

        static func words(in text: String) -> [String] {
            text.lowercased()
                .split { !($0.isLetter || $0.isNumber) }
                .map(String.init)
        }
    }
}
