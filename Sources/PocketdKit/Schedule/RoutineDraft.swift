import Foundation

/// One routine as the editor holds it, which is not the shape one is stored in.
///
/// Flattened on purpose. `Recurrence` is four cases carrying different payloads
/// and `TaskBody` is three, and a form bound directly to those loses the user's
/// half-finished work every time they change a picker — type a question, glance
/// at what a rule would do, and the question is gone, because the enum only
/// holds one case at a time. Keeping every field side by side means switching
/// back and forth costs nothing, and the enums are rebuilt from it only when
/// something is actually saved.
///
/// # Equality is every field, and that is the bug this type was moved here for
///
/// It used to live in the editor's file as `ScheduleDraft`, with `==` written
/// by hand against an identity UUID alone, "for `sheet(item:)`". SwiftUI also
/// uses `==` on the value of a `@State`: a write that compares equal to what is
/// stored is not a change, so nothing re-renders. Every keystroke into the name
/// field was therefore judged "no change" — the form went on saying "It needs a
/// name." under a typed name, the placeholder sat on top of typed text, and
/// Save never enabled. Nobody could create a routine from scratch. `sheet(item:)`
/// needs `Identifiable` and nothing else; `id` gives it a stable identity while
/// `Equatable` is synthesised over everything, so an edit is an edit.
public struct RoutineDraft: Identifiable, Equatable, Sendable {

    /// What the routine does, as a form control rather than as `TaskBody`.
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        /// Today's brief, announced at this time. The default for a routine
        /// made from scratch: it needs nothing typed, nothing connected to
        /// arrive, and no brain to be worth reading.
        case brief
        /// A check over calendar or reminders, which finishes while Pocketd is
        /// closed.
        case rule
        /// The person's own question, written by the brain when Pocketd opens.
        case ask

        public var id: String { rawValue }

