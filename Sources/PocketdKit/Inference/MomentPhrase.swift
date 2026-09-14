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
/// How often a reminder comes back.
///
/// Only the patterns `EKRecurrenceRule` expresses in one line and a person says
/// in one breath. Anything more elaborate — "the first Monday of the month",
/// "every other Thursday" — is left to the Reminders app, because a rule this
/// code cannot read back to the user in a sentence is a rule they cannot check.
public enum ReminderRepeat: String, Sendable, Equatable, CaseIterable {
    case daily
    /// Monday to Friday. Its own case rather than `weekly` with five days,
    /// because it is the one pattern people ask for by name.
    case weekdays
    /// The same weekday as the first occurrence.
    case weekly
    case monthly
    case yearly

    /// How the confirmation says it, so the user can catch a wrong reading.
    public var sentence: String {
        switch self {
        case .daily: "every day"
        case .weekdays: "every weekday"
        case .weekly: "every week"
        case .monthly: "every month"
        case .yearly: "every year"
        }
    }
}

public enum MomentPhrase {

    /// What a phrase turned out to be.
    public enum Resolution: Sendable, Equatable {
        /// A specific instant. `hasTime` false means the phrase named a day and
        /// no clock time — which `EKReminder` models natively and which must
        /// not be silently turned into midnight.
        case moment(Date, hasTime: Bool)
        /// A pattern, and when it first comes round.
        case repeating(ReminderRepeat, first: Date, hasTime: Bool)
        /// The phrase asks for something to repeat and the pattern or the time
        /// could not be pinned down. Still refused — see `recurrenceCues`.
        case recurring
        /// Nothing dependable could be read out of it.
        case unresolved
    }

    /// What a recurrence cue turned out to mean.
    enum RecurrenceRead: Equatable {
        case none
        /// A cue is present and could not be classified. Refused rather than
        /// guessed: "every so often" is not a schedule.
        case unclassifiable
        case pattern(ReminderRepeat, remainder: String)
    }

    // MARK: - Vocabulary

    /// Words that mean "more than once".
    ///
    /// These used to be refused outright, and the reason was the sharpest
    /// example in this file of the rule above. `NSDataDetector` reads "every
    /// day at 7am" as *today* at 7am: one reminder, no repetition, no error.
    /// The user asked for a daily reminder, watched the app agree, got exactly
    /// one, and had no way to discover that until the second morning.
    ///
    /// They are now honoured where the pattern can be read — `EKReminder`
    /// carries an `EKRecurrenceRule`, so a daily reminder is a native repeating
    /// reminder rather than anything this app has to simulate. The refusal
    /// survives for the cases that cannot be read: a cue with no pattern in it
    /// ("every so often"), or a pattern with no hour ("every day"). Refusing
    /// those is still better than filing one reminder and letting the user find
    /// out on the second morning.
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

        switch readRecurrence(cleaned) {
        case .none:
            break
        case .unclassifiable:
            return .recurring
        case let .pattern(pattern, remainder):
            // The pattern is stripped and what is left is resolved as an
            // ordinary phrase, so "every day at 7am" becomes "at 7am" and gets
            // the same roll-forward, the same tripwire and the same refusal to
            // guess as any other time. A remainder that resolves to nothing is
            // still a refusal: "every day" with no hour in it is not a
            // reminder, it is half of one.
            guard case let .moment(first, hasTime) = resolve(
                remainder,
                now: now,
                calendar: calendar,
                detector: detector
            ) else {
                return .recurring
            }
            return .repeating(pattern, first: first, hasTime: hasTime)
        }

        if let iso = isoDate(from: phrase, timeZone: calendar.timeZone) {
            return .moment(iso, hasTime: true)
        }
        if let relative = relativeOffset(cleaned, now: now, calendar: calendar) {
            return .moment(relative, hasTime: true)
        }

