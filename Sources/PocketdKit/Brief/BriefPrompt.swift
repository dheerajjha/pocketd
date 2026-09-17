import Foundation

/// Which greeting the day has earned.
///
/// Its own type rather than an hour comparison written at each call site,
/// because the two boundaries that matter are not the obvious ones. Noon and
/// six are a matter of taste; 03:00 is not, and an `hour < 12` test greets
/// somebody who is awake at three in the morning with "Good morning", which is
/// the single line most likely to make a person conclude the app has no idea
/// what time it is.
public enum TimeOfDayKind: String, Sendable, Codable, Equatable, CaseIterable {
    case morning, afternoon, evening

    /// Morning starts at 05:00, not at midnight. The small hours belong to the
    /// evening that has not finished yet — which is also the evening whose sleep
    /// the brief is about to report on.
    public static func from(now: Date, calendar: Calendar = .current) -> TimeOfDayKind {
        switch calendar.component(.hour, from: now) {
        case 5..<12: .morning
        case 12..<18: .afternoon
        default: .evening
        }
    }

    /// The opening words, without the name and without the punctuation, so the
    /// caller decides both.
    public var greeting: String {
        switch self {
        case .morning: "Good morning"
        case .afternoon: "Good afternoon"
        case .evening: "Good evening"
        }
    }
}

/// The prompt that turns a `TodaySnapshot` into a paragraph, and the paragraph
/// to use when there is nothing to turn it with.
///
/// Three things live here rather than in the app, and each for its own reason.
/// The **prompt** because it is the one piece of text whose exact bytes decide
/// whether a 1.7B model invents a meeting, and a string built inline in a
/// `body` is a string nobody can test. The **fallback** because a first-run user
/// with no model downloaded still has a day, and an empty card on the home tab
/// is the worst possible first impression for an app whose pitch is "reads your
/// day". The **cleaner** because small models emit markdown and reasoning tags
/// whatever they are told, and the repair has to happen somewhere both the
/// streaming view and the stored brief go through.
public enum BriefPrompt {

    /// Roughly how long the whole prompt may be.
    ///
    /// Nine hundred characters is about 220 tokens, which on the smallest model
    /// this app will load leaves the overwhelming majority of a 4k window for
    /// the answer and for the chat history the Ask tab may be holding at the
    /// same time. It is a budget rather than a hard limit because the renderer
    /// meets it by dropping rows, not by cutting text mid-word: a prompt that
    /// ends halfway through an event title is a prompt that invites the model to
    /// finish the title.
    public static let characterBudget = 900

    /// How much of one title survives into the prompt.
    ///
    /// Long enough for a real meeting name, short enough that a calendar
    /// subscription with a 300-character description in its title cannot push
    /// every other row out of the budget.
    static let titleLimit = 48

    // MARK: - The prompt

    /// The system and user turns, in that order.
    ///
    /// Deterministic by construction: every input is a parameter, nothing reads
    /// `Date()` or `.current`, and every list is sorted before it is rendered.
    /// That matters more than it looks — the Today tab regenerates this on every
    /// appear, and a prompt that differs by a row order is a prompt that
    /// produces a visibly different brief for an unchanged day.
    public static func messages(
        snapshot: TodaySnapshot,
        name: String?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeOfDay: TimeOfDayKind
    ) -> [ChatMessage] {
        let system = systemText(name: name, timeOfDay: timeOfDay)
        // Tried widest first. Each rung drops rows rather than characters, so
        // whatever survives is a whole, true row.
        let ladder = [(4, 3, 3), (3, 2, 2), (2, 2, 1), (1, 1, 1), (1, 0, 0)]
        var user = ""
        for (events, due, overdue) in ladder {
            user = userText(
                snapshot: snapshot, now: now, calendar: calendar, locale: locale,
                eventLimit: events, dueLimit: due, overdueLimit: overdue
            )
            if system.count + user.count <= characterBudget { break }
        }
        return [.system(system), .user(user)]
    }

