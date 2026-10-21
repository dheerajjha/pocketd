import PocketdKit
import SwiftUI

// MARK: - A reading more than one surface needs

/// Readings over the schedule that more than one view needs.
///
/// Gathered so that Today and Routines cannot disagree about what is owed.
/// They did, in the first version of this, because each worked it out its own
/// way.
enum ScheduleSummary {

    /// Promises made and not yet kept: questions for the brain that came due
    /// where no brain could run, and are waiting for the app to be open.
    ///
    /// `ScheduledTask.pendingRun` is what decides whether one is still worth
    /// collecting — a daily routine's uncollected 07:00 lapses when tomorrow's
    /// arrives — so this is a filter and not a judgement of its own. Briefs
    /// never appear here: a brief is never owed, it is announced.
    static func pending(in tasks: [ScheduledTask], now: Date = DemoClock.now) -> [(task: ScheduledTask, run: TaskRun)] {
        tasks.compactMap { task in
            task.pendingRun(now: now).map { (task, $0) }
        }
    }
}

// MARK: - The words

/// Every sentence the Routines screens say, in one place.
///
/// Gathered rather than written inline in a `body`, because a claim assembled
/// inside a view is a claim nobody can find, and the claims here are the ones a
/// person reads at seven in the morning to decide whether the app is working.
///
/// The vocabulary is the spec's (§8): a routine, never a task, schedule,
/// watcher or job; Pocketd, never the brain or the model.
enum ScheduleWords {

    // MARK: The card

    /// The time on a card, split so the period can be drawn smaller beside it:
    /// `("7:30", "AM")`, or `("19:30", nil)` on a 24-hour phone.
    ///
    /// The locale decides the clock, through the same `.shortened` style every
    /// other time in the app uses (`Format.time`). The split is done by finding
    /// the locale's own AM and PM symbols in that string rather than by
    /// formatting twice, so a locale that puts the period first still works.
    static func hero(
        _ recurrence: Recurrence,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> (time: String, period: String?) {
        let date: Date
        switch recurrence {
        case .once(let when):
            date = when
        case .daily(let time), .weekly(_, let time), .monthly(_, let time, _):
            date = RoutineDraft.date(from: time, calendar: calendar)
        }
        let full = Format.time(date, calendar: calendar, locale: locale)
        for symbol in periodSymbols(locale) where !symbol.isEmpty {
            if let range = full.range(of: symbol) {
                var time = full
                time.removeSubrange(range)
                return (time.trimmingCharacters(in: .whitespaces), symbol)
            }
        }
        return (full, nil)
    }

    /// The locale's AM and PM, read once for the phone's own locale: every
    /// card asks on every redraw, and a `DateFormatter` is the expensive kind
    /// of object to build that often.
    private static let currentPeriodSymbols: [String] = periodSymbols(of: .current)

    private static func periodSymbols(_ locale: Locale) -> [String] {
        locale == .current ? currentPeriodSymbols : periodSymbols(of: locale)
    }

    private static func periodSymbols(of locale: Locale) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        return [formatter.amSymbol, formatter.pmSymbol].compactMap { $0 }
    }

    /// The grey line under the time: "Weekdays · Morning brief".
    ///
    /// The pattern first, because it is what changes the meaning of the big
    /// number above it; the name second, because a card a person made has a
    /// name they will recognise at a glance anyway.
    static func cardLine(_ task: ScheduledTask, now: Date = DemoClock.now, calendar: Calendar = .current) -> String {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = pattern(task.recurrence, now: now, calendar: calendar)
        return title.isEmpty ? pattern : "\(pattern) · \(title)"
    }

    /// "Weekdays", "Every day", "Mon, Wed and Fri", "Monthly on the 1st",
    /// "Tomorrow", "Tue 20 Oct" — when it comes round, without the time.
    static func pattern(_ recurrence: Recurrence, now: Date = DemoClock.now, calendar: Calendar = .current) -> String {
        switch recurrence {
        case .once(let when):
            return Format.day(when, relativeTo: now, calendar: calendar)
        case .daily:
            return "Every day"
        case .weekly(let days, _):
            return weekdayPhrase(days, calendar: calendar)
        case .monthly(let day, _, let whenShort):
            let base = "Monthly on the \(ordinal(day))"
            // Only said when it can actually happen. "Or the last day" on a
            // rule for the 3rd is noise about a month that does not exist.
            guard day > 28 else { return base }
            return whenShort == .lastDay ? "\(base), or the last day" : "\(base), when there is one"
        }
    }

    /// What a card says about its routine's latest result, or `nil` when there
    /// is nothing yet. One line, and the colour that is not grey is reserved
    /// for something the person can do something about.
    static func cardResult(_ task: ScheduledTask, isWriting: Bool) -> Summary? {
        if isWriting { return Summary(text: "Writing…", isTrouble: false) }
        guard let run = task.lastCompletedRun else { return nil }
        let summary = summary(of: run, in: task)
        return Summary(text: preview(of: summary.text), isTrouble: summary.isTrouble)
    }