        /// Said from the user's side. "Watcher" and "prompt" are the right
        /// words in the code and mean nothing on a phone (spec §8).
        public var label: String {
            switch self {
            case .brief: "Your brief"
            case .rule: "Check calendar or reminders"
            case .ask: "Ask Pocketd"
            }
        }
    }

    public enum Source: String, CaseIterable, Identifiable, Sendable {
        case events
        case reminders
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .events: "Calendar"
            case .reminders: "Reminders"
            }
        }
    }

    /// How it comes round.
    ///
    /// There is no "every day": that is all seven days chosen. The day chips
    /// sit on the editor's first screen, and a separate every-day setting would
    /// be a second spelling of the same choice for the chips to contradict.
    /// `recurrence(calendar:)` stores all seven as `.daily`, so a routine saved
    /// by an older build as `.daily` opens and saves back unchanged.
    public enum Repeats: String, CaseIterable, Identifiable, Sendable {
        case weekly
        case once
        case monthly
        public var id: String { rawValue }
        public var label: String {
            switch self {
            // The days themselves are the chips on the first screen; this is
            // only which of the three shapes the routine has.
            case .weekly: "Weekly"
            case .once: "Once"
            case .monthly: "Monthly"
            }
        }
    }

    /// Stable for as long as the draft exists: what `sheet(item:)` matches on.
    public let id: UUID

    /// The routine being edited, or `nil` for one that does not exist yet.
    /// This is what decides whether saving writes a new file or edits one in
    /// place — see `apply(to:)` and `newTask(now:)`.
    public let taskID: UUID?

    /// Which template this came from, when it came from one.
    ///
    /// Carried on the draft and not on the saved task, because it is wanted for
    /// exactly one thing — the analytics event recorded at the save — and a
    /// stored field would be a provenance claim about a routine the user is
    /// free to rename and rewrite until it has nothing to do with the template
    /// it started from. `nil` means "Custom".
    public var origin: RoutineTemplate?

    public var title: String
    public var kind: Kind
    public var source: Source
    public var calendarRange: CalendarRange
    public var reminderFilter: ReminderFilter
    public var notifyWhenEmpty: Bool
    public var prompt: String

    public var repeats: Repeats
    /// Held as a `Date` because that is what `DatePicker` binds to; only the
    /// hour and minute are ever read off it. The day inside it is meaningless
    /// and is never stored — `TimeOfDay` exists precisely so that "nine in the
    /// morning" does not become an instant that drifts when the user flies
    /// somewhere.
    public var time: Date
    public var days: Set<Weekday>
    public var monthDay: Int
    public var whenShort: ShortMonth
    public var onceAt: Date

    /// Not a control in the editor — the card's switch is the one place a
    /// routine is paused — but carried so a save writes back what is there.
    public var isEnabled: Bool

    // MARK: - Making one

    /// A routine from scratch: a brief, on weekdays at nine, waiting for a name.
    public init(now: Date = Date(), calendar: Calendar = .current) {
        id = UUID()
        taskID = nil
        origin = nil
        title = ""
        kind = .brief
        source = .reminders
        calendarRange = .today
        reminderFilter = .overdue
        notifyWhenEmpty = false
        prompt = ""
        repeats = .weekly
        time = Self.date(from: TimeOfDay(hour: 9, minute: 0), on: now, calendar: calendar)
        days = Weekday.workdays
        monthDay = calendar.component(.day, from: now)
        whenShort = .lastDay
        // An hour from now, on the minute. A one-shot that defaulted to "now"
        // would be refused as already gone before anybody touched it.
        let soon = now.addingTimeInterval(3600)
        onceAt = calendar.date(bySetting: .second, value: 0, of: soon) ?? soon
        isEnabled = true
    }

    /// An existing routine, ready to edit.
    public init(_ task: ScheduledTask, now: Date = Date(), calendar: Calendar = .current) {
        self.init(now: now, calendar: calendar)
        load(task.body, task.recurrence, calendar: calendar)
        title = task.title
        isEnabled = task.isEnabled
        self = RoutineDraft(copying: self, taskID: task.id)
    }

    /// A template, as a draft that will become a new routine.
    public init(
        _ template: RoutineTemplate,
        time: TimeOfDay? = nil,
        weekdaysOnly: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.init(now: now, calendar: calendar)
        let task = template.task(now: now, calendar: calendar, time: time, weekdaysOnly: weekdaysOnly)
        load(task.body, task.recurrence, calendar: calendar)
        title = task.title
        origin = template
    }

    /// The same draft under a different `taskID`, which is a `let` because a
    /// draft that changes which routine it edits halfway through is a draft
    /// that overwrites the wrong file.
    private init(copying other: RoutineDraft, taskID: UUID?) {
        id = other.id
        self.taskID = taskID
        origin = other.origin
        title = other.title
        kind = other.kind
        source = other.source
        calendarRange = other.calendarRange
        reminderFilter = other.reminderFilter
        notifyWhenEmpty = other.notifyWhenEmpty
        prompt = other.prompt
        repeats = other.repeats
        time = other.time
        days = other.days
        monthDay = other.monthDay
        whenShort = other.whenShort
        onceAt = other.onceAt
        isEnabled = other.isEnabled
    }

    private mutating func load(_ body: TaskBody, _ recurrence: Recurrence, calendar: Calendar) {
        switch body {
        case .brief:
            kind = .brief
        case .watcher(let rule, let notify):
            kind = .rule
            notifyWhenEmpty = notify
            switch rule {
            case .events(let range):
                source = .events
                calendarRange = range
            case .reminders(let filter):
                source = .reminders
                reminderFilter = filter
            }
        case .prompt(let text):
            kind = .ask
            prompt = text
        }

        switch recurrence {
        case .once(let when):
            repeats = .once
            onceAt = when
        case .daily(let at):
            repeats = .weekly
            days = Set(Weekday.allCases)
            time = Self.date(from: at, on: time, calendar: calendar)
        case .weekly(let chosen, let at):
            repeats = .weekly
            days = chosen
            time = Self.date(from: at, on: time, calendar: calendar)
        case .monthly(let day, let at, let short):
            repeats = .monthly
            monthDay = day
            whenShort = short
            time = Self.date(from: at, on: time, calendar: calendar)
        }
    }

    // MARK: - Editing

    /// Adds the day if it is off and removes it if it is on — what a day chip
    /// does when it is tapped.
    public mutating func toggle(_ day: Weekday) {
        if days.contains(day) {
            days.remove(day)
        } else {
            days.insert(day)
        }
    }

    // MARK: - Back into the stored shapes

    public func timeOfDay(calendar: Calendar = .current) -> TimeOfDay {
        let components = calendar.dateComponents([.hour, .minute], from: time)
        return TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    public static func date(from time: TimeOfDay, on day: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? day
    }

    public func recurrence(calendar: Calendar = .current) -> Recurrence {
        switch repeats {
        case .once:
            return .once(onceAt)
        case .weekly:
            // All seven is stored as the rule it is, so an older build reads
            // "Every day" exactly as it was written.
            if days.count == Weekday.allCases.count { return .daily(at: timeOfDay(calendar: calendar)) }
            return .weekly(days: days, at: timeOfDay(calendar: calendar))
        case .monthly:
            return .monthly(day: monthDay, at: timeOfDay(calendar: calendar), whenShort: whenShort)
        }
    }

    public var work: TaskBody {
        switch kind {
        case .brief:
            .brief
        case .rule:
            switch source {
            case .events: .watcher(rule: .events(calendarRange), notifyWhenEmpty: notifyWhenEmpty)
            case .reminders: .watcher(rule: .reminders(reminderFilter), notifyWhenEmpty: notifyWhenEmpty)
            }
        case .ask:
            .prompt(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A brand-new routine, with `createdAt` doing the job it was written for:
    /// `settledThrough` starts there, so a daily 09:00 routine created at 14:00
    /// is not instantly due for a morning that had already gone before it
    /// existed.
    ///
    /// Keeps `taskID` when the draft has one. That only happens for an edit
    /// whose routine has disappeared underneath it — delete-everything on the
    /// Privacy screen, with the editor open — and writing it back under its
    /// original id is the difference between recovering the routine the user
    /// was working on and leaving a second copy of it behind.
    public func newTask(now: Date = Date(), calendar: Calendar = .current) -> ScheduledTask {
        ScheduledTask(
            id: taskID ?? UUID(),
            title: cleanTitle,
            body: work,
            recurrence: recurrence(calendar: calendar),
            isEnabled: isEnabled,
            createdAt: now
        )
    }

    /// Writes this edit onto the routine as it currently exists on disk.
    ///
    /// Field by field rather than by replacing the value, because `runs` and
    /// `settledThrough` belong to the scheduler and not to this form. A
    /// background refresh settles a run at 07:00 while the editor is open from
    /// 06:59; saving a whole `ScheduledTask` built here would write that run out
    /// of existence, and the user's only symptom would be a history with a hole
    /// in it.
    ///
    /// The `settledThrough` bump is the other half of the same care. Moving a
    /// daily routine from 09:00 to 10:00 at two in the afternoon leaves this
    /// morning's slot unsettled against a rule that now says 10:00 — which is in
    /// the past — so it is owed a firing the instant it is saved, and the user's
    /// reward for editing a morning brief is a morning brief at teatime. Only
    /// when the schedule actually changed: a rename must not silently swallow a
    /// run that is genuinely due.
    public func apply(to task: inout ScheduledTask, now: Date = Date(), calendar: Calendar = .current) {
        let updated = recurrence(calendar: calendar)
        if task.recurrence != updated {
            task.settledThrough = max(task.settledThrough, now)
        }
        // The card's switch and this save resume a routine the same way —
        // skipping what it missed while it was off. See `setEnabled`.
        task.setEnabled(isEnabled, at: now)
        let body = work
        // A promise to write an answer is only a promise while the routine
        // still asks for one. Turned into a brief or a check, it would sit on
        // the card as "Writing…" for something nothing will ever write.
        if case .prompt = body {} else {
            task.runs.removeAll(where: \.isAwaitingForeground)
        }
        task.title = cleanTitle
        task.body = body
        task.recurrence = updated
        task.updatedAt = now
    }

    // MARK: - Refusing to save something that cannot work

    /// The one reason this draft cannot be saved yet, or `nil` when it can.
    ///
    /// One sentence, shown once, above the button it is disabling. A routine
    /// that can never fire is indistinguishable, once saved, from one whose
    /// next firing is simply far away — which is what `Recurrence.isFireable`
    /// and the past-moment check are for.
    public func problem(now: Date = Date(), calendar: Calendar = .current) -> String? {
        if cleanTitle.isEmpty { return "Give it a name." }
        if kind == .ask, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a question for Pocketd."
        }
        let recurrence = recurrence(calendar: calendar)
        if case .weekly(let chosen, _) = recurrence, chosen.isEmpty { return "Pick at least one day." }
        guard recurrence.isFireable else { return "This can never come round." }
        if case .once(let when) = recurrence, when <= now { return "Pick a time that hasn't passed." }
        return nil
    }
}
