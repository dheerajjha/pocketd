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
            return .moment(relative.date, hasTime: relative.hasTime)
        }
        // "6pm", "at 18:00": a clock time and nothing else, read here against
        // the `now` and calendar this was handed. The detector reads the same
        // words against the system clock and zone, and with a calendar in any
        // other zone that is a different hour — "6pm" asked at 14:33 by a UTC
        // calendar, on a machine in Kolkata, came back as 12:30 UTC, already
        // gone, and was moved to tomorrow. A whole hour on its own — "at 5",
        // "5 o'clock" — comes here too, for the one-to-six rule in
        // `bareClockTime`. "09:00" is left to the passes below, as before.
        if isUnambiguousClockTime(cleaned) || isLoneHour(cleaned),
           let clock = bareClockTime(cleaned, now: now, calendar: calendar) {
            return .moment(clock, hasTime: true)
        }
        // "Friday 5" and "Friday at 5", one reading. The detector reads the
        // first as a date of the month — Thursday 5 November at noon, Monday 10
        // August — so both are asked as "friday at 5", which it reads right,
        // and only the hour of its answer is kept: the day is the next Friday.
        if let asked = weekdayAndHour(cleaned) {
            guard let read = detector(asked.phrase),
                  isReading(read, of: asked.hour, calendar: calendar),
                  let next = nextWeekday(asked.weekday, atTimeOf: read, now: now, calendar: calendar)
            else { return .unresolved }
            return .moment(next, hasTime: true)
        }
        // "next week", "this weekend", "on the 25th": days the detector has no
        // match for at all.
        if let day = dayWithoutATime(cleaned, now: now, calendar: calendar) {
            return .moment(day, hasTime: false)
        }

        let asked = withAtBeforeLoneHour(cleaned)
        guard let detected = detector(asked) else {
            // Anything but a bare clock time comes here only after the detector
            // has failed. Run first, this would hijack phrases the detector
            // reads better: "tomorrow at 3pm" contains a 3 and no day word
            // this parser understands, so it would land three o'clock TODAY
            // and be confidently wrong.
            guard let bare = bareClockTime(cleaned, now: now, calendar: calendar) else { return .unresolved }
            return .moment(bare, hasTime: true)
        }
        // The tripwire. Something in the phrase was about time and did not make
        // it into the answer, so the answer is not what was asked for.
        if mentionsTimeBeyond(detected, in: cleaned, calendar: calendar) { return .unresolved }
        // A day and no time — "tomorrow", "Friday", "next Monday" — is a date.
        // The detector answers every one of them with noon, its fallback, and
        // taken as a time that was the hour nobody asked for: "remind me to buy
        // milk tomorrow", which Apple's model passed on as "tomorrow", went off
        // at 12:00 PM.
        guard saysATimeOfDay(asked) else {
            return .moment(calendar.startOfDay(for: detected), hasTime: false)
        }
        return .moment(rollForwardIfBareTimeIsPast(detected, phrase: cleaned, now: now, calendar: calendar), hasTime: true)
    }

    /// Whether the words name a time of day — so the detector's hour is the
    /// person's, and not its noon for a phrase that named only a day.
    ///
    /// "at 9", "9:30", "9am", "noon", "tonight", "tomorrow morning" do; "tomorrow",
    /// "Friday", "25 December" and "october 30" do not.
    static func saysATimeOfDay(_ phrase: String) -> Bool {
        let words = phrase.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
        // "half" and "quarter" too: "half past four tomorrow" names a time the
        // detector drops, and it is the tripwire's to refuse, not this rule's
        // to quietly turn into a day.
        let timeWords: Set<String> = [
            "noon", "midday", "midnight", "morning", "afternoon", "evening", "night", "tonight",
            "am", "pm", "o'clock", "oclock", "half", "quarter"
        ]
        let hourWords: Set<String> = [
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"
        ]
        for (index, word) in words.enumerated() {
            if timeWords.contains(word) { return true }
            // "9:30", "17:00", "9.30" — and not "25.12", which is a date.
            let pieces = word.split(whereSeparator: { $0 == ":" || $0 == "." }).map(String.init)
            if pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]),
               pieces[1].count == 2, (0...23).contains(hour), (0...59).contains(minute) {
                return true
            }
            // "9am", "9pm".
            if word.count > 2, word.hasSuffix("am") || word.hasSuffix("pm"), Int(word.dropLast(2)) != nil { return true }
            // "at 9", "at nine".
            if index > 0, words[index - 1] == "at", Int(word) != nil || hourWords.contains(word) { return true }
        }
        return false
    }

    /// "next week", "this weekend", "on the 25th", as the days they are.
    ///
    /// The detector has no match for any of them, so they used to be refused
    /// — "I could not work out when" — although each names a day as plainly as
    /// "tomorrow" does. A day of the month is the next one, today included, so
    /// it is never in the past; "next week" is the first day of next week, as
    /// this calendar counts weeks; "this weekend" is today on a weekend, and
    /// otherwise the first day of the coming one.
    static func dayWithoutATime(_ phrase: String, now: Date, calendar: Calendar) -> Date? {
        var words = phrase.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
            .filter { !$0.isEmpty }
        if let first = words.first, ["on", "at", "by"].contains(first) { words.removeFirst() }
        let today = calendar.startOfDay(for: now)

        switch words {
        case ["this", "weekend"], ["the", "weekend"], ["weekend"]:
            if calendar.isDateInWeekend(now) { return today }
            return calendar.nextWeekend(startingAfter: now).map { calendar.startOfDay(for: $0.start) }
        case ["next", "week"]:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.end
        default:
            break
        }

        // "the 25th", "25th", "the 25".
        let saidThe = words.first == "the"
        if saidThe { words.removeFirst() }
        guard words.count == 1 else { return nil }
        var digits = Substring(words[0])
        var ordinal = false
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
            digits = digits.dropLast(suffix.count)
            ordinal = true
            break
        }
        guard ordinal || saidThe, (1...2).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let day = Int(digits), (1...31).contains(day),
              let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        else { return nil }
        for offset in 0...12 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: thisMonth) else { continue }
            var parts = calendar.dateComponents([.year, .month], from: month)
            parts.day = day
            // The 31st of a 30-day month would spill into the next one.
            guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == day, date >= today else { continue }
            return date
        }
        return nil
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
    ///
    /// Days and weeks come back as the day, with no time: "in 3 days" is a day,
    /// and the minute it happened to be said at is not a time anybody chose.
    static func relativeOffset(_ phrase: String, now: Date, calendar: Calendar) -> (date: Date, hasTime: Bool)? {
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
        guard let date = calendar.date(byAdding: component, value: amount, to: now) else { return nil }
        return component == .day || component == .weekOfYear
            ? (calendar.startOfDay(for: date), false)
            : (date, true)
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


    /// Days a number beside cannot be a date of the month. "Friday 5" can be
    /// Friday the fifth; "tomorrow 9" can only be an hour.
    static let relativeDays: Set<String> = ["today", "tonight", "tomorrow"]

    /// "tomorrow 9" as "tomorrow at 9", and "9 tomorrow" as "at 9 tomorrow",
    /// for the detector.
    ///
    /// The detector reads "tomorrow at 9" as nine in the morning, and from
    /// "tomorrow 9" it matches only "tomorrow" and returns its fallback noon —
    /// confidently wrong, with no half or quarter in the phrase for the tripwire
    /// to notice. Measured on macOS 27: the same drop for "9 tomorrow", "today
    /// 6", "tonight 8" (19:00, the detector's "tonight") and "tomorrow evening
    /// 7" (18:00). With the "at", every one of them is read as the hour asked
    /// for, by the same reader and the same rule as the phrase with the "at"
    /// already in it, so "tomorrow 9" can never mean anything "tomorrow at 9"
    /// does not.
    ///
    /// Only that bare shape is touched: one of `relativeDays`, maybe the part
    /// of the day straight after it, and one whole hour on one side with no
    /// "at". "tomorrow 8 evening" is left alone, because the detector reads
    /// "tomorrow at 8 evening" as eight in the morning — and so is anything
    /// with a weekday, a second number or one more word in it.
    static func withAtBeforeLoneHour(_ phrase: String) -> String {
        let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        let bare = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
        guard let day = bare.firstIndex(where: relativeDays.contains) else { return phrase }
        var unit = [day]
        if day + 1 < bare.count, timesOfDay.contains(bare[day + 1]) { unit.append(day + 1) }
        let others = bare.indices.filter { !unit.contains($0) }
        guard others.count == 1, let hour = others.first else { return phrase }
        let digits = bare[hour]
        guard (1...2).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), (0...23).contains(value)
        else { return phrase }
        var rewritten = words
        rewritten.insert("at", at: hour)
        return rewritten.joined(separator: " ")
    }

    /// Calendar weekday numbers, Sunday first, for every name in `weekdayNames`.
    static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4, "weds": 4, "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6, "saturday": 7, "sat": 7
    ]

    /// Each weekday's full name, for the phrase the detector is asked.
    static let weekdayFullNames: [Int: String] = [
        1: "sunday", 2: "monday", 3: "tuesday", 4: "wednesday", 5: "thursday", 6: "friday", 7: "saturday"
    ]

    /// "Friday 5", "5 Friday", "on Friday at 5": the weekday, the hour, and the
    /// phrase to ask the detector, which is "friday at 5" for every one of them.
    ///
    /// The detector reads a number beside a weekday as the date of the month —
    /// "Friday 5" came back as Thursday 5 November at noon, and "wednesday 5",
    /// asked on a Wednesday in October, as 5 August, months gone; "5 Friday"
    /// kept the Friday and dropped the 5 for noon. Measured on macOS 27. It
    /// reads "friday at 5" right, as five in the afternoon, so every way of
    /// writing a weekday and an hour is asked as that one phrase: "Friday 5"
    /// can never mean anything "Friday at 5" does not.
    ///
    /// Only that shape: a weekday, maybe "on" or "this", maybe "at", and one
    /// whole hour. "Friday 5pm" and "Friday 5:30" the detector reads right as
    /// they are; "next Friday 5" is left alone, because people read "next"
    /// both ways.
    static func weekdayAndHour(_ phrase: String) -> (weekday: Int, hour: Int, phrase: String)? {
        let words = phrase.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
            .filter { !$0.isEmpty }
        var weekday: Int?
        var hour: Int?
        var ats = 0
        for word in words {
            if ["on", "this"].contains(word) { continue }
            if word == "at" {
                ats += 1
                continue
            }
            if weekday == nil, let number = weekdayNumbers[word] {
                weekday = number
                continue
            }
            guard hour == nil, (1...2).contains(word.count), word.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(word), (0...23).contains(value)
            else { return nil }
            hour = value
        }
        guard ats <= 1, let weekday, let hour, let name = weekdayFullNames[weekday] else { return nil }
        return (weekday, hour, "\(name) at \(hour)")
    }

    /// Whether the detector's answer is the hour that was asked, in either
    /// half of the day. A detector that dropped it answers noon, and noon is
    /// the time nobody asked for.
    static func isReading(_ read: Date, of hour: Int, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: read)
        guard let readHour = parts.hour, parts.minute == 0 else { return false }
        return hour > 12 ? readHour == hour : readHour % 12 == hour % 12
    }

    /// The next `weekday` at the time of day `read` says — today, while that
    /// time is still ahead, and otherwise the next one.
    ///
    /// Only the detector's hour and minute are kept. Its date is not: asked
    /// "wednesday at 5" late on a Wednesday it moves to next week, which is
    /// right, but the day is this file's to decide, so that no reading of a
    /// weekday can land on a date of the month, or in the past.
    static func nextWeekday(_ weekday: Int, atTimeOf read: Date, now: Date, calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.hour, .minute], from: read)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        let today = calendar.startOfDay(for: now)
        // A week and a day, so today's weekday is reached twice: today, and
        // next week once today's time has gone.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  calendar.component(.weekday, from: day) == weekday,
                  let time = wallClock(hour: hour, minute: minute, on: day, calendar: calendar),
                  time > now
            else { continue }
            return time
        }
        return nil
    }

    /// "at 5", "5", "5 o'clock": a whole hour, and nothing to say which half of
    /// the day — `bareClockTime`'s to read, never the detector's. The detector
    /// has no match for "at 5", and it reads "5 o'clock" as five in the
    /// morning, which the phrase never said.
    static func isLoneHour(_ phrase: String) -> Bool {
        let rest = phrase.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
            .filter { !$0.isEmpty && !["at", "o'clock", "oclock"].contains($0) }
        guard rest.count == 1, let only = rest.first, (1...2).contains(only.count),
              only.allSatisfy({ $0.isASCII && $0.isNumber }), let hour = Int(only)
        else { return false }
        return (0...23).contains(hour)
    }

    /// Whether the phrase is one clock time with nothing else in it — "6pm",
    /// "at 6 pm", "18:00" — and the time names its half of the day: an am or
    /// pm, or an hour past twelve.
    ///
    /// Anything more is the detector's to read. "tomorrow at 3pm" has a 3 and
    /// a day word `bareClockTime` does not understand, and would land at three
    /// o'clock TODAY; "09:00" is a reading `bareClockTime` makes differently
    /// from the detector — the next nine o'clock, which after nine in the
    /// morning is nine at night — so it keeps the reading it always had.
    static func isUnambiguousClockTime(_ phrase: String) -> Bool {
        let words = phrase.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
        var times = 0
        var namesHalf = false
        for word in words {
            switch word {
            case "at":
                continue
            case "am", "pm":
                namesHalf = true
                continue
            default:
                break
            }
            var digits = Substring(word)
            if digits.hasSuffix("am") || digits.hasSuffix("pm") {
                digits = digits.dropLast(2)
                namesHalf = true
            }
            let pieces = digits.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count),
                  pieces.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }),
                  let hour = Int(pieces[0]), (0...23).contains(hour)
            else { return false }
            if pieces.count == 2, let minute = Int(pieces[1]), !(0...59).contains(minute) { return false }
            if hour > 12 { namesHalf = true }
            times += 1
        }
        return times == 1 && namesHalf
    }

    /// An hour with no date around it — "at 9", "morning at 7", "17:30".
    ///
    /// Needed because `NSDataDetector` returns NO MATCH for a bare hour without
    /// am or pm: "at 7am" resolves and "at 9" does not. That gap is invisible
    /// until it lands on the commonest phrasing there is — "daily at 9" — and
    /// refuses it, which is how a repeating reminder feature ships looking
    /// broken.
    ///
    /// Where a whole hour has no am/pm and no part-of-day word, one to six is
    /// the afternoon: "at 5" is five today while that is still ahead, and five
    /// tomorrow once it has gone. The rule used to be the NEXT five o'clock,
    /// whichever half of the day it fell in, and asked at 7:33 PM that was five
    /// in the morning — "remind me to call the plumber at 5" was filed for
    /// 5:00 AM, which nobody means, and "Friday 5" and "tomorrow 5" already
    /// meant five in the afternoon. Seven to twelve, and a time with minutes,
    /// keep that next-one-round reading: "at 9" at 2 PM is nine tonight, "at
    /// 7" at 9 PM is seven tomorrow morning. Either way it is a choice rather
    /// than a reading, and the confirmation says which one it picked, so a
    /// user who meant the other one sees it in the same breath.
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
        // clock: a colon, an am/pm, the word "at" immediately before it, an
        // "o'clock" or a part of the day after it — or nothing beside it at
        // all. "9" on its own is what Apple's model passes for "remind me to
        // call mum at 9", and a phrase that is only an hour has nothing else
        // to be.
        var isClock = false
        var isWholeHour = false
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
                let next = index + 1 < words.count ? words[index + 1] : ""
                let followedByMeridiem = ["am", "pm"].contains(next)
                let followedByOClock = ["o'clock", "oclock"].contains(next)
                // "5 in the morning", "10 at night".
                let after = words.dropFirst(index + 1).prefix(3).map { $0 }
                let followedByPartOfDay = (after.count == 3 && after[0] == "in" && after[1] == "the" && timesOfDay.contains(after[2]))
                    || after.starts(with: ["at", "night"])
                guard precededByAt || followedByMeridiem || followedByOClock || followedByPartOfDay || words.count == 1 else { continue }
                hour = h
                isClock = true
                isWholeHour = true
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
        } else if isWholeHour, (1...6).contains(resolved) {
            // Neither said, and one to six: the afternoon.
            resolved += 12
        } else if resolved <= 12 {
            // Neither said. Take whichever of the two comes round first.
            let candidates = [resolved, resolved + 12].compactMap {
                wallClock(hour: $0, minute: minute, on: now, calendar: calendar)
            }
            if let next = candidates.filter({ $0 > now }).min() { return next }
            // Both gone today, so the earlier of the two tomorrow.
            return candidates.min().flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        }

        guard let candidate = wallClock(hour: resolved, minute: minute, on: now, calendar: calendar) else {
            return nil
        }
        guard candidate <= now else { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    /// `hour:minute` as the clock on the wall reads it on `day`, in the
    /// calendar's zone. Hour 24 is the midnight that ends the day.
    ///
    /// Set, never added to midnight: on the day the clocks go forward, the
    /// start of the day plus eighteen hours is seven in the evening, and on the
    /// day they go back it is five.
    static func wallClock(hour: Int, minute: Int, on day: Date, calendar: Calendar) -> Date? {
        guard hour == 24 else {
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            .flatMap { calendar.date(bySettingHour: 0, minute: minute, second: 0, of: $0) }
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