    // MARK: The editor

    /// What this routine will do, in one sentence under the name.
    ///
    /// The editor's first screen is a name, a time and some days; this line is
    /// what keeps that from being a form that hides what it makes. The choice
    /// itself lives under More options.
    static func purpose(of draft: RoutineDraft) -> String {
        switch draft.kind {
        case .brief:
            return "Pocketd tells you your brief is ready, and writes it on Today."
        case .rule:
            let what = draft.source == .events ? phrase(draft.calendarRange) : phrase(draft.reminderFilter)
            return draft.notifyWhenEmpty
                ? "Pocketd checks \(what) and tells you, even when there is nothing."
                : "Pocketd checks \(what) and tells you when there is something."
        case .ask:
            return "Pocketd lets you know, and writes the answer when you open the app."
        }
    }

    private static func phrase(_ range: CalendarRange) -> String {
        switch range {
        case .today: "what is on your calendar today"
        case .tomorrow: "what is on your calendar tomorrow"
        case .this_week: "what is on your calendar this week"
        case .next_week: "what is on your calendar next week"
        }
    }

    private static func phrase(_ filter: ReminderFilter) -> String {
        switch filter {
        case .overdue: "for overdue reminders"
        case .today: "for reminders due today"
        case .tomorrow: "for reminders due tomorrow"
        case .this_week: "for reminders due this week"
        case .all_open: "your open reminders"
        }
    }

    // MARK: Clocks

    /// A moment, as somebody would say it: "today at 7:30 AM", "yesterday at
    /// 9:00 AM", "on Tue 20 Oct at 6:00 PM".
    ///
    /// Relative for the days that cover nearly every row on these screens,
    /// because the absolute form makes a reader do date arithmetic to answer
    /// the only question they had, which is whether it has happened yet.
    static func when(_ date: Date, now: Date = DemoClock.now, calendar: Calendar = .current) -> String {
        let time = Format.time(date, calendar: calendar)
        return "\(Format.dayPhrase(date, relativeTo: now, calendar: calendar)) at \(time)"
    }

    /// "Every day at 7:00 AM", "Mon, Wed and Fri at 9:30 AM", "Monthly on the
    /// 1st at 9:00 AM" — for VoiceOver and anywhere the time is not drawn
    /// separately.
    static func recurrence(_ recurrence: Recurrence, now: Date = DemoClock.now, calendar: Calendar = .current) -> String {
        switch recurrence {
        case .once(let when):
            return "Once, \(Self.when(when, now: now, calendar: calendar))"
        default:
            let hero = hero(recurrence, calendar: calendar)
            let time = hero.period.map { "\(hero.time) \($0)" } ?? hero.time
            return "\(pattern(recurrence, now: now, calendar: calendar)) at \(time)"
        }
    }

    static func weekdayPhrase(_ days: Set<Weekday>, calendar: Calendar = .current) -> String {
        guard !days.isEmpty else { return "No days chosen" }
        if days == Weekday.workdays { return "Weekdays" }
        if days == Weekday.weekend { return "Weekends" }
        if days.count == Weekday.allCases.count { return "Every day" }
        let chosen = ordered(days, calendar: calendar)
        // Three or more days in a row, in this phone's week, are a range:
        // "Mon–Sat" rather than six names and an "and".
        let week = ordered(Set(Weekday.allCases), calendar: calendar)
        if chosen.count >= 3,
           let start = week.firstIndex(of: chosen[0]),
           Array(week[start..<min(start + chosen.count, week.count)]) == chosen {
            return "\(shortName(chosen[0], calendar: calendar))–\(shortName(chosen[chosen.count - 1], calendar: calendar))"
        }
        let names = chosen.map { shortName($0, calendar: calendar) }
        guard names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// Where a routine sits in the day, for putting a list in the order of
    /// one: minutes past midnight of the time it fires.
    static func minuteOfDay(_ recurrence: Recurrence, calendar: Calendar = .current) -> Int {
        switch recurrence {
        case .once(let when):
            let parts = calendar.dateComponents([.hour, .minute], from: when)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        case .daily(let time), .weekly(_, let time), .monthly(_, let time, _):
            return time.hour * 60 + time.minute
        }
    }

    /// The chosen days in the order this device shows a week.
    ///
    /// `Calendar.firstWeekday` is Sunday in the US, Monday across most of Europe
    /// and Saturday in much of the Gulf. `Weekday`'s raw values are Foundation's
    /// numbering and are explicitly *not* a display order; sorting on them puts
    /// Sunday first for everybody.
    static func ordered(_ days: Set<Weekday>, calendar: Calendar = .current) -> [Weekday] {
        let first = calendar.firstWeekday
        return Weekday.allCases
            .sorted { ($0.rawValue - first + 7) % 7 < ($1.rawValue - first + 7) % 7 }
            .filter(days.contains)
    }

    static func shortName(_ day: Weekday, calendar: Calendar = .current) -> String {
        // Straight out of the calendar's own symbols, so the name is in the
        // user's language.
        let symbols = calendar.shortWeekdaySymbols
        let index = day.rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(day)"
    }

    /// The letter on a day chip: "M", "T", "W".
    ///
    /// Single letters collide — T for Tuesday and Thursday — which is fine on
    /// a row of seven in the order of a week, where position disambiguates,
    /// and is why every chip still carries the full name for VoiceOver.
    static func initial(_ day: Weekday, calendar: Calendar = .current) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        let index = day.rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : shortName(day, calendar: calendar)
    }