    static func systemText(name: String?, timeOfDay: TimeOfDayKind) -> String {
        var lines = [
            "You write a two or three sentence brief for the owner of this phone.",
            "Warm and plain, and easy to read aloud. No lists, no markdown, no headings, no emoji.",
            // The three refusals in one line, because a model this size weights
            // the start and the end of a system turn far more than the middle,
            // and this is the instruction whose failure is a fabricated meeting.
            "Use only the facts below. Never invent an event, a reminder or a number, and say nothing about anything that is not listed.",
        ]
        if let name = displayName(name) {
            lines.append("Open by greeting them for the \(timeOfDay.rawValue), by name: \(name).")
        } else {
            lines.append("Open by greeting them for the \(timeOfDay.rawValue).")
        }
        // Last, so it is the sentence nearest the data. "As an AI language
        // model" in the middle of a two-sentence brief is the single most
        // obvious tell there is, and it costs nine words to forbid.
        lines.append("Never mention yourself, a model, or how this was written.")
        return lines.joined(separator: "\n")
    }

    /// The day, rendered so that the same day always renders the same way.
    ///
    /// Blocks are omitted entirely when their source is not connected, and say
    /// `none` when it is connected and empty. The distinction is the whole
    /// point: a missing block leaves the model nothing to talk about, which is
    /// what "do not mention data that is off" means in practice, while `none` is
    /// a fact it is allowed to report.
    static func userText(
        snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        eventLimit: Int,
        dueLimit: Int,
        overdueLimit: Int
    ) -> String {
        var blocks: [String] = [heading(now: now, calendar: calendar, locale: locale)]

        if snapshot.calendar.isReadable {
            let ordered = sortedEvents(snapshot.events).filter { $0.end > now || $0.isAllDay }
            blocks.append(block("EVENTS", rows: ordered, limit: eventLimit) {
                eventLine($0, now: now, calendar: calendar, locale: locale)
            })
        }
        if snapshot.reminders.isReadable {
            blocks.append(block("DUE", rows: sortedReminders(snapshot.dueToday), limit: dueLimit) {
                clipped($0.title)
            })
            blocks.append(block("OVERDUE", rows: sortedReminders(snapshot.overdue), limit: overdueLimit) {
                clipped($0.title)
            })
        }
        if snapshot.health.isReadable {
            blocks.append("SLEEP\n" + sleepLine(snapshot))
            blocks.append("STEPS\n" + stepsLine(snapshot, locale: locale))
        }
        // Resting heart rate is deliberately absent, and it is the one omission
        // here that is not about the budget. A small model handed a heart rate
        // writes a sentence about what it means, and "your resting heart rate is
        // up, you may be coming down with something" is medical advice this app
        // has no business giving. The number is in the snapshot because the
        // tiles may show it; a tile states a figure and stops.
        return blocks.joined(separator: "\n\n")
    }

