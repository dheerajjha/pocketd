import Foundation

/// Turning "2 AM today" into a `Date`, on the device, with nothing guessed.
///
/// `CalendarRange` explains why the *read* tools take four fixed values instead
/// of a date: a 1–3B model asked for an ISO string emits `2025-13-01` or a year
/// in the 0002s often enough that it has to be planned for. A write cannot dodge
/// the problem the same way, because the time is the user's and it is arbitrary
/// — there is no enum with "2am" in it. So the arithmetic moves here, where a
/// calendar, a time zone and the current instant all exist and none of them are
/// the model's problem, and the model's job shrinks to relaying the words the
/// user typed.
///
/// The rule the whole file is built around: **never return a time nobody asked
/// for.** A reminder at the wrong hour is worse than no reminder, because the
/// user believes it is set. Every path that cannot be sure answers
/// `.unresolved` and the tool asks, which costs a turn and is always cheaper
/// than a missed alarm.
public enum MomentPhrase {

    /// What a phrase turned out to be.
    public enum Resolution: Sendable, Equatable {
        /// A specific instant. `hasTime` false means the phrase named a day and
        /// no clock time — which `EKReminder` models natively and which must
        /// not be silently turned into midnight.
        case moment(Date, hasTime: Bool)
        /// The phrase asks for something to repeat. Refused rather than
        /// flattened — see `recurrenceCues`.
        case recurring
        /// Nothing dependable could be read out of it.
        case unresolved
    }

    // MARK: - Vocabulary

    /// Words that mean "more than once".
    ///
    /// These are refused, and the reason is the sharpest example in this file
    /// of the rule above. `NSDataDetector` reads "every day at 7am" as *today*
    /// at 7am: one reminder, no repetition, no error. The user asked for a
    /// daily reminder, watched the app agree, got exactly one, and has no way
    /// to discover that until the second morning. Answering "I cannot set a
    /// repeating reminder" is a worse demo and an honest one — and this app has
    /// a scheduling engine with a real `Recurrence` type, so the right answer
    /// is to point at it rather than to fake it here.
    static let recurrenceCues: Set<String> = [
        "every", "each", "daily", "weekly", "monthly", "yearly", "annually",
        "repeating", "repeat", "repeatedly", "recurring", "always", "weekdays", "weekends"
    ]

    /// Words that are about clock time.
    ///
    /// Used only as a tripwire. After the detector has had its go, any of these
    /// left *outside* what it matched means the phrase said something about the
    /// time that was not understood, and the answer it produced is therefore
    /// not the one that was asked for. "half past four tomorrow" is the case
    /// this exists for: the detector matches "tomorrow", silently drops "half
    /// past four", and returns noon.
    static let clockWords: Set<String> = [
        "half", "past", "quarter", "to", "oclock", "o", "clock",
        "am", "pm", "noon", "midday", "midnight", "morning", "afternoon",
        "evening", "night", "tonight", "minute", "minutes", "hour", "hours",
        "sharp", "ish"
    ]

    // MARK: - Entry point

    /// - Parameter detector: The fallback natural-language pass. Injected so
    ///   that every decision in this file is testable against a fixed `now`:
    ///   `NSDataDetector` resolves "tomorrow" against the real system clock and
    ///   offers no way to anchor it, which would make these tests depend on the
    ///   hour they ran at.
    public static func resolve(
        _ phrase: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        detector: (String) -> Date? = MomentPhrase.systemDetector
    ) -> Resolution {
        let cleaned = normalise(phrase)
        guard !cleaned.isEmpty else { return .unresolved }

        let words = Set(tokens(in: cleaned))
        if !words.isDisjoint(with: recurrenceCues) { return .recurring }

        if let iso = isoDate(from: phrase, timeZone: calendar.timeZone) {
            return .moment(iso, hasTime: true)
        }
        if let relative = relativeOffset(cleaned, now: now, calendar: calendar) {
            return .moment(relative, hasTime: true)
        }

        guard let detected = detector(cleaned) else { return .unresolved }
        // The tripwire. Something in the phrase was about time and did not make
        // it into the answer, so the answer is not what was asked for.
        if mentionsTimeBeyond(detected, in: cleaned, calendar: calendar) { return .unresolved }
        return .moment(rollForwardIfBareTimeIsPast(detected, phrase: cleaned, now: now, calendar: calendar), hasTime: true)
    }

    // MARK: - Pieces