    static func ordinal(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }

    // MARK: Where a run happened

    /// The way a run came about, in the user's terms. The line under each run
    /// in the history.
    static func context(_ context: ExecutionContext) -> String {
        switch context {
        case .backgroundRefresh: "While Pocketd was closed"
        case .foreground: "While Pocketd was open"
        case .deskMode: "While Pocketd stayed open on a charger"
        case .notificationResponse: "When you opened the notification"
        }
    }

    /// The grey sentence under a result page's title: when it last ran.
    static func ran(_ run: TaskRun, of task: ScheduledTask, now: Date = DemoClock.now) -> String {
        let moment = when(run.ranAt, now: now)
        return task.body == .brief ? "Ready \(moment)." : "Ran \(moment)."
    }

    // MARK: What a run said

    struct Summary: Equatable {
        let text: String
        /// Whether this is a state the user might want to do something about.
        /// Drives the one colour on the screen that is not grey.
        let isTrouble: Bool
    }

    /// What one run produced, or the reason it produced nothing.
    ///
    /// Every failure is spelled out rather than falling back to a generic
    /// sentence, because they have different remedies and "it failed" sends a
    /// person looking for the wrong one. The switch is exhaustive on purpose: a
    /// new outcome in `PocketdKit` should break this build rather than render
    /// as an empty row.
    static func summary(of run: TaskRun, in task: ScheduledTask) -> Summary {
        switch run.outcome {
        case .reported:
            // Sanitised on the way out even though a watcher report already
            // was on the way in. A question's answer has not been through it,
            // and the bidi overrides `PromptSanitiser` removes are precisely
            // what makes a row show something other than what it holds.
            let text = run.output?.sanitisedForPrompt() ?? ""
            return Summary(text: text.isEmpty ? "It had nothing to say." : text, isTrouble: false)

        case .nothingToReport:
            switch task.body {
            case .watcher(let rule, _):
                // The rule's own empty sentence, which is the one the
                // notification would have carried. An empty day and an
                // unreadable calendar must never look alike.
                return Summary(text: rule.emptyText, isTrouble: false)
            case .brief:
                // The banner had no day to add — nothing connected, or nothing
                // readable from a locked phone — and the brief itself is on
                // Today either way.
                return Summary(text: "Ready on Today.", isTrouble: false)
            case .prompt:
                return Summary(text: "Nothing to report.", isTrouble: false)
            }

        case .unauthorized(let authorization):
            if case .watcher(let rule, _) = task.body {
                return Summary(text: authorization.explanation(for: rule.entity), isTrouble: true)
            }
            // A question does not record which source was refused — the run
            // record deliberately holds a closed set of reasons rather than an
            // error's text — so the sentence names the screen that can say.
            return Summary(text: "It couldn't read what it needed. Check what Pocketd can see in You.", isTrouble: true)

        case .awaitingForeground:
            return Summary(text: "Not written yet.", isTrouble: false)

        case .failed(let failure):
            switch failure {
            case .noModelLoaded:
                return Summary(text: "Pocketd wasn't ready to write this.", isTrouble: true)
            case .interrupted:
                return Summary(text: "It stopped before it finished.", isTrouble: true)
            case .lapsed:
                return Summary(text: "Missed — Pocketd wasn't open before the next one.", isTrouble: true)
            case .other:
                return Summary(text: "It didn't finish.", isTrouble: true)
            }
        }
    }

    /// How much of a result a card shows before the result page does.
    static let previewLimit = 90

    /// The first ninety characters of a run's own words, flattened.
    ///
    /// A check's report is a headline and then one line per row, and a card
    /// that rendered them as lines would be a card whose height depends on
    /// somebody else's calendar. Flattened with a middle dot rather than a
    /// space, because "2 overdue Send the signed lease" reads as one sentence
    /// that has lost a word.
    static func preview(of text: String, limit: Int = previewLimit) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        // Cut on a word boundary where there is one within reach, so the tail
        // is not half a word plus an ellipsis.
        let cut = flattened.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) < 16 {
            return cut[..<space] + "…"
        }
        return cut + "…"
    }
}

// MARK: - Small things

extension String {
    /// "today at 07:00" at the front of a sentence.
    ///
    /// `capitalized` is wrong here and was the first attempt: it upper-cases
    /// every word, giving "Today At 07:00".
    var capitalisedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + String(dropFirst())
    }
}