    static func heading(now: Date, calendar: Calendar, locale: Locale) -> String {
        let day = now.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.wide).day().month(.wide)
        )
        return "\(day), \(clock(now, calendar: calendar, locale: locale))."
    }

    /// Twelve or twenty-four hour, whichever the locale asks for.
    ///
    /// `.hour().minute()` rather than a `dateFormat` string, because a hardcoded
    /// `HH:mm` prints 14:00 to somebody whose phone has said 2 PM for ten years,
    /// and the model then repeats it back in a brief meant to sound like a
    /// person talking.
    static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .hour().minute()
        )
    }

    static func block<Row>(_ label: String, rows: [Row], limit: Int, line: (Row) -> String) -> String {
        guard !rows.isEmpty else { return "\(label)\nnone" }
        var body = rows.prefix(max(0, limit)).map(line)
        let hidden = rows.count - body.count
        if hidden > 0 {
            // Counted rather than dropped in silence. A model shown four of
            // eleven events will happily describe the day as quiet.
            body.append("and \(hidden) more")
        }
        return ([label] + body).joined(separator: "\n")
    }

    static func eventLine(_ event: BriefEvent, now: Date, calendar: Calendar, locale: Locale) -> String {
        var parts: [String] = []
        if !calendar.isDate(event.start, inSameDayAs: now) {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
            if let tomorrow, calendar.isDate(event.start, inSameDayAs: tomorrow) {
                parts.append("tomorrow")
            } else {
                parts.append(event.start.formatted(
                    Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                        .weekday(.abbreviated)
                ))
            }
        }
        parts.append(event.isAllDay ? "all day" : clock(event.start, calendar: calendar, locale: locale))
        parts.append(clipped(event.title))
        // The location is left out, for the reason `WatcherEvaluation.line`
        // gives: it is the longest field on the row that a stranger fully
        // controls, nothing validates it, and it costs a third of the events
        // block to carry. A user who wants it opens the event.
        return parts.joined(separator: " ")
    }

    static func sleepLine(_ snapshot: TodaySnapshot) -> String {
        guard let slept = snapshot.sleepLastNight else { return "none" }
        // `HealthFormat.duration` and not the compact form the tiles use. This
        // string is read by a model, and everything else a model reads about
        // this person's body is written by that function; two spellings of the
        // same quantity in one context is how "6h 36m" comes back as "six
        // thirty-six".
        let text = HealthFormat.duration(slept)
        guard let usual = snapshot.sleepUsual else { return text }
        return "\(text) (usual \(HealthFormat.duration(usual)))"
    }

    static func stepsLine(_ snapshot: TodaySnapshot, locale: Locale) -> String {
        guard let steps = snapshot.stepsToday else { return "none" }
        let text = HealthFormat.value(steps, metric: .steps, locale: locale)
        guard let usual = snapshot.stepsUsual else { return text }
        return "\(text) (usual \(HealthFormat.value(usual, metric: .steps, locale: locale)))"
    }

    // MARK: - The brief nobody had to generate

    /// A brief assembled from the snapshot alone.
    ///
    /// Used when no model is loaded, while one is downloading, and any time
    /// generation fails — which on a first run is most of the first ten minutes.
    /// It is deliberately a *brief* and not an apology: the data is already
    /// there, and an app that can read the day but says "no model loaded" on the
    /// screen whose whole promise is reading the day has buried its own feature
    /// behind a technical noun the user was promised they would never see.
    ///
    /// Never returns an empty string. With nothing connected it says what
    /// connecting would give, which is the only useful sentence left.
    public static func fallback(
        snapshot: TodaySnapshot,
        name: String?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let kind = TimeOfDayKind.from(now: now, calendar: calendar)
        let greeting = displayName(name).map { "\(kind.greeting), \($0)." } ?? "\(kind.greeting)."

        var clauses: [String] = []
        if let clause = eventClause(snapshot, now: now, calendar: calendar, locale: locale) {
            clauses.append(clause)
        }
        if let clause = reminderClause(snapshot) {
            clauses.append(clause)
        }
        if let clause = bodyClause(snapshot, locale: locale) {
            clauses.append(clause)
        }

        guard !clauses.isEmpty else {
            return "\(greeting) \(connectSentence(snapshot))"
        }
        return "\(greeting) \(sentence(from: clauses))"
    }

    static func eventClause(_ snapshot: TodaySnapshot, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard snapshot.calendar.isReadable else { return nil }
        guard let next = snapshot.nextEvent(now: now) else {
            return "nothing more is on your calendar today"
        }
        let time = clock(next.start, calendar: calendar, locale: locale)
        guard calendar.isDate(next.start, inSameDayAs: now) else {
            return "today is clear from here, and \(clipped(next.title)) at \(time) opens tomorrow"
        }
        return "\(clipped(next.title)) at \(time) is next"
    }

    static func reminderClause(_ snapshot: TodaySnapshot) -> String? {
        guard snapshot.reminders.isReadable else { return nil }
        let due = snapshot.dueToday.count
        let overdue = snapshot.overdue.count
        switch (due, overdue) {
        case (0, 0):
            return "nothing is due today"
        case (_, 0):
            return "\(spelled(due)) \(noun("reminder", due)) \(verb(due)) due today"
        case (0, _):
            return "\(spelled(overdue)) \(noun("reminder", overdue)) \(verb(overdue)) overdue"
        default:
            return "\(spelled(due)) \(noun("reminder", due)) \(verb(due)) due today and \(spelled(overdue)) \(overdue == 1 ? "is" : "are") overdue"
        }
    }

    /// Sleep if there is any, steps otherwise.
    ///
    /// One clause and not two, because the sentence is already carrying a
    /// calendar and a list and a third comma turns a greeting into a report.
    /// Sleep wins because it is finished: a step count read at nine in the
    /// morning is a fraction of a day being compared with a whole one.
    static func bodyClause(_ snapshot: TodaySnapshot, locale: Locale) -> String? {
        guard snapshot.health.isReadable else { return nil }
        if let slept = snapshot.sleepLastNight {
            let text = "you slept \(BriefFormat.duration(slept))"
            guard let usual = snapshot.sleepUsual else { return text }
            switch Comparison.compare(slept, usual: usual) {
            case .below: return text + ", a little under your usual"
            case .above: return text + ", a little over your usual"
            case .usual: return text + ", about your usual"
            }
        }
        if let steps = snapshot.stepsToday {
            return "you have walked \(BriefFormat.count(steps, locale: locale)) steps"
        }
        return nil
    }

    static func connectSentence(_ snapshot: TodaySnapshot) -> String {
        var missing: [String] = []
        if !snapshot.calendar.isReadable { missing.append("your calendar") }
        if !snapshot.reminders.isReadable { missing.append("your reminders") }
        if !snapshot.health.isReadable { missing.append("Health") }
        guard !missing.isEmpty else { return "There is nothing to report yet." }
        return "Connect \(DeletionNarrative.joined(missing)) and this becomes a few lines about your own day — what is next, what is due, and how you slept."
    }

    /// "A, b, and c." — with the serial comma, because the last clause of these
    /// sentences routinely contains a comma of its own ("you slept 6h 36m, a
    /// little under your usual") and without it the list and the aside run
    /// together.
    static func sentence(from clauses: [String]) -> String {
        let joined: String
        switch clauses.count {
        case 1: joined = clauses[0]
        case 2: joined = "\(clauses[0]) and \(clauses[1])"
        default: joined = clauses.dropLast().joined(separator: ", ") + ", and " + (clauses.last ?? "")
        }
        return capitalisingFirst(joined) + "."
    }

    // MARK: - Cleaning up after the model

    /// Strips everything a small model adds that a two-sentence brief cannot use.
    ///
    /// Every rule here is something observed rather than imagined: reasoning
    /// models emit `<think>` whatever the sampler is told, instruction-tuned
    /// models bullet anything that smells like a list, and a model asked for a
    /// brief will hand one back inside quotation marks roughly a third of the
    /// time, as though reading it out.
    ///
    /// The order is load-bearing. Reasoning blocks go first, because their
    /// contents are full of the markdown the later rules would otherwise strip
    /// into the visible text. Quotes go last, because they can only be
    /// recognised once the whitespace around them is gone.
    public static func clean(_ modelOutput: String) -> String {
        var text = strippingReasoning(modelOutput)
        text = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(strippingLeader)
            .joined(separator: "\n")
        text = String(text.unicodeScalars.filter { !emphasis.contains($0) })
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return strippingQuotes(text)
    }

    /// `*`, `_` and the backtick. Removed unconditionally, which is safe here
    /// and would not be elsewhere: this text is two or three sentences of prose
    /// about a diary, produced by a generation that was given no tools, so there
    /// is no snake_case identifier and no code span for them to be part of.
    private static let emphasis: Set<Unicode.Scalar> = ["*", "_", "`"]

    static func strippingReasoning(_ text: String) -> String {
        var result = text
        let open = "<think>"
        let close = "</think>"
        while let start = result.range(of: open) {
            if let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                // An unclosed tag means the stream was cut off mid-thought, and
                // everything after it is reasoning. Keeping it would print the
                // model's working out on the home tab.
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        // A close with no open: some templates prefill the opening tag, so the
        // model's first emitted token is the *closing* one and everything
        // before it is the thought.
        if let end = result.range(of: close) {
            result.removeSubrange(result.startIndex..<end.upperBound)
        }
        return result
    }

    /// Bullets, numbers and heading marks at the start of a line.
    static func strippingLeader(_ line: Substring) -> String {
        var rest = line.drop { $0 == " " || $0 == "\t" }
        while let first = rest.first, first == "#" || first == ">" {
            rest = rest.dropFirst()
        }
        if let first = rest.first, first == "-" || first == "*" || first == "\u{2022}" {
            rest = rest.dropFirst()
        } else {
            // "1." and "1)" — digits only, so a sentence starting with a year
            // is not mistaken for a numbered list item.
            let digits = rest.prefix { $0.isNumber }
            if !digits.isEmpty, let marker = rest.dropFirst(digits.count).first, marker == "." || marker == ")" {
                rest = rest.dropFirst(digits.count + 1)
            }
        }
        return String(rest)
    }

    static func strippingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}")]
        for (open, close) in pairs where text.count > 1 && text.first == open && text.last == close {
            return String(text.dropFirst().dropLast())
        }
        // An opening mark with nothing to close it, which is the commonest
        // shape of this failure rather than a rare one: a model that decides to
        // read the brief out loud opens with a quote, and the generation then
        // stops at its token limit before the closing one. Taking only the
        // matched pair left a stray \" on the front of the home tab.
        //
        // Only the first character is considered, and only when the rest of the
        // text has no partner for it \u2014 "He said \"yes\" at nine" keeps both of
        // its marks, and so does a brief that genuinely quotes something.
        guard let first = text.first else { return text }
        for (open, close) in pairs where first == open {
            let rest = text.dropFirst()
            guard !rest.contains(close), !rest.contains(open) else { break }
            return String(rest)
        }
        // And the mirror of it: a closing mark whose opener was eaten by the
        // reasoning stripper. Doubles only \u2014 a trailing ' or \u2019 is far more
        // likely to be the apostrophe in "the boys'" than half a quotation.
        guard let last = text.last, last == "\"" || last == "\u{201D}" else { return text }
        let head = text.dropLast()
        let opener: Character = last == "\"" ? "\"" : "\u{201C}"
        guard !head.contains(opener), !head.contains(last) else { return text }
        return String(head)
    }

    // MARK: - Small words

    static func sortedEvents(_ events: [BriefEvent]) -> [BriefEvent] {
        events.sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
    }

    /// Dated first, then by title. Undated reminders sort last for the reason
    /// `WatcherEvaluation` gives: most lists are mostly undated, and floating
    /// them up buries the three things that actually have a deadline.
    static func sortedReminders(_ reminders: [BriefReminder]) -> [BriefReminder] {
        reminders.sorted { left, right in
            let leftDue = left.due ?? .distantFuture
            let rightDue = right.due ?? .distantFuture
            return leftDue == rightDue ? left.title < right.title : leftDue < rightDue
        }
    }

    /// Cut at a word boundary where there is one within reach, because a title
    /// ending "Quarterly planning wor" reads as a bug and a model will finish
    /// the word for you.
    static func clipped(_ title: String, limit: Int = titleLimit) -> String {
        let flat = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let head = flat.prefix(limit)
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[head.startIndex..<space]) + "…"
        }
        return String(head) + "…"
    }

    static func trimmed(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// A name short enough to sit inside a greeting.
    ///
    /// Clipped for a reason that is not cosmetic: the name is the one part of
    /// the system message the user types, so without a bound it is also the one
    /// part that can push the entire day out of `characterBudget`. Thirty-two
    /// characters is longer than any name anybody greets somebody by.
    static func displayName(_ name: String?) -> String? {
        trimmed(name).map { clipped($0, limit: 32) }
    }

    /// Spelled out up to ten. "2 reminders are due" in a sentence somebody is
    /// going to hear read aloud is a line of a report, not a greeting.
    static func spelled(_ count: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return (0..<words.count).contains(count) ? words[count] : "\(count)"
    }

    static func noun(_ word: String, _ count: Int) -> String { count == 1 ? word : word + "s" }
    static func verb(_ count: Int) -> String { count == 1 ? "is" : "are" }

    static func capitalisingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