    static func normalise(_ phrase: String) -> String {
        phrase
            // U+2019, which is what iOS smart punctuation inserts and what the
            // user's own words therefore contain — the same trap
            // `ToolOffer` documents for "what's".
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func tokens(in phrase: String) -> [String] {
        phrase.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// A model that does emit a well-formed ISO string is honoured rather than
    /// second-guessed. Both shapes, because the common mistake is omitting the
    /// zone, not inventing one.
    /// - Parameter timeZone: The caller's zone, for the two shapes that carry
    ///   none. Threaded in rather than left to `DateFormatter`'s default,
    ///   which is the *system* zone: a phone in Mumbai parsing a string meant
    ///   for a London calendar would land five and a half hours out, and
    ///   nothing about the result would look wrong.
    static func isoDate(from phrase: String, timeZone: TimeZone) -> Date? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cheap reject first: every accepted shape starts with four digits and
        // a dash, and running two formatters over "tomorrow at 3pm" is waste.
        guard trimmed.count >= 16, trimmed.prefix(4).allSatisfy(\.isNumber), trimmed.dropFirst(4).hasPrefix("-") else {
            return nil
        }
        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: trimmed) { return date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = local.date(from: trimmed) { return date }
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return local.date(from: trimmed)
    }

    /// "in 20 minutes", "in 2 hours".
    ///
    /// Handled here and not left to the detector because the detector does not
    /// handle it at all — it returns no match for "in 20 minutes" — and it is
    /// one of the two or three ways anybody actually asks for a short timer.
    static func relativeOffset(_ phrase: String, now: Date, calendar: Calendar) -> Date? {
        // Split on whitespace rather than through `tokens(in:)`, which drops
        // every non-alphanumeric character — including the minus sign, so
        // "in -5 minutes" arrived here as 5 and quietly became a reminder five
        // minutes from now. The sign has to survive as far as the `> 0` test.
        let words = phrase.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
        guard let anchor = words.firstIndex(of: "in"), words.count > anchor + 2 else { return nil }
        guard let amount = Int(words[anchor + 1]), amount > 0 else { return nil }
        let unit = words[anchor + 2]
        let component: Calendar.Component
        switch unit {
        case "minute", "minutes", "min", "mins": component = .minute
        case "hour", "hours", "hr", "hrs": component = .hour
        case "day", "days": component = .day
        case "week", "weeks": component = .weekOfYear
        default: return nil
        }
        return calendar.date(byAdding: component, value: amount, to: now)
    }

    /// Whether the phrase talks about a time the resolved date does not account
    /// for.
    ///
    /// Conservative on purpose: it only fires when a clock word is present AND
    /// the resolved time is midnight-ish or noon-ish, the two values a detector
    /// falls back on when it gives up on the time half. Firing on every clock
    /// word would reject "tomorrow morning", which resolves fine.
    static func mentionsTimeBeyond(_ resolved: Date, in phrase: String, calendar: Calendar) -> Bool {
        let words = Set(tokens(in: phrase))
        // "half past four" and "quarter to six" are the shapes that break it.
        // A lone "past" or "to" is ordinary English; the pair is not.
        let compound = words.contains("half") || words.contains("quarter")
        guard compound else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: resolved)
        let isFallbackHour = (parts.hour == 0 || parts.hour == 12) && parts.minute == 0
        return isFallbackHour
    }

    /// A bare time already gone today means the next one.
    ///
    /// "Remind me at 7" said at nine in the evening means seven tomorrow, which
    /// is what every clock app on the phone does. But "2am today" said at 3am
    /// means 2am today — the user named the day and is owed the day they named,
    /// even though it is behind them, because an overdue reminder is a real and
    /// useful thing and a silently moved one is not.
    static func rollForwardIfBareTimeIsPast(
        _ resolved: Date,
        phrase: String,
        now: Date,
        calendar: Calendar
    ) -> Date {
        guard resolved < now else { return resolved }
        let words = Set(tokens(in: phrase))
        let namesADay = !words.isDisjoint(with: [
            "today", "tonight", "tomorrow", "yesterday",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june", "july",
            "august", "september", "october", "november", "december"
        ])
        guard !namesADay else { return resolved }
        // Only ever by whole days, and only while it is still behind: adding a
        // fixed 24 hours would land an hour out across a daylight-saving change.
        var candidate = resolved
        var guardRail = 0
        while candidate < now, guardRail < 8 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return resolved }
            candidate = next
            guardRail += 1
        }
        return candidate
    }

    /// The real natural-language pass.
    ///
    /// `NSDataDetector` is genuinely good at this — "2 AM today", "tomorrow at
    /// 3pm", "next Friday at 9" and "25 December at noon" all land — and it is
    /// on the device, free, and older than any of us. What it is not is honest
    /// about failure, which is what everything above compensates for.
    public static func systemDetector(_ phrase: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(phrase.startIndex..., in: phrase)
        return detector.matches(in: phrase, range: range).first?.date
    }
}
