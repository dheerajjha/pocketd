import Foundation

/// How long a new calendar event lasts.
///
/// Apple's model fills `duration_minutes` whether or not anybody said how long.
/// Measured on the Mac against the iOS 27 model: "add dinner with Priya at 8pm"
/// came back with a length nine times in ten — 30, 120, and with the current
/// guidance mostly 480, so dinner ran until four in the morning — and no wording
/// of the argument's guidance stopped it ("only if the user said", "null if they
/// did not"). Every length a person DID say ("a 90 minute workout", "for two
/// hours") came back right.
///
/// So the number is believed only when the person's own words state a length,
/// and otherwise the event gets the hour every calendar app defaults to. A rule
/// here rather than more wording there, because wording is what was tried; and
/// here, in the tool body both brains share, rather than in one brain's wrapper,
/// so a downloaded brain that invents a length gets the same answer.
public enum EventLength {

    /// The longest a length is believed when there are no words to check it
    /// against: a full working day and then some, and nowhere near the extra
    /// digit a model adds to one.
    public static let uncheckedCeilingMinutes = 12 * 60

    /// The event's length in minutes: the model's, if the person said how long,
    /// and an hour if they did not.
    ///
    /// - Parameters:
    ///   - stated: The person's latest message, as they wrote it. `nil` when no
    ///     person's words reach the tool — a network client, or a body called
    ///     outside a conversation — and then the model's number stands unless it
    ///     runs past twelve hours, because there is nothing to hold it against.
    ///   - modelMinutes: What the model put in `duration_minutes`.
    /// - Returns: Always positive, and never past
    ///   `PersonalDataWrites.maximumEventMinutes`.
    public static func decide(stated: String?, modelMinutes: Int?) -> Int {
        guard let stated, !stated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let modelMinutes, modelMinutes > 0, modelMinutes <= uncheckedCeilingMinutes else {
                return PersonalDataWrites.defaultEventMinutes
            }
            return modelMinutes
        }
        // Said, and the model left it out anyway: the default, not a number read
        // out of the words here. The model reads "90 minute" correctly every
        // time it is measured; what it cannot do is leave the field alone.
        guard statesALength(stated) else { return PersonalDataWrites.defaultEventMinutes }
        return PersonalDataWrites.resolvedMinutes(modelMinutes)
    }

    // MARK: - Did they say how long?

    /// Whether the words say how long something lasts or when it ends: "for 2
    /// hours", "a 90-minute workout", "half an hour", "an hour long", "all day",
    /// "from 2 to 4", "until 9".
    ///
    /// A question about the words, deliberately not an attempt to read the
    /// number out of them, and it leans towards yes. A yes keeps the model's
    /// number, which is all that happened before this existed; a wrong no
    /// replaces a length the person did say with an hour.
    ///
    /// The no that matters is for the sentences people actually type to add
    /// something — "dinner with Priya at 8pm", "lunch with Sam on Friday at 1",
    /// "dinner for 2 at 8" — and for the time words that are about when it
    /// starts rather than how long it runs: "in 20 minutes", "2 hours from now".
    public static func statesALength(_ text: String) -> Bool {
        let words = words(in: text, hyphens: .joined)
        if words.indices.contains(where: { saysAnAmountOfTime(at: $0, in: words) }) { return true }
        if words.indices.contains(where: { saysAWholeStretch(at: $0, in: words) }) { return true }
        if words.indices.contains(where: { saysWhenItEnds(at: $0, in: words) }) { return true }
        let marked = self.words(in: text, hyphens: .separate)
        return marked.indices.contains { saysARange(at: $0, in: marked) }
    }

    /// "an hour", "90 minutes", "2 hours" — the length as the confirmation says
    /// it, so the card states what was actually written.
    static func spoken(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if minutes >= 1440, minutes % 1440 == 0 {
            return minutes == 1440 ? "a day" : "\(minutes / 1440) days"
        }
        switch minutes {
        case 1: return "1 minute"
        case 60: return "an hour"
        case ..<120 where rest != 0: return "\(minutes) minutes"
        default: return rest == 0 ? "\(hours) hours" : "\(hours) hours \(rest) minutes"
        }
    }

    // MARK: Vocabulary

    static let units: Set<String> = [
        "minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs",
        "day", "days", "week", "weeks"
    ]

    /// A number glued to its unit: "90min", "2hrs", "45m", "1h".
    static let gluedUnits: Set<String> = [
        "m", "min", "mins", "minute", "minutes", "h", "hr", "hrs", "hour", "hours", "d", "day", "days"
    ]

    /// Words that make up an amount, so the amount in "a couple of hours" or
    /// "an hour and a half" can be walked back to whatever came before it.
    static let amountWords: Set<String> = [
        "a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "half", "quarter", "quarters", "couple", "few", "several", "of", "and"
    ]

    /// Before an amount: it says when, not how long. "in 20 minutes", "every 2
    /// hours".
    static let startsBefore: Set<String> = ["in", "within", "every", "each"]

    /// After an amount: the same. "2 hours from now", "30 minutes before the
    /// game", "an hour later".
    static let startsAfter: Set<String> = [
        "from", "later", "ago", "before", "after", "earlier", "prior", "beforehand", "early", "late", "out"
    ]

    /// "all day", "the whole afternoon", "a full week".
    static let wholeWords: Set<String> = ["all", "whole", "full", "entire"]
    static let stretches: Set<String> = ["day", "morning", "afternoon", "evening", "night", "week", "weekend"]

    static let untilWords: Set<String> = ["until", "till", "til", "untill"]
    static let endWords: Set<String> = ["end", "ends", "ending", "finish", "finishes", "finishing"]

    /// Where an end follows a start: "2 to 4", "2-4pm", "9 through 5".
    static let rangeMarkers: Set<String> = ["to", "-", "through", "thru"]

    static let hourWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "noon": 12, "midday": 12, "midnight": 0
    ]

    // MARK: The four ways a length is said

    /// "2 hours", "a 90 minute workout", "half an hour", "a couple of hours",
    /// "45 min", "1h30" — and not "happy hour", "office hours" or "last
    /// minute", which have a unit and no amount, nor "in 20 minutes" or "2
    /// hours from now", which say when it starts.
    static func saysAnAmountOfTime(at index: Int, in words: [String]) -> Bool {
        var first = index
        if !isGluedAmount(words[index]) {
            guard units.contains(words[index]) else { return false }
            var cursor = index - 1
            while cursor >= 0, isAmount(words[cursor]) { cursor -= 1 }
            guard cursor < index - 1 else { return false }
            first = cursor + 1
        }
        let before = first > 0 ? words[first - 1] : ""
        // "for" settles it whatever follows: "for 2 hours from 3pm" is a length
        // and a start.
        if before == "for" { return true }
        if startsBefore.contains(before) { return false }
        let after = index + 1 < words.count ? words[index + 1] : ""
        return !startsAfter.contains(after)
    }

    /// "all day", "all-day", "the whole afternoon", "a full week", "for the day".
    static func saysAWholeStretch(at index: Int, in words: [String]) -> Bool {
        if words[index] == "allday" { return true }
        guard index + 1 < words.count, stretches.contains(words[index + 1]) else { return false }
        if wholeWords.contains(words[index]) { return true }
        return words[index] == "the" && index > 0 && words[index - 1] == "for"
    }

    /// "until 9", "till 6pm", "ends at 5", "finishing around 10:30".
    static func saysWhenItEnds(at index: Int, in words: [String]) -> Bool {
        if untilWords.contains(words[index]) { return true }
        guard endWords.contains(words[index]), index + 1 < words.count else { return false }
        return ["at", "by", "around", "about"].contains(words[index + 1])
    }

    /// "from 2 to 4", "2-4pm", "9 to 5", "14:00–15:30", "between 2 and 4".
    ///
    /// Read on words that keep their hyphens, because a hyphen is the commonest
    /// way to write a range and also the way people write "1-1" and "1-2-1" for
    /// a meeting with one person. A range that starts and ends at the same hour
    /// is not a range, and one that runs on into another number is not either.
    /// "at 8pm to my calendar" is not one because "my" is not a time.
    static func saysARange(at index: Int, in words: [String]) -> Bool {
        if words[index] == "between" {
            guard index + 3 < words.count, let from = clock(words[index + 1]) else { return false }
            let rest = words[(index + 2)...].prefix(3)
            guard let and = rest.firstIndex(of: "and"), and + 1 < words.count, let to = clock(words[and + 1]) else { return false }
            return from != to
        }
        guard rangeMarkers.contains(words[index]), index > 0, index + 1 < words.count else { return false }
        var left = index - 1
        if ["am", "pm"].contains(words[left]), left > 0 { left -= 1 }
        var right = index + 1
        guard let from = clock(words[left]), let to = clock(words[right]) else { return false }
        if right + 1 < words.count, ["am", "pm"].contains(words[right + 1]) { right += 1 }
        let runsOn = (left > 0 && rangeMarkers.contains(words[left - 1]))
            || (right + 1 < words.count && rangeMarkers.contains(words[right + 1]))
        return from != to && !runsOn
    }

    // MARK: Pieces

    /// A number, a number word or a fraction that can be part of an amount.
    static func isAmount(_ word: String) -> Bool {
        if amountWords.contains(word) { return true }
        let fractions: Set<Character> = ["½", "¼", "¾", "⅓", "⅔"]
        let digits = word.filter { !fractions.contains($0) }
        if digits.isEmpty { return word.contains(where: fractions.contains) }
        return isNumeral(digits)
    }

    /// "2", "90", "1.5".
    static func isNumeral(_ word: String) -> Bool {
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// "90min", "2hrs", "45m", "1h", "1h30", "1h30m" — never "8am", "2nd" or
    /// "5k".
    static func isGluedAmount(_ word: String) -> Bool {
        let number = word.prefix { ($0.isASCII && $0.isNumber) || $0 == "." }
        guard let lead = number.first, lead.isNumber, isNumeral(String(number)) else { return false }
        let unit = word.dropFirst(number.count)
        if gluedUnits.contains(String(unit)) { return true }
        guard unit.hasPrefix("h") else { return false }
        let afterHour = unit.dropFirst()
        let minutes = afterHour.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(minutes.count) else { return false }
        return ["", "m", "min", "mins"].contains(String(afterHour.dropFirst(minutes.count)))
    }

    /// A clock time as minutes past midnight: "2", "4pm", "14:00", "8.30",
    /// "noon", "two". Only for telling a range from a pair of equal numbers, so
    /// "4pm" and "4" are not told apart and do not need to be.
    static func clock(_ word: String) -> Int? {
        if let hour = hourWords[word] { return hour * 60 }
        var digits = Substring(word)
        for suffix in ["am", "pm", "a", "p"] where digits.hasSuffix(suffix) {
            digits = digits.dropLast(suffix.count)
            break
        }
        let pieces = digits.split(whereSeparator: { $0 == ":" || $0 == "." }).map(String.init)
        guard (1...2).contains(pieces.count),
              pieces.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hour = Int(pieces[0]), (0...23).contains(hour)
        else { return nil }
        let minute = pieces.count == 2 ? Int(pieces[1]) ?? 60 : 0
        guard (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    enum Hyphens {
        /// "90-minute" as "90 minute", "all-day" as "all day".
        case joined
        /// "2-4pm" as "2 - 4pm", so a range can be seen.
        case separate
    }

    /// Lowercased words, with the punctuation that sits on them removed and a
    /// possessive taken off ("a week's holiday").
    static func words(in text: String, hyphens: Hyphens) -> [String] {
        var text = text.lowercased()
            // U+2019, which is what iOS smart punctuation types.
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "a.m.", with: "am")
            .replacingOccurrences(of: "p.m.", with: "pm")
        for dash in ["\u{2013}", "\u{2014}", "-"] {
            text = text.replacingOccurrences(of: dash, with: hyphens == .separate ? " - " : " ")
        }
        return text
            .split(whereSeparator: { $0.isWhitespace || ",;!?()\"/".contains($0) })
            .map { piece -> String in
                var word = piece.trimmingCharacters(in: CharacterSet(charactersIn: ".:'"))
                if word.hasSuffix("'s") { word.removeLast(2) }
                return word
            }
            .filter { !$0.isEmpty }
    }
}

// MARK: - The person's words, for the tool bodies

public extension ToolContext {
    /// The person's own latest message, for the answer being written now.
    ///
    /// Bound beside `origin`, for the one decision a tool body must not take
    /// from the model alone: whether anybody said how long an event lasts
    /// (`EventLength`). Out of band for the reason `origin` is — llama.cpp's
    /// tools are frozen into the client at load, so nothing per-request can
    /// reach them through their arguments — and bound by both engines from the
    /// same request, through `userText(of:)`.
    ///
    /// `nil` by default, and for a network client: what another device sends
    /// as its last message is whatever its software put there, not a person's
    /// sentence about one event — and it may not write anyway.
    @TaskLocal static var userText: String?

    /// What `userText` is for a request: the latest user turn of a request from
    /// this phone, and nothing for anyone else.
    static func userText(of request: GenerationRequest) -> String? {
        guard request.origin.isThisPhone else { return nil }
        return request.messages.last(where: { $0.role == .user })?.content
    }
}
