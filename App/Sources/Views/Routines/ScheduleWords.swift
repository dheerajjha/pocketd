import PocketdKit
import SwiftUI

// MARK: - Two questions both surfaces ask

/// Readings over the schedule that more than one view needs.
///
/// Gathered so that Today's bell badge and the Routines tab cannot disagree
/// about what is due. They did, in the first version of this, because each
/// worked it out its own way.
enum ScheduleSummary {

    /// The next firing across every task, or `nil` when nothing will fire again
    /// — every task paused, or every recurrence spent.
    static func nextFiring(in tasks: [ScheduledTask], now: Date = Date()) -> Date? {
        tasks.compactMap { $0.dueness(now: now).next }.min()
    }

    /// Promises made and not yet kept: prompt tasks that came due where no model
    /// could run, and are waiting for the app to be open.
    ///
    /// `ScheduledTask.pendingRun` is what decides whether one is still worth
    /// collecting — a daily task's uncollected 07:00 lapses when tomorrow's
    /// arrives — so this is a filter and not a judgement of its own.
    static func pending(in tasks: [ScheduledTask], now: Date = Date()) -> [(task: ScheduledTask, run: TaskRun)] {
        tasks.compactMap { task in
            task.pendingRun(now: now).map { (task, $0) }
        }
    }
}

// MARK: - The words

/// Every sentence these two screens say about scheduling, in one place.
///
/// Gathered rather than written inline in a `body` for the reason
/// `AbilitiesView` gives about its own copy: a claim assembled inside a view is
/// a claim nobody can write a test against, and the claims here are the ones
/// most likely to be quietly wrong — they are the app's only explanation of why
/// a 7am prompt task does not arrive at 7am with an answer in it.
///
/// This belongs in `PocketdKit` beside `ExecutionContext`, where a test could
/// hold it to that. It is here because this change may not touch that module;
/// the handoff asks for the move.
enum ScheduleWords {

    // MARK: Which half of the feature

    struct Kind {
        let chip: String
        let symbol: String
    }

    /// The distinction the whole feature turns on, in three words on a chip.
    ///
    /// Phrased from the user's side rather than the implementation's. "Watcher"
    /// and "prompt" are the right words in the code and mean nothing on a phone;
    /// what a person needs to know is whether this thing works while they are
    /// asleep.
    static func kind(_ body: TaskBody) -> Kind {
        body.needsModel
            ? Kind(chip: "Needs you here", symbol: "brain")
            : Kind(chip: "Runs on its own", symbol: "clock.badge.checkmark")
    }

    /// The honesty requirement, in the smallest space it fits into.
    ///
    /// The failure being designed against: somebody sets up a 7am briefing that
    /// needs the brain, gets nothing useful for a week, and concludes the app is
    /// broken. Discovering the constraint while *making* one of these is fine;
    /// discovering it a week later is the thing that must not happen. So the
    /// sentence sits under the choice in the editor, and again under the list.
    ///
    /// "Brain" rather than "model", here and everywhere below, because these
    /// sentences are read on the Routines tab and in its editor — consumer
    /// screens, where spec §2 puts the real word one level down.
    /// Two sentences, because a paragraph under a grid is a paragraph nobody
    /// reads and this one has to survive somebody skimming. Both halves, in the
    /// order that matters: what runs on its own, and what needs you here. The
    /// long version is in the editor, under the control that decides it.
    static let listFooter = """
        A routine built from a rule runs on its own while Pocketd is closed, and its notification arrives \
        with the answer in it. One that needs the brain notifies you on time and writes the answer when you \
        open the app.
        """

    /// The same fact, at the moment it is being chosen.
    static func explanation(needsModel: Bool) -> String {
        needsModel
            ? """
            This one needs the brain, and the brain needs Pocketd to be open — iOS will not give a closed app \
            the graphics chip. You get the notification exactly on time; the answer is written when you open \
            the app, or on its own if the phone is charging in desk mode.
            """
            : """
            This one is a rule, not a question for the brain, so the phone can answer it while Pocketd is \
            closed. The notification arrives with the answer already in it.
            """
    }

    /// Two sentences on the results row: why it is owed, and what fixes it. The
    /// remedy differs, so the sentence does.
    static func waitingFooter(hasModel: Bool) -> String {
        hasModel
            ? """
            They came due while Pocketd was closed, which is where the brain cannot run. Writing them takes \
            a few seconds, here.
            """
            : """
            They came due while Pocketd was closed, which is where the brain cannot run. Open it with a \
            brain loaded and they write themselves.
            """
    }

