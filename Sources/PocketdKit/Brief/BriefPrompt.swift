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

    /// The hours at which the greeting changes: 05:00, 12:00 and 18:00.
    static let boundaries = [5, 12, 18]

    /// The next moment after `now` at which the greeting changes — when a
    /// brief that opened "Good morning" stops being the right brief.
    public static func nextChange(after now: Date, calendar: Calendar = .current) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            for hour in boundaries {
                if let moment = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), moment > now {
                    return moment
                }
            }
        }
        return nil
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
            // "Easy to read aloud" used to sit here, and a small model took it
            // literally: the home tab read "at eleven fifty seven AM". Digits
            // are what the screen shows; the speech engine says them fine.
            "Warm and plain. No lists, no markdown, no headings, no emoji. Write times and numbers in digits.",
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
        // No heading with the date or the time. A brain repeats whatever it is
        // handed as a fact worth a sentence — "It is 9:41 AM", "Today is
        // Wednesday, 21 October" — and the brief has three sentences to spend,
        // on a screen whose header already says what day it is. The blocks
        // carry everything about time a brief needs: what is under way, what
        // is still to come, what is tomorrow.
        var blocks: [String] = []

        if snapshot.calendar.isReadable {
            blocks.append(contentsOf: eventBlocks(
                snapshot, now: now, calendar: calendar, locale: locale, limit: eventLimit
            ))
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

    /// Twelve or twenty-four hour, whichever the locale asks for.
    ///
    /// `.hour().minute()` rather than a `dateFormat` string, because a hardcoded
    /// `HH:mm` prints 14:00 to somebody whose phone has said 2 PM for ten years,
    /// and the model then repeats it back in a brief meant to sound like a
    /// person talking.
    static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        Format.time(date, calendar: calendar, locale: locale)
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

    /// The calendar as up to three blocks: ALL DAY TODAY, LATER TODAY,
    /// TOMORROW — what is still ahead, and nothing else.
    ///
    /// One list of start times was the bug: "1:00 PM Lunch at The Arches"
    /// handed over at a quarter to two still reads as a lunch to come, and
    /// Apple's brain wrote it up that way on Today. So an event that has begun
    /// is not sent at all, and neither is one that has finished. Sending the
    /// one under way, labelled, was tried and measured: given "Standup, on now
    /// until 9:45 AM" or "Standup, already started, ends 9:45 AM", the brain
    /// still wrote "your standup is at 9:45 AM" in half its briefs. The
    /// template, which is not guessing, says what is under way itself
    /// (`calendarSentence`).
    ///
    /// LATER TODAY is always present, as `none` when nothing is left, because a
    /// missing block leaves a model to guess and a guess is a meeting. The
    /// other two appear only when they have something in them; an all-day
    /// event is "all day", which no reader takes for something about to start.
    ///
    /// `limit` is the whole calendar's share of the budget, spent in page
    /// order. Rows a block could not fit are counted in that block, so a model
    /// shown one of three things tomorrow does not call tomorrow quiet.
    static func eventBlocks(
        _ snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        limit: Int
    ) -> [String] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let dayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday)
        else { return ["LATER TODAY\nnone"] }

        var allDay: [BriefEvent] = []
        var later: [BriefEvent] = []
        var next: [BriefEvent] = []
        for event in sortedEvents(snapshot.events) where event.end > now && event.start < dayAfter {
            if event.start >= tomorrow {
                next.append(event)
            } else if event.isAllDay {
                allDay.append(event)
            } else if event.start > now {
                later.append(event)
            }
            // Begun and not finished: not sent. See above.
        }

        var budget = max(0, limit)
        func rows(_ events: [BriefEvent], _ line: (BriefEvent) -> String) -> [String] {
            let shown = Array(events.prefix(budget))
            budget -= shown.count
            var rows = shown.map(line)
            let hidden = events.count - shown.count
            if hidden > 0 {
                rows.append(shown.isEmpty ? Format.counted(hidden, "event", locale: locale) : "and \(hidden) more")
            }
            return rows
        }
        func time(_ date: Date) -> String { clock(date, calendar: calendar, locale: locale) }

        var blocks: [String] = []
        if !allDay.isEmpty {
            blocks.append((["ALL DAY TODAY"] + rows(allDay) { clipped($0.title) }).joined(separator: "\n"))
        }
        let laterLines = rows(later) { "\(time($0.start)) \(clipped($0.title))" }
        blocks.append((["LATER TODAY"] + (laterLines.isEmpty ? ["none"] : laterLines)).joined(separator: "\n"))
        if !next.isEmpty {
            // "tomorrow" on every row as well as over the block: given only
            // the label, the brain wrote "a design review at 10:00 AM" into a
            // sentence about this afternoon.
            let lines = rows(next) { event in
                event.isAllDay
                    ? "tomorrow, all day: \(clipped(event.title))"
                    : "tomorrow \(time(event.start)) \(clipped(event.title))"
            }
            blocks.append((["TOMORROW"] + lines).joined(separator: "\n"))
        }
        // The location is left out, for the reason `WatcherEvaluation.line`
        // gives: it is the longest field on the row that a stranger fully
        // controls, nothing validates it, and it costs a third of the events
        // block to carry. A user who wants it opens the event.
        return blocks
    }

    static func sleepLine(_ snapshot: TodaySnapshot) -> String {
        guard let slept = snapshot.sleepLastNight else { return "none" }
        // `HealthFormat.duration` and not the compact form the tiles use. This
        // string is read by a model, and everything else a model reads about
        // this person's body is written by that function; two spellings of the
        // same quantity in one context is how "6h 36m" comes back as "six
        // thirty-six".
        let text = HealthFormat.duration(slept)
        guard let usual = snapshot.sleepUsual, usual > 0 else { return text }
        // The gap is worked out here rather than left to the brain, which
        // made 6 h 36 m against 7 h 5 m "1 hour and 25 minutes less".
        let gap = slept - usual
        let comparison = abs(gap) < 5 * 60
            ? "about usual"
            : "\(HealthFormat.duration(abs(gap))) \(gap < 0 ? "under" : "over") usual"
        return "\(text) (usual \(HealthFormat.duration(usual)); \(comparison))"
    }

    /// Steps against where a usual day has got to *by now*, when that is
    /// known — the Activity tile's comparison. Handed only the whole day's
    /// usual at half past nine, the brain wrote "1,980 fewer steps than your
    /// usual" beside a tile reading Ahead.
    static func stepsLine(_ snapshot: TodaySnapshot, locale: Locale) -> String {
        guard let steps = snapshot.stepsToday else { return "none" }
        let text = HealthFormat.value(steps, metric: .steps, locale: locale)
        if let byNow = snapshot.stepsUsualByNow, byNow > 0 {
            return "\(text) (usual by this time of day \(HealthFormat.value(byNow, metric: .steps, locale: locale)))"
        }
        guard let usual = snapshot.stepsUsual else { return text }
        return "\(text) (usual for a whole day \(HealthFormat.value(usual, metric: .steps, locale: locale)))"
    }

    // MARK: - The brief nobody had to generate

    /// The most sentences a brief on the home tab may have, greeting included.
    ///
    /// Three: a greeting, the calendar, and everything else. A fourth pushes the
    /// tiles under the fold on a small phone, and the tiles are where the
    /// numbers are.
    public static let maximumSentences = 3

    /// A brief assembled from the snapshot alone.
    ///
    /// Used when no model is loaded, while one is downloading, whenever a model
    /// cannot read the day, and any time generation fails — which on a first
    /// run is most of the first ten minutes. It is deliberately a *brief* and
    /// not an apology: the data is already there, and an app that can read the
    /// day but says "no model loaded" on the screen whose whole promise is
    /// reading the day has buried its own feature behind a technical noun.
    ///
    /// At most three sentences — the greeting, the calendar, then reminders and
    /// sleep — in digits and the app's one set of formats ("1:00 PM", "6h 36m",
    /// "4,120"). Never spelled out: the screen shows digits, and the speech
    /// engine reads "1 reminder" as words without being asked.
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
        let facts = factSentences(snapshot: snapshot, now: now, calendar: calendar, locale: locale)
        return ([greeting] + facts).joined(separator: " ")
    }

    /// The first sentence after the greeting: what a notification that says
    /// "Your morning brief is ready." can carry underneath.
    ///
    /// The greeting is skipped because a notification already greets nobody in
    /// particular, and "Good morning, Sam." under "Your morning brief is ready."
    /// is two lines saying nothing. With nothing connected it is the connect
    /// sentence, which is at least true.
    public static func firstSentence(
        snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        factSentences(snapshot: snapshot, now: now, calendar: calendar, locale: locale).first
            ?? connectSentence(snapshot)
    }

    /// One sentence for a lock-screen banner under "Your morning brief is
    /// ready.", with no titles in it.
    ///
    /// Counts and times only: "Your next event is at 1:00 PM, you have 1
    /// reminder due today and 1 overdue, and you slept 6h 36m." A banner is
    /// read by whoever picks the phone up, and an event title is written by
    /// whoever sent the invite — neither belongs on a lock screen, which is the
    /// rule `NotificationCentre` already keeps. Built from the same clauses and
    /// the same `DueSplit` as the brief, so the banner and the brief it
    /// announces cannot count differently.
    ///
    /// Nil when nothing is connected: a banner saying "Connect your calendar"
    /// at 7:30 is an advert, not a brief.
    public static func notificationSentence(
        snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        var clauses: [String] = []
        if snapshot.calendar.isReadable {
            if let next = snapshot.nextEvent(now: now), calendar.isDate(next.start, inSameDayAs: now) {
                clauses.append("your next event is at \(clock(next.start, calendar: calendar, locale: locale))")
            } else if TodayVerdicts.hasNothingToday(snapshot, now: now, calendar: calendar) {
                clauses.append("nothing is on your calendar today")
            } else {
                clauses.append("nothing else is on your calendar today")
            }
        }
        if let reminders = reminderClause(snapshot, now: now, calendar: calendar, locale: locale) {
            clauses.append(reminders)
        }
        if snapshot.health.isReadable, let slept = snapshot.sleepLastNight, slept > 0 {
            clauses.append("you slept \(Format.duration(slept))")
        }
        guard !clauses.isEmpty else { return nil }
        return sentence(from: clauses)
    }

    /// The first sentence of any brief that is not its greeting — a template
    /// one or a model's. Nil when the brief is only a greeting.
    public static func firstFactSentence(of text: String) -> String? {
        let all = sentences(in: text)
        guard let first = all.first else { return nil }
        let rest = isGreeting(first) ? Array(all.dropFirst()) : all
        return rest.first
    }

    /// The calendar sentence, then one sentence for reminders and the body.
    static func factSentences(snapshot: TodaySnapshot, now: Date, calendar: Calendar, locale: Locale) -> [String] {
        var sentences: [String] = []
        if let day = calendarSentence(snapshot, now: now, calendar: calendar, locale: locale) {
            sentences.append(day)
        }
        var clauses: [String] = []
        if let clause = reminderClause(snapshot, now: now, calendar: calendar, locale: locale) {
            clauses.append(clause)
        }
        if let clause = bodyClause(snapshot, locale: locale) {
            clauses.append(clause)
        }
        if !clauses.isEmpty {
            sentences.append(sentence(from: clauses))
        }
        if sentences.isEmpty {
            sentences.append(connectSentence(snapshot))
        }
        return sentences
    }

    /// `Lunch at The Arches at 1:00 PM is next.`
    ///
    /// "Nothing on your calendar today." only when the reader started at
    /// midnight and found nothing at all; a reader that started at `now` cannot
    /// see the morning, so it says "nothing else" — the walkthrough caught the
    /// opposite mistake, "nothing more" on a day that never had anything.
    ///
    /// Something already under way is said to be under way, with the time it
    /// ends — "Lunch at The Arches runs until 2:00 PM, then Dentist at 4:30
    /// PM." — and never as what is next: the same split the prompt hands a
    /// brain (`eventBlocks`), so the template and a brain's brief cannot
    /// disagree about whether lunch has started.
    static func calendarSentence(_ snapshot: TodaySnapshot, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard snapshot.calendar.isReadable else { return nil }
        let empty = TodayVerdicts.hasNothingToday(snapshot, now: now, calendar: calendar)
        let running = snapshot.currentEvent(now: now).map {
            "\(clipped($0.title)) runs until \(clock($0.end, calendar: calendar, locale: locale))"
        }
        guard let next = snapshot.nextEvent(now: now) else {
            if let running { return "\(running), and nothing else is on today." }
            return empty ? "Nothing on your calendar today." : "Nothing else is on your calendar today."
        }
        let time = clock(next.start, calendar: calendar, locale: locale)
        if calendar.isDate(next.start, inSameDayAs: now) {
            if let running { return "\(running), then \(clipped(next.title)) at \(time)." }
            return "\(clipped(next.title)) at \(time) is next."
        }
        let isTomorrow = calendar.date(byAdding: .day, value: 1, to: now)
            .map { calendar.isDate(next.start, inSameDayAs: $0) } ?? false
        // One sentence either way: the brief has room for three, and the
        // greeting and the reminders have the other two.
        if let running {
            guard isTomorrow else { return "\(running), and nothing else is on today." }
            return "\(running), then nothing until \(clipped(next.title)) tomorrow at \(time)."
        }
        let opening = empty ? "Nothing on your calendar today" : "Nothing else is on today"
        guard isTomorrow else { return opening + "." }
        return "\(opening), and tomorrow starts with \(clipped(next.title)) at \(time)."
    }

    /// Counted by `DueSplit`, the rule the Due tile uses, so the paragraph and
    /// the tile under it give the same numbers.
    static func reminderClause(_ snapshot: TodaySnapshot, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard snapshot.reminders.isReadable else { return nil }
        let split = DueSplit.of(snapshot, now: now, calendar: calendar)
        let due = split.today.count
        let overdue = split.overdue.count
        switch (due, overdue) {
        case (0, 0):
            return "nothing is due today"
        case (_, 0):
            return "you have \(Format.counted(due, "reminder", locale: locale)) due today"
        case (0, _):
            return "you have \(Format.counted(overdue, "overdue reminder", locale: locale))"
        default:
            return "you have \(Format.counted(due, "reminder", locale: locale)) due today and \(Format.count(overdue, locale: locale)) overdue"
        }
    }

    /// Sleep if there is any, steps otherwise.
    ///
    /// One clause and not two, because the sentence is already carrying the
    /// reminders and a third comma turns a greeting into a report. Sleep wins
    /// because it is finished: a step count read at nine in the morning is a
    /// fraction of a day. The comparison is the Sleep tile's own phrase, so
    /// the paragraph and the tile quote the same minutes.
    static func bodyClause(_ snapshot: TodaySnapshot, locale: Locale) -> String? {
        guard snapshot.health.isReadable else { return nil }
        if let slept = snapshot.sleepLastNight, slept > 0 {
            let text = "you slept \(Format.duration(slept))"
            guard let usual = snapshot.sleepUsual, usual > 0 else { return text }
            return "\(text), \(TodayVerdicts.deltaPhrase(slept - usual)) your usual"
        }
        if let steps = snapshot.stepsToday {
            return "you've walked \(Format.counted(Int(steps.rounded()), "step", locale: locale))"
        }
        return nil
    }

    static func connectSentence(_ snapshot: TodaySnapshot) -> String {
        var missing: [String] = []
        if !snapshot.calendar.isReadable { missing.append("your calendar") }
        if !snapshot.reminders.isReadable { missing.append(missing.isEmpty ? "your reminders" : "reminders") }
        if !snapshot.health.isReadable { missing.append("Health") }
        guard !missing.isEmpty else { return "There's nothing to report yet." }
        return "Connect \(listed(missing)) to see your day here."
    }

    /// `a`, `a and b`, `a, b and c`.
    static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    /// Two clauses joined with a comma before the "and", because the second
    /// routinely carries a comma of its own ("you slept 6h 36m, about your
    /// usual") and without it the list and the aside run together.
    static func sentence(from clauses: [String]) -> String {
        let joined: String
        switch clauses.count {
        case 1: joined = clauses[0]
        case 2: joined = "\(clauses[0]), and \(clauses[1])"
        default: joined = clauses.dropLast().joined(separator: ", ") + ", and " + (clauses.last ?? "")
        }
        return capitalisingFirst(joined) + "."
    }

    // MARK: - When a brief stops being true

    /// Whether a brief written at `written` has stopped describing the day by
    /// `now`.
    ///
    /// A brief is a paragraph about a moment. "Lunch at The Arches at 1:00 PM
    /// is next" is true at noon and false at a quarter to two, and a brain's
    /// brief used to be kept for the rest of the day once written — so Today
    /// went on announcing a lunch that was already being eaten. Any brief, the
    /// template's or a brain's, is out of date once something it could have
    /// described has moved on since it was written: an event started or
    /// finished, a timed reminder fell due, or the part of the day its
    /// greeting names is over.
    ///
    /// - Parameter snapshot: the latest reading of the day, so an event added
    ///   since the brief was written counts too.
    public static func isOutdated(
        writtenAt written: Date,
        snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        snapshot.hasTurned(between: written, and: now)
            || TimeOfDayKind.from(now: written, calendar: calendar) != TimeOfDayKind.from(now: now, calendar: calendar)
    }

    /// When a brief written at `now` will next be out of date: the day's next
    /// turning point, or the next change of greeting, whichever comes first.
    /// What lets a screen that stays open rewrite its brief at the minute a
    /// meeting starts instead of at the next time somebody pulls to refresh.
    public static func nextRewrite(
        after now: Date,
        snapshot: TodaySnapshot,
        calendar: Calendar = .current
    ) -> Date? {
        [snapshot.nextTurningPoint(after: now), TimeOfDayKind.nextChange(after: now, calendar: calendar)]
            .compactMap { $0 }
            .min()
    }

    // MARK: - What a model may put on the home tab

    /// The model's brief as it may be shown, or nil when the template should
    /// stay.
    ///
    /// Everything `clean` does, then the three things the walkthrough found on
    /// the home tab:
    ///
    /// - **Instruction echo.** A 360M model handed this system turn printed it
    ///   back as the brief — "Warm and plain, and easy to read aloud. No lists…"
    ///   — and it was cached and shown for a day. Any sentence sharing a run of
    ///   four words with the instructions is dropped; a brief that is mostly
    ///   echo, or that dumps the data blocks back, is refused.
    /// - **A time in words.** "…at eleven fifty seven AM." The screen shows
    ///   digits, always; a brief that spells a time, a length of time or a date
    ///   out is refused. A plain count ("two reminders") is put into digits
    ///   instead, because that is a fix rather than a failure.
    /// - **Length.** At most `maximumSentences`, cut at whole sentences.
    ///
    /// Refused means the template stays on screen — two true sentences, which
    /// is a better outcome than any of the above.
    public static func screened(_ modelOutput: String) -> String? {
        // "p.m." first: its dots are sentence stops to everything below, and
        // "4:30 p.m. today" counted as two sentences pushed the third off
        // the end of the brief.
        let text = BriefFactCheck.normalisingMeridiems(clean(modelOutput))
        guard !echoesDataBlocks(text) else { return nil }
        let all = sentences(in: text)
        guard !all.isEmpty else { return nil }
        let kept = all.filter { !isInstructionEcho($0) }
        // Mostly echo: what is left is the residue of a failed generation,
        // not a brief.
        guard kept.count * 2 > all.count else { return nil }
        guard !kept.contains(where: spellsOutTime) else { return nil }
        let result = kept.prefix(maximumSentences).map(digitisingCounts).joined(separator: " ")
        guard result.count >= 20 else { return nil }
        return result
    }

    /// Sentences, split where a stop is followed by a space or the end — so
    /// "4.2 km" and "1:00 PM" survive whole.
    static func sentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        var current = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            current.append(character)
            let next = trimmed.index(after: index)
            if ".!?".contains(character), next == trimmed.endIndex || trimmed[next] == " " {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
            index = next
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    static func isGreeting(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return ["good morning", "good afternoon", "good evening", "hello", "hi ", "hi,", "morning,", "evening,"]
            .contains { lower.hasPrefix($0) }
    }

    /// Lower-cased words, letters and digits only.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    static func shingles(_ words: [String], size: Int) -> Set<String> {
        guard words.count >= size else { return [] }
        return Set((0...(words.count - size)).map { words[$0..<($0 + size)].joined(separator: " ") })
    }

    /// Every run of four words in every variant of the system turn.
    static let instructionShingles: Set<String> = {
        var text = TimeOfDayKind.allCases.map { systemText(name: nil, timeOfDay: $0) }
        text.append(systemText(name: "Name", timeOfDay: .morning))
        return shingles(words(text.joined(separator: "\n")), size: 4)
    }()

    static func isInstructionEcho(_ sentence: String) -> Bool {
        !shingles(words(sentence), size: 4).isDisjoint(with: instructionShingles)
    }

    /// The prompt's block labels, in the capitals the prompt writes them in.
    /// No brief has a reason to shout "OVERDUE"; a model reciting its input
    /// does.
    static func echoesDataBlocks(_ text: String) -> Bool {
        let labels: Set<String> = ["EVENTS", "LATER", "TOMORROW", "DUE", "OVERDUE", "SLEEP", "STEPS"]
        return text.split { !$0.isLetter }.contains { labels.contains(String($0)) }
    }

    static let hourWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
    static let numberWords: Set<String> = Set(hourWords + [
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty",
    ])
    static let minuteWords: Set<String> = ["oh", "ten", "fifteen", "twenty", "thirty", "forty", "fifty"]
    static let ordinalWords: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth",
    ]
    static let monthWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]

    /// A clock time, a length of time or a date written in words.
    ///
    /// "eleven fifty seven am", "nine thirty", "half past four", "seven hours
    /// and ten minutes", "october twenty first". Plain counts are left alone —
    /// "two reminders" is a different fault with a different fix.
    static func spellsOutTime(_ sentence: String) -> Bool {
        let tokens = words(sentence.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: ".", with: ""))
        for (index, word) in tokens.enumerated() {
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            let previous = index > 0 ? tokens[index - 1] : ""
            if numberWords.contains(word) {
                if ["am", "pm", "o'clock", "oclock"].contains(next) { return true }
                if ["hour", "hours", "minute", "minutes"].contains(next) { return true }
                if hourWords.contains(word), minuteWords.contains(next) { return true }
            }
            if ["past", "to"].contains(word), ["half", "quarter"].contains(previous), numberWords.contains(next) {
                return true
            }
            if monthWords.contains(previous), ordinalWords.contains(word) || numberWords.contains(word) {
                return true
            }
        }
        return false
    }

    /// The things a brief counts, which may take a digit in front of them.
    static let countedNouns: Set<String> = [
        "reminder", "reminders", "event", "events", "meeting", "meetings", "thing", "things",
        "item", "items", "task", "tasks", "appointment", "appointments", "call", "calls",
    ]

    /// "Two reminders are due" → "2 reminders are due". Only before a noun the
    /// brief counts, so "one of them" and "no one" keep their words.
    static func digitisingCounts(_ sentence: String) -> String {
        var output: [Substring] = []
        let pieces = sentence.split(separator: " ", omittingEmptySubsequences: false)
        for (index, piece) in pieces.enumerated() {
            let word = piece.lowercased()
            if let value = hourWords.firstIndex(of: word),
               index + 1 < pieces.count,
               countedNouns.contains(words(String(pieces[index + 1])).first ?? "") {
                output.append(Substring(String(value + 1)))
            } else {
                output.append(piece)
            }
        }
        return output.joined(separator: " ")
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

    static func capitalisingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
