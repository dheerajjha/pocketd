import Foundation
import PocketdKit

/// The brain's sentence over a data block, in the app's own spelling.
///
/// The block under an answer is written by the app — "3:00 PM", "1 reminder" —
/// and the sentence over it by the brain, which writes "3pm" and "one overdue
/// reminder". Side by side in one card that reads as two authors disagreeing
/// about the same fact. So the sentence is set the way the brief is: a time in
/// the phone's own format, and a small count in digits before the thing it
/// counts.
///
/// Only over a data block. A story or an explanation is prose, and "one thing
/// I love about the sea" is a sentence, not a count; `AskMessageRow` leaves
/// those exactly as written. Display only, too: the brain's history keeps its
/// own words.
enum AnswerWords {

    static func screened(
        _ text: String,
        now: Date = DemoClock.now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let timed = formattingTimes(relativeDays(text, now: now, calendar: calendar), calendar: calendar, locale: locale)
        return curlingQuotes(digitisingCounts(timed))
    }

    // MARK: - Days

    /// "for Thu, 22 Oct at 6:00 PM" → "for tomorrow at 6:00 PM", when Thursday
    /// is tomorrow; yesterday and today the same way. The tools write the date
    /// with `PersonalDataFormat.day`, so the same formatter finds it; a date
    /// further off keeps its weekday, which already says when.
    ///
    /// Read against now, not against when the sentence was written: a
    /// reminder set yesterday "for tomorrow" is today's reminder when the
    /// conversation is opened again.
    static func relativeDays(_ text: String, now: Date = DemoClock.now, calendar: Calendar = .current) -> String {
        var result = text
        for (offset, word) in [(-1, "yesterday"), (0, "today"), (1, "tomorrow")] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let written = PersonalDataFormat.day(day, timeZone: calendar.timeZone, calendar: calendar)
            guard result.contains(written) else { continue }
            // "on tomorrow" is not English; the day word stands alone.
            result = result.replacingOccurrences(of: " on \(written)", with: " \(word)")
            result = result.replacingOccurrences(of: written, with: word)
        }
        return result
    }

    // MARK: - Times

    /// "3pm", "3 pm", "3:30pm", "10 a.m." → this phone's own `Format.time`:
    /// "3:00 PM" where the phone says 3 PM, "15:00" where it says 15:00 — the
    /// same spelling the timeline under the sentence uses.
    static func formattingTimes(_ text: String, calendar: Calendar = .current, locale: Locale = .current) -> String {
        // "PM." at the end of a sentence is a time and a full stop: the
        // stop is only swallowed as part of "p.m.", and given back below.
        let pattern = #"(?i)\b(1[0-2]|0?[1-9])(?::([0-5][0-9]))?\s?(a\.m\.|p\.m\.|a\.m|p\.m|am|pm)(?![a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let hour = Int(source.substring(with: match.range(at: 1))) else { continue }
            let minute = match.range(at: 2).location == NSNotFound ? 0 : Int(source.substring(with: match.range(at: 2))) ?? 0
            let isAfternoon = source.substring(with: match.range(at: 3)).lowercased().hasPrefix("p")
            let hour24 = (hour % 12) + (isAfternoon ? 12 : 0)
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = hour24
            components.minute = minute
            guard let date = calendar.date(from: components) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += Format.time(date, calendar: calendar, locale: locale)
            cursor = match.range.location + match.range.length
            // "…at 6 p.m." ending the sentence: the abbreviation's last dot was
            // also the full stop.
            if source.substring(with: match.range(at: 3)).hasSuffix("."), endsSentence(source, at: cursor) {
                result += "."
            }
        }
        result += source.substring(from: cursor)
        return result
    }

    /// Whether what follows `location` starts a new sentence or ends the text.
    private static func endsSentence(_ source: NSString, at location: Int) -> Bool {
        guard location < source.length else { return true }
        let rest = source.substring(from: location)
        if rest.hasPrefix("\n") { return true }
        guard rest.hasPrefix(" "), let next = rest.dropFirst().first else { return false }
        return next.isUppercase
    }

    // MARK: - Counts

    static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]

    /// What an answer about the day counts.
    static let countedNouns: Set<String> = [
        "reminder", "reminders", "event", "events", "meeting", "meetings",
        "appointment", "appointments", "task", "tasks", "item", "items",
        "hour", "hours", "minute", "minutes", "day", "days", "night", "nights",
        "step", "steps", "workout", "workouts", "call", "calls",
    ]

    /// Words that may stand between a count and its noun: "two more
    /// reminders", "one overdue reminder".
    static let countAdjectives: Set<String> = [
        "overdue", "more", "new", "other", "upcoming", "open", "remaining", "due",
        "short", "long", "late", "early", "separate", "scheduled", "unfinished",
    ]

    /// "You have one overdue reminder" → "You have 1 overdue reminder". Only
    /// before a counted noun, so "one of them", "no one" and "the one at
    /// four" keep their words.
    static func digitisingCounts(_ text: String) -> String {
        var pieces = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in pieces.indices {
            guard let value = numberWords.firstIndex(of: bare(pieces[index]).lowercased()) else { continue }
            // The word itself must be whole: "one," ends a clause and counts
            // nothing.
            guard pieces[index].allSatisfy(\.isLetter) else { continue }
            var next = index + 1
            if next < pieces.count, countAdjectives.contains(bare(pieces[next]).lowercased()) { next += 1 }
            guard next < pieces.count, countedNouns.contains(bare(pieces[next]).lowercased()) else { continue }
            pieces[index] = String(value + 1)
        }
        return pieces.joined(separator: " ")
    }

    /// A word without the punctuation around it.
    private static func bare(_ piece: String) -> String {
        piece.trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    // MARK: - Quotes

    /// `"Call Mom"` → “Call Mom”. Only when the straight quotes pair up — an
    /// odd one out is a measurement or a typo, and left alone.
    static func curlingQuotes(_ text: String) -> String {
        guard text.contains("\""), text.filter({ $0 == "\"" }).count.isMultiple(of: 2) else { return text }
        var opening = true
        return String(text.map { character in
            guard character == "\"" else { return character }
            defer { opening.toggle() }
            return opening ? "\u{201C}" : "\u{201D}"
        })
    }
}