        guard let detected = detector(cleaned) else {
            // Only after the detector has failed, never before it. Run first,
            // this would hijack phrases the detector reads better: "tomorrow at
            // 3pm" contains a 3 and no day word this parser understands, so it
            // would land three o'clock TODAY and be confidently wrong.
            guard let bare = bareClockTime(cleaned, now: now, calendar: calendar) else { return .unresolved }
            return .moment(bare, hasTime: true)
        }
        // The tripwire. Something in the phrase was about time and did not make
        // it into the answer, so the answer is not what was asked for.
        if mentionsTimeBeyond(detected, in: cleaned, calendar: calendar) { return .unresolved }
        return .moment(rollForwardIfBareTimeIsPast(detected, phrase: cleaned, now: now, calendar: calendar), hasTime: true)
    }

    // MARK: - Pieces


    // MARK: - Recurrence

    /// Period nouns that follow "every" or "each". Removed from the phrase,
    /// because "day" in "every day at 7am" is about the pattern and would
    /// otherwise be read as part of the time.
    static let periodWords: [String: ReminderRepeat] = [
        "day": .daily, "days": .daily,
        "weekday": .weekdays, "weekdays": .weekdays,
        "week": .weekly, "weeks": .weekly,
        "month": .monthly, "months": .monthly,
        "year": .yearly, "years": .yearly
    ]

    /// Cues that stand on their own.
    static let standaloneRepeats: [String: ReminderRepeat] = [
        "daily": .daily, "weekly": .weekly, "monthly": .monthly,
        "yearly": .yearly, "annually": .yearly, "weekdays": .weekdays
    ]

    /// Parts of the day that imply a daily pattern and are KEPT, unlike the
    /// period nouns above. "every morning" repeats daily and the word "morning"
    /// is also the only thing in the phrase that says what time — strip it and
    /// there is nothing left to resolve.
    static let timesOfDay: Set<String> = ["morning", "afternoon", "evening", "night"]

    static let weekdayNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "weds", "thu", "thur", "thurs", "fri", "sat", "sun"
    ]

    /// Reads a pattern out of the phrase and hands back what is left.
    ///
    /// Word by word rather than by pattern-matching whole phrases, because the
    /// orders people use are not enumerable: "every day at 7am", "at 7am every
    /// day", "daily at 9", "every Tuesday at 6pm" and "every weekday morning"
    /// all have to land, and a list of templates would miss the sixth.
    static func readRecurrence(_ phrase: String) -> RecurrenceRead {
        // Split on whitespace, not through `tokens(in:)`, which drops every
        // non-alphanumeric character — "17:30" would come back as two words and
        // the remainder would no longer be a time.
        let raw = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        let bare = raw.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
        guard bare.contains(where: recurrenceCues.contains) else { return .none }

        var pattern: ReminderRepeat?
        var remainder: [String] = []
        var index = 0

        while index < raw.count {
            let word = bare[index]

            if word == "every" || word == "each" {
                let next = index + 1 < bare.count ? bare[index + 1] : ""
                if let period = periodWords[next] {
                    // "every day", "every weekday" — both words go.
                    pattern = period
                    index += 2
                    continue
                }
                if weekdayNames.contains(next) {
                    // "every Tuesday" — weekly, and the weekday stays so that
                    // the detector can work out which Tuesday comes next.
                    pattern = .weekly
                    index += 1
                    continue
                }
                if timesOfDay.contains(next) {
                    // "every morning" — daily, and the word stays because it is
                    // also the only time in the phrase.
                    pattern = .daily
                    index += 1
                    continue
                }
                // "every so often", "every now and then". A cue with no
                // readable pattern is not a schedule.
                return .unclassifiable
            }

            if let standalone = standaloneRepeats[word] {
                pattern = standalone
                index += 1
                continue
            }

            // Bare intensifiers that carry no pattern of their own. Dropped so
            // they cannot confuse the detector, but they do not set a pattern:
            // "repeat" on its own says nothing about how often.
            if ["repeating", "repeat", "repeatedly", "recurring", "always"].contains(word) {
                index += 1
                continue
            }

            remainder.append(raw[index])
            index += 1
        }

        guard let pattern else { return .unclassifiable }
        return .pattern(pattern, remainder: remainder.joined(separator: " "))
    }

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


    /// An hour with no date around it — "at 9", "morning at 7", "17:30".
    ///
    /// Needed because `NSDataDetector` returns NO MATCH for a bare hour without
    /// am or pm: "at 7am" resolves and "at 9" does not. That gap is invisible
    /// until it lands on the commonest phrasing there is — "daily at 9" — and
    /// refuses it, which is how a repeating reminder feature ships looking
    /// broken.
    ///
    /// Where there is no am/pm and no part-of-day word, the answer is the NEXT
    /// nine o'clock, whichever half of the day that falls in. That is a choice
    /// rather than a reading, and it is the one every clock app on the phone
    /// makes; the confirmation says which one it picked, so a user who meant
    /// the other one sees it in the same breath rather than the next morning.
    static func bareClockTime(_ phrase: String, now: Date, calendar: Calendar) -> Date? {
        let words = phrase.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }

        var hour: Int?
        var minute = 0
        // A digit alone is not a time. "in 20 bananas" reached this parser
        // after the relative and detector passes both declined it, and 20
        // became eight in the evening — the confidently-wrong answer this whole
        // file exists to refuse, reintroduced by the fallback meant to help.
        // So a number counts only with something beside it saying it is a
        // clock: a colon, an am/pm, or the word "at" immediately before it.
        var isClock = false
        for (index, word) in words.enumerated() {
            let pieces = word.split(separator: ":", omittingEmptySubsequences: false)
            if pieces.count == 2, let h = Int(pieces[0]), let m = Int(pieces[1]), (0...23).contains(h), (0...59).contains(m) {
                hour = h
                minute = m
                isClock = true
                break
            }
            if word.count > 2, word.hasSuffix("am") || word.hasSuffix("pm"), let h = Int(word.dropLast(2)), (1...12).contains(h) {
                hour = h
                isClock = true
                break
            }
            if let h = Int(word), (0...23).contains(h) {
                let precededByAt = index > 0 && words[index - 1] == "at"
                let followedByMeridiem = index + 1 < words.count && ["am", "pm"].contains(words[index + 1])
                guard precededByAt || followedByMeridiem else { continue }
                hour = h
                isClock = true
                break
            }
        }
        guard isClock else { return nil }
        guard var resolved = hour else { return nil }

        let set = Set(words)
        let saysMorning = !set.isDisjoint(with: ["am", "morning"])
        let saysLater = !set.isDisjoint(with: ["pm", "afternoon", "evening", "night", "tonight"])
        // A word that suffixed a number rather than standing alone.
        let suffixedAM = words.contains { $0.hasSuffix("am") && Int($0.dropLast(2)) != nil }
        let suffixedPM = words.contains { $0.hasSuffix("pm") && Int($0.dropLast(2)) != nil }

        if resolved <= 12, saysMorning || suffixedAM {
            if resolved == 12 { resolved = 0 }
        } else if resolved <= 12, saysLater || suffixedPM {
            if resolved != 12 { resolved += 12 }
        } else if resolved <= 12 {
            // Neither said. Take whichever of the two comes round first.
            let today = calendar.startOfDay(for: now)
            let candidates = [resolved, resolved + 12].compactMap {
                calendar.date(byAdding: DateComponents(hour: $0, minute: minute), to: today)
            }
            if let next = candidates.filter({ $0 > now }).min() { return next }
            // Both gone today, so the earlier of the two tomorrow.
            return candidates.min().flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        }

        let today = calendar.startOfDay(for: now)
        guard let candidate = calendar.date(byAdding: DateComponents(hour: resolved, minute: minute), to: today) else {
            return nil
        }
        guard candidate <= now else { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
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
