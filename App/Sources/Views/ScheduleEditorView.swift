import PocketdKit
import SwiftUI

// MARK: - The form's own state

/// One task as a form holds it, which is not the shape one is stored in.
///
/// Flattened on purpose. `Recurrence` is four cases carrying different payloads
/// and `TaskBody` is two, and a form bound directly to those loses the user's
/// half-finished work every time they change a segmented control — type a
/// prompt, glance at what a rule would do, and the prompt is gone, because the
/// enum only holds one case at a time. Keeping every field side by side means
/// switching back and forth costs nothing, and the enums are rebuilt from it
/// only when something is actually saved.
///
/// Identity is the task being edited, or a fresh UUID for a new one, and
/// `Equatable`/`Hashable` are written by hand against that alone. They exist for
/// `navigationDestination(item:)` and not for comparing drafts: `Recurrence` and
/// `TimeOfDay` are `Equatable` but not `Hashable`, so there is nothing to
/// synthesise from, and identity is the only thing SwiftUI is asking about here.
struct ScheduleDraft: Identifiable, Hashable, Sendable {

    /// Which half of the feature this is, as a form control rather than as the
    /// two cases of `TaskBody`.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case rule
        case model
        var id: String { rawValue }

        /// Deliberately not "watcher" and "prompt". Those are the right names in
        /// the code and say nothing on a phone; these say what the user is
        /// choosing between, which is whether the phone can answer this alone.
        var label: String {
            switch self {
            case .rule: "A rule"
            case .model: "Ask the model"
            }
        }
    }

    enum Source: String, CaseIterable, Identifiable, Sendable {
        case events
        case reminders
        var id: String { rawValue }
        var label: String {
            switch self {
            case .events: "Calendar"
            case .reminders: "Reminders"
            }
        }
    }

    enum Repeats: String, CaseIterable, Identifiable, Sendable {
        case once, daily, weekly, monthly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .once: "Once"
            case .daily: "Every day"
            case .weekly: "Some days"
            case .monthly: "Monthly"
            }
        }
    }

    /// `nil` for a task that does not exist yet. This is also what decides
    /// whether saving writes a new file or edits one in place, which matters
    /// more than it looks — see `SchedulesView.save`.
    let id: UUID?
    private let identity: UUID

    var title = ""
    var kind: Kind = .rule
    var source: Source = .events
    var calendarRange: CalendarRange = .today
    var reminderFilter: ReminderFilter = .overdue
    var notifyWhenEmpty = false
    var prompt = ""

    var repeats: Repeats = .daily
    /// Held as a `Date` because that is what `DatePicker` binds to; only the
    /// hour and minute are ever read off it. The day inside it is meaningless
    /// and is never stored — `TimeOfDay` exists precisely so that "nine in the
    /// morning" does not become an instant that drifts when the user flies
    /// somewhere.
    var time = ScheduleDraft.date(from: TimeOfDay(hour: 9, minute: 0))
    var days: Set<Weekday> = Weekday.workdays
    var monthDay = 1
    var whenShort: ShortMonth = .lastDay
    var onceAt = Date().addingTimeInterval(3600)

    var isEnabled = true

    init() {
        id = nil
        identity = UUID()
    }

    init(_ task: ScheduledTask, calendar: Calendar = .current) {
        self.init(
            id: task.id,
            title: task.title,
            body: task.body,
            recurrence: task.recurrence,
            isEnabled: task.isEnabled,
            calendar: calendar
        )
    }

    /// A starter, as a draft.
    ///
    /// Through the same type the editor uses rather than straight to a
    /// `ScheduledTask`, so that one tap on a starter and one tap on Save in the
    /// editor take the identical path into the store — including the
    /// notification permission request and the reconcile that `AppModel` does
    /// around a save. A starter that wrote its own file was scheduled correctly
    /// and never notified anybody.
    init(_ starter: ScheduleStarter, calendar: Calendar = .current) {
        self.init(
            id: nil,
            title: starter.title,
            body: starter.work,
            recurrence: starter.recurrence,
            isEnabled: true,
            calendar: calendar
        )
    }

    private init(
        id: UUID?,
        title: String,
        body: TaskBody,
        recurrence: Recurrence,
        isEnabled: Bool,
        calendar: Calendar
    ) {
        self.id = id
        // A new draft still needs one, and it has to be stable for as long as
        // the draft is on screen: it is what `navigationDestination(item:)`
        // matches on, and a fresh UUID per comparison would push the editor
        // again on every redraw.
        identity = id ?? UUID()
        self.title = title
        self.isEnabled = isEnabled

        switch body {
        case .watcher(let rule, let notifyWhenEmpty):
            kind = .rule
            self.notifyWhenEmpty = notifyWhenEmpty
            switch rule {
            case .events(let range):
                source = .events
                calendarRange = range
            case .reminders(let filter):
                source = .reminders
                reminderFilter = filter
            }
        case .prompt(let text):
            kind = .model
            prompt = text
        }

        switch recurrence {
        case .once(let when):
            repeats = .once
            onceAt = when
        case .daily(let at):
            repeats = .daily
            time = Self.date(from: at, calendar: calendar)
        case .weekly(let days, let at):
            repeats = .weekly
            self.days = days
            time = Self.date(from: at, calendar: calendar)
        case .monthly(let day, let at, let whenShort):
            repeats = .monthly
            monthDay = day
            self.whenShort = whenShort
            time = Self.date(from: at, calendar: calendar)
        }
    }

    // MARK: Back into the stored shapes

    func timeOfDay(calendar: Calendar = .current) -> TimeOfDay {
        let components = calendar.dateComponents([.hour, .minute], from: time)
        return TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    static func date(from time: TimeOfDay, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }

    func recurrence(calendar: Calendar = .current) -> Recurrence {
        switch repeats {
        case .once: .once(onceAt)
        case .daily: .daily(at: timeOfDay(calendar: calendar))
        case .weekly: .weekly(days: days, at: timeOfDay(calendar: calendar))
        case .monthly: .monthly(day: monthDay, at: timeOfDay(calendar: calendar), whenShort: whenShort)
        }
    }

    var work: TaskBody {
        switch kind {
        case .rule:
            switch source {
            case .events: .watcher(rule: .events(calendarRange), notifyWhenEmpty: notifyWhenEmpty)
            case .reminders: .watcher(rule: .reminders(reminderFilter), notifyWhenEmpty: notifyWhenEmpty)
            }
        case .model:
            .prompt(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A brand-new task, with `createdAt` doing the job it was written for:
    /// `settledThrough` starts there, so a daily 09:00 task created at 14:00 is
    /// not instantly due for a morning that had already gone before it existed.
    ///
    /// Keeps `id` when the draft has one. That only happens for an edit whose
    /// task has disappeared underneath it — the Data screen's delete-everything,
    /// with this editor open — and writing it back under its original id is the
    /// difference between recovering the task the user was working on and
    /// leaving a second copy of it behind.
    func newTask(now: Date = Date(), calendar: Calendar = .current) -> ScheduledTask {
        ScheduledTask(
            id: id ?? UUID(),
            title: cleanTitle,
            body: work,
            recurrence: recurrence(calendar: calendar),
            isEnabled: isEnabled,
            createdAt: now
        )
    }

    /// Writes this edit onto the task as it currently exists on disk.
    ///
    /// Field by field rather than by replacing the value, because `runs` and
    /// `settledThrough` belong to the scheduler and not to this form. A
    /// background refresh settles a run at 07:00 while the editor is open from
    /// 06:59; saving a whole `ScheduledTask` built here would write that run out
    /// of existence, and the user's only symptom would be a history with a hole
    /// in it.
    ///
    /// The `settledThrough` bump is the other half of the same care. Moving a
    /// daily task from 09:00 to 10:00 at two in the afternoon leaves this
    /// morning's slot unsettled against a rule that now says 10:00 — which is in
    /// the past — so the task is owed a firing the instant it is saved, and the
    /// user's reward for editing a morning briefing is a morning briefing at
    /// teatime. Only when the schedule actually changed: a rename must not
    /// silently swallow a run that is genuinely due.
    func apply(to task: inout ScheduledTask, now: Date = Date(), calendar: Calendar = .current) {
        let updated = recurrence(calendar: calendar)
        if task.recurrence != updated {
            task.settledThrough = max(task.settledThrough, now)
        }
        // Resuming a paused task skips what it missed while it was off, for the
        // reason `SchedulesView.setEnabled` gives at length: a week's holiday
        // should not end in a notification about last Tuesday.
        if isEnabled, !task.isEnabled {
            task.settledThrough = max(task.settledThrough, now)
        }
        task.title = cleanTitle
        task.body = work
        task.recurrence = updated
        task.isEnabled = isEnabled
        task.updatedAt = now
    }

    // MARK: Identity

    static func == (lhs: ScheduleDraft, rhs: ScheduleDraft) -> Bool { lhs.identity == rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

// MARK: - The editor

/// Creating or changing one scheduled task.
///
/// The screen is arranged so that the sentence explaining what this app can and
/// cannot do sits directly under the control that decides it. That placement is
/// the whole design: the failure being avoided is somebody setting up a 7am
/// briefing that needs the model, receiving nothing useful for a week, and
/// concluding the app is broken. Finding out here, while choosing, costs
/// nothing; finding out a week later costs the feature.
struct ScheduleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ScheduleDraft
    private let save: (ScheduleDraft) -> Void
    private let goTo: (AppTab) -> Void

    init(
        draft: ScheduleDraft,
        goTo: @escaping (AppTab) -> Void = { _ in },
        save: @escaping (ScheduleDraft) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.goTo = goTo
        self.save = save
    }

    var body: some View {
        Form {
            nameSection
            workSection
            scheduleSection
            if draft.id != nil {
                Section {
                    Toggle("Enabled", isOn: $draft.isEnabled)
                } footer: {
                    // Pausing rather than deleting is the state somebody wants
                    // for a holiday, and the one a delete cannot express.
                    Text("A paused task keeps its schedule and produces nothing until you switch it back on.")
                }
            }
        }
        .navigationTitle(draft.id == nil ? "New task" : "Edit task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save(draft)
                    dismiss()
                }
                .disabled(contentProblem != nil || scheduleProblem != nil)
            }
        }
    }

    // MARK: Name

    private var nameSection: some View {
        Section {
            TextField("Name", text: $draft.title)
                .textInputAutocapitalization(.sentences)
        } header: {
            Text("Name")
        } footer: {
            if let problem = contentProblem, draft.cleanTitle.isEmpty {
                Text(problem).foregroundStyle(scheduleWarningColour)
            } else {
                Text("What you will see on the notification.")
            }
        }
    }

    // MARK: What it does

    private var workSection: some View {
        Section {
            Picker("Kind", selection: $draft.kind) {
                ForEach(ScheduleDraft.Kind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            switch draft.kind {
            case .rule:
                Picker("Look at", selection: $draft.source) {
                    ForEach(ScheduleDraft.Source.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                switch draft.source {
                case .events:
                    Picker("Which", selection: $draft.calendarRange) {
                        ForEach(CalendarRange.allCases, id: \.self) { range in
                            Text(ScheduleWords.title(range)).tag(range)
                        }
                    }
                case .reminders:
                    Picker("Which", selection: $draft.reminderFilter) {
                        ForEach(ReminderFilter.allCases, id: \.self) { filter in
                            Text(ScheduleWords.title(filter)).tag(filter)
                        }
                    }
                }
                Toggle("Tell me even when there is nothing", isOn: $draft.notifyWhenEmpty)

            case .model:
                // A plain `TextField` collapses a paragraph into one scrolling
                // line, and what goes here is a paragraph — this is the box the
                // user writes the actual question in.
                TextEditor(text: $draft.prompt)
                    .frame(minHeight: 96)
                    .font(.body)
                    .overlay(alignment: .topLeading) {
                        if draft.prompt.isEmpty {
                            Text("What should it work out for you?")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }

            if let warning = accessWarning {
                Text(warning.sentence)
                    .font(.footnote)
                    .foregroundStyle(scheduleWarningColour)
                if warning.offersAbilities {
                    Button("Open Abilities") { goTo(.abilities) }
                }
            }
        } header: {
            Text("What it does")
        } footer: {
            // Directly under the choice. This is the honesty requirement, and it
            // is two sentences rather than a paragraph because a paragraph in a
            // form footer is a paragraph nobody reads.
            VStack(alignment: .leading, spacing: 6) {
                Text(ScheduleWords.explanation(needsModel: draft.kind == .model))
                if let problem = contentProblem, !draft.cleanTitle.isEmpty {
                    Text(problem).foregroundStyle(scheduleWarningColour)
                }
            }
        }
    }

    // MARK: When

    private var scheduleSection: some View {
        Section {
            Picker("Repeat", selection: $draft.repeats) {
                ForEach(ScheduleDraft.Repeats.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            switch draft.repeats {
            case .once:
                // Bounded below by now: a one-shot in the past has no firing at
                // all — `FireSequence.next` returns nothing for it — so it would
                // save cleanly and then sit in the list forever saying "nothing
                // further".
                DatePicker("At", selection: $draft.onceAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            case .daily:
                DatePicker("At", selection: $draft.time, displayedComponents: .hourAndMinute)
            case .weekly:
                dayPicker
                DatePicker("At", selection: $draft.time, displayedComponents: .hourAndMinute)
            case .monthly:
                Picker("Day of the month", selection: $draft.monthDay) {
                    ForEach(1...31, id: \.self) { day in
                        Text(ScheduleWords.ordinal(day)).tag(day)
                    }
                }
                if draft.monthDay > 28 {
                    // Only asked when it can happen. There is no default answer
                    // to "what does the 31st mean in February" that does not
                    // surprise somebody, which is why `ShortMonth` makes the
                    // caller say.
                    Picker("In shorter months", selection: $draft.whenShort) {
                        Text("Use the last day").tag(ShortMonth.lastDay)
                        Text("Skip that month").tag(ShortMonth.skip)
                    }
                }
                DatePicker("At", selection: $draft.time, displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("When")
        } footer: {
            if let problem = scheduleProblem {
                Text(problem).foregroundStyle(scheduleWarningColour)
            } else {
                // The rule, resolved against the real calendar, as dates. This
                // is the only way a user can tell that "monthly on the 31st,
                // skipping shorter months" means a four-month gap — and it
                // catches a daylight-saving or first-weekday mistake in the one
                // place where it is still cheap to notice.
                Text(preview)
            }
        }
    }

    /// The days, as a row that pushes a list rather than as a row of chips.
    ///
    /// A row of seven tappable chips was written twice — as `Button`s, then as
    /// `Toggle`s, then with a bare `onTapGesture` — and all three looked exactly
    /// right and did nothing at all. A `Form` row holding seven controls does not
    /// deliver a touch to the one that was hit, and the failure is completely
    /// silent: the preview underneath simply never changed. Found by tapping
    /// Monday in the simulator, which is the only way it shows up.
    ///
    /// A pushed list is also the pattern the platform uses for exactly this
    /// choice — the Clock app's Repeat screen is seven rows with checkmarks —
    /// and it fixes a second problem the chips had: a 32-point chip is below the
    /// 44-point minimum for something a thumb has to hit.
    private var dayPicker: some View {
        NavigationLink {
            DayPicker(days: $draft.days)
        } label: {
            LabeledContent("Days", value: ScheduleWords.weekdayPhrase(draft.days))
        }
    }

    // MARK: What will actually happen

    private var preview: String {
        let recurrence = draft.recurrence()
        // The picker above is the whole answer for a one-shot, and three
        // identical dates would be a lie about it. What the picker does not say
        // is that there is no second one.
        if case .once = recurrence { return "Once only. It will not repeat." }

        var firings: [Date] = []
        var cursor = Date()
        // Three, because one is not enough to show a pattern and a list of them
        // is not a footer. Three is what makes "some days" legible.
        while firings.count < 3, let next = FireSequence.next(after: cursor, of: recurrence) {
            firings.append(next)
            cursor = next
        }
        guard !firings.isEmpty else { return "This will never fire." }
        // Days rather than whole dates: the time picker is directly above, and
        // "tomorrow at 7:00 AM, then Mon 14 Sep at 7:00 AM, then Tue 15 Sep at
        // 7:00 AM" — the first version — buries the only thing this line is for,
        // which is the shape of the pattern.
        return "Next: " + firings.map { ScheduleWords.day($0) }.joined(separator: ", then ")
    }

    // MARK: Refusing to save something that cannot work

    private var contentProblem: String? {
        if draft.cleanTitle.isEmpty { return "It needs a name." }
        if draft.kind == .model, case .prompt(let text) = draft.work, text.isEmpty {
            return "Type what you want it to work out."
        }
        return nil
    }

    /// The schedule refusals, which exist because a task that can never fire is
    /// indistinguishable, once saved, from one whose next firing is simply far
    /// away. `Recurrence.isFireable` is written for exactly this check.
    private var scheduleProblem: String? {
        let recurrence = draft.recurrence()
        if case .weekly(let days, _) = recurrence, days.isEmpty {
            return "Pick at least one day, or this will sit in the list looking scheduled and never run."
        }
        guard recurrence.isFireable else { return "This rule can never come round." }
        if case .once(let when) = recurrence, when <= Date() {
            return "That moment has already gone. Pick one in the future."
        }
        return nil
    }

    // MARK: The ability this rule depends on

    private struct AccessWarning {
        let sentence: String
        let offersAbilities: Bool
    }

    /// Whether the thing this task reads is actually readable.
    ///
    /// A watcher over a calendar the app was never given is not a task, it is a
    /// daily notification saying permission is off — and the person who would
    /// have to work that out is the one who set it up weeks earlier. Said here,
    /// while they are looking at the rule.
    ///
    /// Only for rules. A prompt task's tools are decided at run time by what is
    /// switched on then, and guessing which of them the sentence will reach for
    /// would put a specific, confident and possibly wrong warning on the screen.
    private var accessWarning: AccessWarning? {
        guard draft.kind == .rule else { return nil }
        let entity: PersonalDataEntity = draft.source == .events ? .calendar : .reminders
        guard model.isEnabled(entity) else {
            return AccessWarning(
                sentence: """
                    Pocketd is not set up to read your \(entity.noun) yet, so this rule would have nothing to \
                    look at.
                    """,
                offersAbilities: true
            )
        }
        // Absent means nobody has looked yet, which is not the same as refused,
        // and warning about a permission this process has not checked is how a
        // screen ends up shouting at someone whose setup is fine.
        guard let authorization = model.personalDataAuthorization[entity], !authorization.canRead else {
            return nil
        }
        return AccessWarning(sentence: authorization.explanation(for: entity), offersAbilities: false)
    }
}

// MARK: - Which days

/// The seven days, one row each, with a tick against the chosen ones.
///
/// Its own screen rather than an inline row of chips: see `dayPicker`. One
/// `Button` per row is the shape that actually receives a tap inside a `List`,
/// and a full-width row is a target a thumb can hit.
private struct DayPicker: View {
    @Binding var days: Set<Weekday>

    var body: some View {
        List {
            Section {
                // In the order this device shows a week, which `ScheduleWords`
                // works out from `Calendar.firstWeekday` — Sunday in the US,
                // Monday across most of Europe, Saturday in much of the Gulf.
                ForEach(ScheduleWords.ordered(Set(Weekday.allCases)), id: \.self) { day in
                    Button {
                        if days.contains(day) {
                            days.remove(day)
                        } else {
                            days.insert(day)
                        }
                    } label: {
                        HStack {
                            Text(ScheduleWords.fullName(day))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            if days.contains(day) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ScheduleWords.fullName(day))
                    .accessibilityValue(days.contains(day) ? "On" : "Off")
                }
            } footer: {
                if days.isEmpty {
                    // The same refusal the editor shows, said where the mistake
                    // is being made. `Recurrence.isFireable` exists because a
                    // weekly rule with no days is indistinguishable, once saved,
                    // from one whose next firing is simply far away.
                    Text("Pick at least one day, or this will never run.")
                        .foregroundStyle(scheduleWarningColour)
                } else {
                    Text(ScheduleWords.weekdayPhrase(days))
                }
            }
        }
        .navigationTitle("Days")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - The words only the editor needs

extension ScheduleWords {
    /// "Monday", in the user's language.
    ///
    /// The list rows have room for the whole word, and the abbreviations
    /// `shortName` gives are there for a summary line rather than for a thing
    /// somebody is choosing between.
    static func fullName(_ day: Weekday, calendar: Calendar = .current) -> String {
        let symbols = calendar.weekdaySymbols
        let index = day.rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : shortName(day, calendar: calendar)
    }

    /// Display names for the two range enums.
    ///
    /// The raw values are snake_case because they are what the model literally
    /// sees in the tool schema; `this_week` on a picker row is the kind of
    /// detail that makes an app feel like a database front end.
    static func title(_ range: CalendarRange) -> String {
        switch range {
        case .today: "What is on today"
        case .tomorrow: "What is on tomorrow"
        case .this_week: "What is on this week"
        case .next_week: "What is on next week"
        }
    }

    static func title(_ filter: ReminderFilter) -> String {
        switch filter {
        case .overdue: "Overdue"
        case .today: "Due today"
        case .tomorrow: "Due tomorrow"
        case .this_week: "Due this week"
        case .all_open: "Everything still open"
        }
    }
}