    // MARK: Clocks

    /// A firing, as somebody would say it out loud.
    ///
    /// "today at 07:00" rather than "Fri 12 Sep, 07:00" for the two days that
    /// cover nearly every row on this screen, because the absolute form makes a
    /// reader do the date arithmetic to answer the only question they had, which
    /// is whether it has happened yet. Anything further out gets the same format
    /// the watcher's own report lines use, so a notification and this screen
    /// never disagree about how a date looks.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(
            Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        )
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        // The zone comes off the same calendar that placed the firing rather
        // than off `.current`, for the reason `WatcherEvaluation.line(for:)`
        // gives: those are the same object in the app and different ones on the
        // night somebody lands abroad.
        return PersonalDataFormat.moment(date, timeZone: calendar.timeZone, calendar: calendar)
    }

    /// A firing as a day alone, for a line that has already said the time.
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow"
        }
        return PersonalDataFormat.day(date, timeZone: calendar.timeZone, calendar: calendar)
    }

    /// "Every day at 07:00", "Mon, Wed and Fri at 09:30", "Monthly on the 1st".
    static func recurrence(_ recurrence: Recurrence, calendar: Calendar = .current) -> String {
        switch recurrence {
        case .once(let when):
            return "Once, \(Self.when(when, calendar: calendar))"
        case .daily(let time):
            return "Every day at \(clock(time, calendar: calendar))"
        case .weekly(let days, let time):
            return "\(weekdayPhrase(days, calendar: calendar)) at \(clock(time, calendar: calendar))"
        case .monthly(let day, let time, let whenShort):
            let base = "Monthly on the \(ordinal(day)) at \(clock(time, calendar: calendar))"
            // Only said when it can actually happen. Appending "or the last day"
            // to a rule for the 3rd is noise about a month that does not exist.
            guard day > 28 else { return base }
            return whenShort == .lastDay
                ? "\(base), or the last day in shorter months"
                : "\(base), skipping shorter months"
        }
    }

    static func clock(_ time: TimeOfDay, calendar: Calendar = .current) -> String {
        // Built through `DateComponents` rather than with `String(format:)`, so
        // that a phone set to a 12-hour clock says "7:00 AM" like every other
        // time on the screen. A hard-coded `%02d:%02d` was the first version and
        // it read as a 24-hour clock to a user whose device is not.
        var components = DateComponents()
        components.hour = time.hour
        components.minute = time.minute
        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:%02d", time.hour, time.minute)
        }
        return date.formatted(
            Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        )
    }

    static func weekdayPhrase(_ days: Set<Weekday>, calendar: Calendar = .current) -> String {
        guard !days.isEmpty else { return "No days chosen" }
        if days == Weekday.workdays { return "Weekdays" }
        if days == Weekday.weekend { return "Weekends" }
        if days.count == Weekday.allCases.count { return "Every day" }
        let names = ordered(days, calendar: calendar).map { shortName($0, calendar: calendar) }
        guard names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
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
        // user's language. `veryShortWeekdaySymbols` is a single letter and
        // collides — T for Tuesday and Thursday — which is exactly what a day
        // picker must not do.
        let symbols = calendar.shortWeekdaySymbols
        let index = day.rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(day)"
    }

    static func ordinal(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }

    // MARK: Where a run happened

    /// The execution context in the user's terms.
    ///
    /// This one line under each run is what makes the constraint legible without
    /// a paragraph about Metal: a watcher's history reads "while Pocketd was
    /// closed" every morning, a prompt task's reads "when you opened the app",
    /// and the difference explains itself.
    static func context(_ context: ExecutionContext) -> String {
        switch context {
        case .backgroundRefresh: "Ran while Pocketd was closed"
        case .foreground: "Ran while you had the app open"
        case .deskMode: "Ran by itself, in Desk Mode"
        case .notificationResponse: "Ran when you opened the notification"
        }
    }

    // MARK: What a run said

    struct Summary {
        let text: String
        /// Whether this is a state the user might want to do something about.
        /// Drives the one colour on the screen that is not grey.
        let isTrouble: Bool
    }

    /// What one run produced, or the reason it produced nothing.
    ///
    /// Every `RunFailure` is spelled out rather than falling back to a generic
    /// sentence, because the four of them have four different remedies and "the
    /// task failed" sends a user looking for the wrong one. The switch is
    /// exhaustive on purpose: a new outcome in `PocketdKit` should break this
    /// build rather than render as an empty row.
    static func summary(of run: TaskRun, in task: ScheduledTask) -> Summary {
        switch run.outcome {
        case .reported:
            // Sanitised on the way out even though a watcher report already was
            // on the way in. A prompt task's output has not been through it, and
            // the bidi overrides `PromptSanitiser` removes are precisely what
            // makes a row show something other than what it holds.
            let text = run.output?.sanitisedForPrompt() ?? ""
            return Summary(text: text.isEmpty ? "Reported nothing." : text, isTrouble: false)

        case .nothingToReport:
            // The rule's own empty sentence, which is the one the notification
            // would have carried. An empty day and an unreadable calendar must
            // never look alike, and `CalendarRange.emptyText` exists so there is
            // a single wording for it.
            if case .watcher(let rule, _) = task.body {
                return Summary(text: rule.emptyText, isTrouble: false)
            }
            return Summary(text: "Nothing to report.", isTrouble: false)

        case .unauthorized(let authorization):
            if case .watcher(let rule, _) = task.body {
                return Summary(text: authorization.explanation(for: rule.entity), isTrouble: true)
            }
            // A prompt task does not record which tool was refused — the run
            // record deliberately holds a closed set of reasons rather than an
            // error's text — so the sentence names the screen that can say,
            // instead of guessing an entity and being confidently wrong.
            return Summary(
                text: "It could not read what it needed. Check what is switched on under You.",
                isTrouble: true
            )

        case .awaitingForeground:
            return Summary(text: "Due, and not written yet.", isTrouble: false)

        case .failed(let failure):
            switch failure {
            case .noModelLoaded:
                return Summary(text: "No brain was loaded, so there was nothing to think with.", isTrouble: true)
            case .interrupted:
                return Summary(
                    text: "It started and did not finish — the app went to the background, or the phone got too warm.",
                    isTrouble: true
                )
            case .lapsed:
                return Summary(
                    text: "Never collected: the next run came due before anyone opened the app.",
                    isTrouble: true
                )
            case .other:
                return Summary(text: "It did not finish.", isTrouble: true)
            }
        }
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

// MARK: - The words only the Routines tab needs

extension ScheduleWords {

    /// The countdown, in the mono voice the rest of the app reads numbers in.
    ///
    /// "IN 42 MIN" · "IN 3 H" · "TODAY 19:00" · "TOMORROW 07:30" · "SUN 18:00".
    /// Relative while a person can still plan around it and absolute after
    /// that, because "in 19 hours" is arithmetic and "tomorrow 07:30" is an
    /// answer. The handover is at twelve hours, which is the point past which
    /// nobody converts hours into a clock face in their head.
    ///
    /// Uppercased here rather than by the label that draws it, so the spoken
    /// form below can keep readable casing — the same argument `SectionLabel`
    /// makes about shouting at VoiceOver.
    static func nextLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "ANY MOMENT" }
        if seconds < 3600 {
            return "IN \(Int(seconds / 60)) MIN"
        }
        if seconds < 12 * 3600 {
            return "IN \(Int((seconds / 3600).rounded())) H"
        }
        let time = timeOnly(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY \(time)".uppercased() }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "TOMORROW \(time)".uppercased()
        }
        // Inside the next week a weekday name is the shortest thing that is
        // still unambiguous; past that it needs a date, or "MON" is off by
        // eight days.
        if let week = calendar.date(byAdding: .day, value: 7, to: now), date < week {
            let weekday = date.formatted(
                Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
            )
            return "\(weekday) \(time)".uppercased()
        }
        let day = date.formatted(
            Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        )
        return "\(day) \(time)".uppercased()
    }

    /// What a screen reader says instead of the shouted form above.
    static func nextSpoken(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        "Next \(when(date, now: now, calendar: calendar))"
    }

    /// The clock face on its own, for a label that has already said the day.
    static func timeOnly(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute())
    }

    /// How much of a result a card shows.
    ///
    /// Ninety characters is a sentence and a bit at 15pt on the narrowest
    /// iPhone in support — enough to recognise this morning's brief without the
    /// card becoming the result. The full text is one tap away, which is the
    /// whole reason the card carries a chevron.
    static let previewLimit = 90

    /// The first ninety characters of a run's own words, tidied.
    ///
    /// A watcher's report is a headline and then one line per row, and a card
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
