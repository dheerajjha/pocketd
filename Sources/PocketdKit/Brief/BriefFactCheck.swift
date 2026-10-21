import Foundation

// MARK: - What a brief may say

/// Every clock time, length of time and number a brief about one reading of
/// the day may state, worked out from the same snapshot its prompt was built
/// from.
///
/// The template brief is assembled from the snapshot and cannot be wrong. A
/// brain's is written from the prompt, and QA caught it wrong in three ways,
/// each directly above a tile saying otherwise: "a design review at 10:00 AM"
/// in an afternoon sentence when the review was tomorrow; "1 hour and 25
/// minutes less than your usual" when the gap was 29 minutes; "1,980 fewer
/// steps" beside an Activity tile reading Ahead. So nothing numeric reaches
/// Today unless it is one of these facts, on the right day.
public struct BriefFacts: Sendable {

    /// A moment a brief may name: an event still to start, or a reminder with
    /// a time today.
    struct Moment: Sendable, Equatable {
        var date: Date
        var isTomorrow: Bool
    }

    let moments: [Moment]
    /// Lengths of time, in whole minutes: last night, the usual, the gap
    /// between them, and how long each event ahead runs.
    let minutes: [Int]
    /// Plain numbers: the counts the brief may give, the step figures, and any
    /// digits inside a title, which a brief may quote with the title.
    let numbers: Set<Int>
    /// Tomorrow's weekday, lower-cased: "On Thursday" is as good as
    /// "tomorrow".
    let tomorrowName: String
    let calendar: Calendar
    let locale: Locale

    public init(snapshot: TodaySnapshot, now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now
        tomorrowName = tomorrow.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
        ).lowercased()

        var moments: [Moment] = []
        var minutes: [Int] = []
        var numbers: Set<Int> = []

        func digits(in title: String) {
            for run in title.split(whereSeparator: { !$0.isNumber }) {
                if let value = Int(run) { numbers.insert(value) }
            }
        }

        if snapshot.calendar.isReadable {
            // The same events the prompt sends: what is still to start, today
            // and tomorrow. One under way or over is not a fact a brief may
            // give a time for — said with its time, it reads as still to come.
            var laterToday = 0
            var allDay = 0
            var nextDay = 0
            for event in snapshot.events where event.end > now && event.start < dayAfter {
                digits(in: event.title)
                if event.isAllDay {
                    if event.start < tomorrow { allDay += 1 } else { nextDay += 1 }
                    continue
                }
                if event.start >= tomorrow {
                    nextDay += 1
                    moments.append(Moment(date: event.start, isTomorrow: true))
                } else if event.start > now {
                    laterToday += 1
                    moments.append(Moment(date: event.start, isTomorrow: false))
                } else {
                    continue
                }
                minutes.append(Self.wholeMinutes(event.end.timeIntervalSince(event.start)))
            }
            numbers.formUnion([laterToday, allDay, nextDay, laterToday + allDay, laterToday + nextDay])
        }

        if snapshot.reminders.isReadable {
            let split = DueSplit.of(snapshot, now: now, calendar: calendar)
            numbers.formUnion([split.today.count, split.overdue.count, split.today.count + split.overdue.count])
            for reminder in split.today + split.overdue {
                digits(in: reminder.title)
                if reminder.dueHasTime, let due = reminder.due, calendar.isDate(due, inSameDayAs: now) {
                    moments.append(Moment(date: due, isTomorrow: false))
                }
            }
        }

        if snapshot.health.isReadable {
            if let slept = snapshot.sleepLastNight, slept > 0 {
                minutes.append(Self.wholeMinutes(slept))
                if let usual = snapshot.sleepUsual, usual > 0 {
                    minutes.append(Self.wholeMinutes(usual))
                    minutes.append(abs(Self.wholeMinutes(slept - usual)))
                }
            }
            for figure in [snapshot.stepsToday, snapshot.stepsUsual, snapshot.stepsUsualByNow].compactMap({ $0 }) {
                numbers.insert(Int(figure.rounded()))
            }
        }

        self.moments = moments
        self.minutes = minutes
        self.numbers = numbers
    }

    static func wholeMinutes(_ seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded())
    }

    /// The moment a stated time names, on the day the sentence puts it.
    ///
    /// - Parameter meridiem: "a" or "p" when the brief said AM or PM; nil
    ///   when it said neither, which leaves both halves of the day possible.
    func moment(hour: Int, minute: Int, meridiem: Character?, isTomorrow: Bool) -> Moment? {
        let hours: [Int]
        switch meridiem {
        case "a": hours = [hour == 12 ? 0 : hour]
        case "p": hours = [hour == 12 ? 12 : hour + 12]
        default: hours = hour == 0 || hour > 12 ? [hour] : [hour, hour == 12 ? 0 : hour + 12]
        }
        return moments.first { moment in
            let parts = calendar.dateComponents([.hour, .minute], from: moment.date)
            return moment.isTomorrow == isTomorrow
                && hours.contains(parts.hour ?? -1)
                && parts.minute == minute
        }
    }

    /// The fact a stated length of time is, within a minute of rounding.
    func duration(near stated: Int) -> Int? {
        minutes.first { abs($0 - stated) <= 1 }
    }
}

// MARK: - Checking a brief against them

extension BriefPrompt {

    /// The brain's brief as it may be shown on Today, or nil to keep the
    /// template.
    ///
    /// Everything `screened(_:)` does, and then the facts: every clock time
    /// must be an event or reminder's, on the day the sentence gives it — a
    /// tomorrow item must say tomorrow; every length of time must be one of
    /// the day's, within a minute; every other number must be a count the
    /// brief can make or a figure it was given. What passes is put into the
    /// app's own formats — "4:30 p.m." becomes "4:30 PM", "6 hours and 36
    /// minutes" becomes "6h 36m" — so the paragraph and the tiles under it read
    /// alike. One wrong figure and the whole brief goes: the template is
    /// always true, and a paragraph that is right but for one number is wrong.
    public static func screened(_ modelOutput: String, facts: BriefFacts) -> String? {
        guard let text = screened(modelOutput) else { return nil }
        return BriefFactCheck.checked(text, against: facts)
    }
}

enum BriefFactCheck {

    static func checked(_ text: String, against facts: BriefFacts) -> String? {
        var checked: [String] = []
        for sentence in BriefPrompt.sentences(in: normalisingMeridiems(text)) {
            guard let sentence = checkedSentence(sentence, facts) else { return nil }
            checked.append(sentence)
        }
        let result = checked.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals below; a typo is a crash in the tests,
        // not a silent pass in the app.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// "4:30 PM", "10 am", "16:30", "4:30 in the afternoon". A bare number is
    /// not a time: it needs minutes, AM or PM, or the part of the day.
    static let time = regex(
        #"(?<![\d:.,])(\d{1,2})(?::([0-5]\d))?(?:\s*([ap])m\b)?(?:\s+in\s+the\s+(morning|afternoon|evening))?"#
    )
    /// "6h 36m", "6 hours and 36 minutes", "7 h 5 m", "2 hours".
    static let hours = regex(
        #"(?<![\d:.,])(\d{1,2})\s*(?:h|hr|hrs|hour|hours)\b(?:\s*(?:and\s+)?(\d{1,2})\s*(?:m|min|mins|minute|minutes)\b)?"#
    )
    /// "29 min", "45 minutes", "36m".
    static let minutes = regex(#"(?<![\d:.,])(\d{1,3})\s*(?:m|min|mins|minute|minutes)\b"#)
    /// "4,120", "6100", "2" — and "4120," at the end of a clause, which a
    /// lookahead refusing any comma once let through unchecked.
    static let number = regex(#"(?<![\d.,])(?:\d{1,3}(?:,\d{3})+(?!\d)|\d+(?!\d))"#)
    /// Words that put what follows on a day.
    static let marker = regex(#"\b(tomorrow|today|tonight|this morning|this afternoon|this evening|later)\b"#)
    /// Where one clause of a sentence ends and the next begins.
    static let boundary = regex(#",|;|\band\b|\bthen\b|\bbut\b|\bwhile\b|\bfollowed by\b"#)
    /// An "a.m." or "p.m." left after normalising: a time in a shape this
    /// check does not read.
    static let strayMeridiem = regex(#"\b[ap]\.\s?m\b\.?"#)

    /// "4:30 p.m." → "4:30 PM" before anything else, sentence stops kept: the
    /// dots in "p.m." would otherwise split one sentence into two at "p.m.
    /// today", and lose the scope "today" gives the time before it.
    static func normalisingMeridiems(_ text: String) -> String {
        // Case-sensitive on purpose, unlike the rest: "[A-Z]" is how a stop
        // that also ended the sentence is told from "p.m. today".
        let dotted = try! NSRegularExpression(pattern: #"(\d)\s*([aApP])\.\s?[mM]\.(\s+[A-Z]|\s*$)?"#)
        let ns = NSMutableString(string: text)
        for match in dotted.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let source = text as NSString
            let digit = source.substring(with: match.range(at: 1))
            let half = source.substring(with: match.range(at: 2)).uppercased()
            // A stop that ended the sentence as well as the abbreviation is
            // kept, so the next sentence still starts as one.
            let endsSentence = match.range(at: 3).location != NSNotFound
            let tail = endsSentence ? "." + source.substring(with: match.range(at: 3)) : ""
            ns.replaceCharacters(in: match.range, with: "\(digit) \(half)M\(tail)")
        }
        return ns as String
    }

    // MARK: One sentence

    static func checkedSentence(_ sentence: String, _ facts: BriefFacts) -> String? {
        let source = sentence as NSString
        let all = NSRange(location: 0, length: source.length)
        let masked = NSMutableString(string: sentence)
        var replacements: [(range: NSRange, text: String)] = []

        func mask(_ range: NSRange) {
            masked.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }

        // The day each part of the sentence is about.
        var markers = marker.matches(in: sentence, range: all).map { match in
            (location: match.range.location, isTomorrow: source.substring(with: match.range).lowercased() == "tomorrow")
        }
        for match in regex(#"\b\#(NSRegularExpression.escapedPattern(for: facts.tomorrowName))\b"#)
            .matches(in: sentence, range: all) {
            markers.append((location: match.range.location, isTomorrow: true))
        }
        markers.sort { $0.location < $1.location }
        let cuts = [0] + boundary.matches(in: sentence, range: all).map(\.range.location) + [source.length]
        func clause(of location: Int) -> Int {
            (cuts.lastIndex { $0 <= location } ?? 0)
        }

        // Times first, so "6:30" is never read as a length or a count.
        let times = time.matches(in: sentence, range: all).filter { match in
            match.range(at: 2).location != NSNotFound
                || match.range(at: 3).location != NSNotFound
                || match.range(at: 4).location != NSNotFound
        }
        let clausesWithTimes = Set(times.map { clause(of: $0.range.location) })

        for match in times {
            let location = match.range.location
            let isTomorrow = day(of: location, markers: markers, clause: clause, clausesWithTimes: clausesWithTimes)
            guard let hour = Int(source.substring(with: match.range(at: 1))) else { return nil }
            let minute = match.range(at: 2).location == NSNotFound ? 0 : Int(source.substring(with: match.range(at: 2))) ?? -1
            var meridiem: Character?
            if match.range(at: 3).location != NSNotFound {
                meridiem = source.substring(with: match.range(at: 3)).lowercased().first
            } else if match.range(at: 4).location != NSNotFound {
                meridiem = source.substring(with: match.range(at: 4)).lowercased() == "morning" ? "a" : "p"
            }
            guard let moment = facts.moment(hour: hour, minute: minute, meridiem: meridiem, isTomorrow: isTomorrow) else {
                // Not an event's or a reminder's, or on the wrong day — the
                // design review at 10:00 AM in a sentence about this afternoon.
                return nil
            }
            replacements.append((match.range, Format.time(moment.date, calendar: facts.calendar, locale: facts.locale)))
            mask(match.range)
        }
        let rest = masked as String
        guard strayMeridiem.firstMatch(in: rest, range: all) == nil else { return nil }

        // Lengths of time, hours first so "6h 36m" is one length, not two.
        for pattern in [hours, minutes] {
            for match in pattern.matches(in: masked as String, range: all) {
                let text = masked as NSString
                let leading = Int(text.substring(with: match.range(at: 1))) ?? 0
                var stated = pattern === hours ? leading * 60 : leading
                if pattern === hours, match.range(at: 2).location != NSNotFound {
                    stated += Int(text.substring(with: match.range(at: 2))) ?? 0
                }
                guard let fact = facts.duration(near: stated) else { return nil }
                replacements.append((match.range, Format.minutesText(fact, padded: false)))
                mask(match.range)
            }
        }

        // Every other number: a count the brief can make, or a figure it was
        // given. "1,980 fewer steps" is neither.
        for match in number.matches(in: masked as String, range: all) {
            let digits = (masked as NSString).substring(with: match.range).replacingOccurrences(of: ",", with: "")
            guard let value = Int(digits), facts.numbers.contains(value) else { return nil }
            if value >= 1_000 {
                replacements.append((match.range, Format.count(value, locale: facts.locale)))
            }
        }

        let output = NSMutableString(string: sentence)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            output.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return output as String
    }

    /// Whether the time at `location` is about tomorrow.
    ///
    /// A day word in its own clause decides; failing that, the last one
    /// before it in the sentence ("Tomorrow, a design review at 10:00 AM and
    /// yoga at 6:30 PM" — both tomorrow); failing that, one after it, but only
    /// from a clause with no time of its own ("At 10:00 AM you have a design
    /// review tomorrow"). Otherwise today.
    static func day(
        of location: Int,
        markers: [(location: Int, isTomorrow: Bool)],
        clause: (Int) -> Int,
        clausesWithTimes: Set<Int>
    ) -> Bool {
        let own = clause(location)
        let inClause = markers.filter { clause($0.location) == own }
        if let nearest = inClause.min(by: { abs($0.location - location) < abs($1.location - location) }) {
            return nearest.isTomorrow
        }
        if let before = markers.last(where: { $0.location < location }) {
            return before.isTomorrow
        }
        if let after = markers.first(where: { $0.location > location && !clausesWithTimes.contains(clause($0.location)) }) {
            return after.isTomorrow
        }
        return false
    }
}
