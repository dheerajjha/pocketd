import PocketdKit
import SwiftUI

// MARK: - The form's own state

/// One routine as a form holds it, which is not the shape one is stored in.
///
/// Flattened on purpose. `Recurrence` is four cases carrying different payloads
/// and `TaskBody` is two, and a form bound directly to those loses the user's
/// half-finished work every time they change a segmented control — type a
/// prompt, glance at what a rule would do, and the prompt is gone, because the
/// enum only holds one case at a time. Keeping every field side by side means
/// switching back and forth costs nothing, and the enums are rebuilt from it
/// only when something is actually saved.
///
/// Identity is the routine being edited, or a fresh UUID for a new one, and
/// `Equatable`/`Hashable` are written by hand against that alone. They exist for
/// `sheet(item:)` and not for comparing drafts: `Recurrence` and `TimeOfDay`
/// are `Equatable` but not `Hashable`, so there is nothing to synthesise from,
/// and identity is the only thing SwiftUI is asking about here.
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
        ///
        /// "The brain" rather than "the model", because this is a consumer
        /// screen — spec §2 puts the real word one level down, under Brain.
        var label: String {
            switch self {
            case .rule: "A rule"
            case .model: "Ask the brain"
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

    /// `nil` for a routine that does not exist yet. This is also what decides
    /// whether saving writes a new file or edits one in place, which matters
    /// more than it looks — see `RoutinesView.save`.
    let id: UUID?
    private let identity: UUID

    /// Which template card this came from, when it came from one.
    ///
    /// Carried on the draft and not on the saved `ScheduledTask`, because it is
    /// wanted for exactly one thing — `AnalyticsEvent.routineCreated`, recorded
    /// at the save — and a stored field would be a provenance claim about a
    /// routine the user is free to rename and rewrite until it has nothing to
    /// do with the card it started from. `nil` means the plus button, which is
    /// what `RoutineOrigin.custom` is for.
    var origin: RoutineTemplate?

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

    /// A template, as a draft.
    ///
    /// Through the same type the editor uses rather than straight to a
    /// `ScheduledTask`, so that a tap on a template card and a tap on Save in
    /// the editor take the identical path into the store — including the
    /// notification permission request and the reconcile that `AppModel` does
    /// around a save. A starter that wrote its own file, in v1, was scheduled
    /// correctly and never notified anybody.
    ///
    /// The whole point of routing a template through the editor rather than
    /// saving it on tap is that the two things a person wants to change before
    /// they own a routine — the hour and the days — are then in front of them.
    init(
        _ template: RoutineTemplate,
        time: TimeOfDay? = nil,
        weekdaysOnly: Bool = true,
        calendar: Calendar = .current
    ) {
        let task = template.task(time: time, weekdaysOnly: weekdaysOnly)
        self.init(
            id: nil,
            title: task.title,
            body: task.body,
            recurrence: task.recurrence,
            isEnabled: true,
            calendar: calendar
        )
        origin = template
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
        // the draft is on screen: it is what `sheet(item:)` matches on, and a
        // fresh UUID per comparison would present the editor again on every
        // redraw.
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

    /// A brand-new routine, with `createdAt` doing the job it was written for:
    /// `settledThrough` starts there, so a daily 09:00 routine created at 14:00
    /// is not instantly due for a morning that had already gone before it
    /// existed.
    ///
    /// Keeps `id` when the draft has one. That only happens for an edit whose
    /// task has disappeared underneath it — the Privacy screen's
    /// delete-everything, with this editor open — and writing it back under its
    /// original id is the difference between recovering the routine the user
    /// was working on and leaving a second copy of it behind.
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
    func apply(to task: inout ScheduledTask, now: Date = Date(), calendar: Calendar = .current) {
        let updated = recurrence(calendar: calendar)
        if task.recurrence != updated {
            task.settledThrough = max(task.settledThrough, now)
        }
        // Resuming a paused routine skips what it missed while it was off, for
        // the reason `RoutinesView.setEnabled` gives at length: a week's holiday
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

/// Creating or changing one routine.
///
/// The screen is arranged so that the sentence explaining what this app can and
/// cannot do sits directly under the control that decides it. That placement is
/// the whole design: the failure being avoided is somebody setting up a 7am
/// brief that needs the brain, receiving nothing useful for a week, and
/// concluding the app is broken. Finding out here, while choosing, costs
/// nothing; finding out a week later costs the feature.
///
/// A stack of cards rather than a `Form`, which is not only a restyle. The old
/// version's day picker had to be a pushed list because a `Form` row holding
/// seven chips silently refuses to deliver a touch to the one that was hit —
/// three implementations of that looked right and did nothing. The push is kept
/// anyway, because it is also the pattern the platform uses for exactly this
/// choice and because a full-width row is a target a thumb can hit.
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
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                nameCard
                workCard
                scheduleCard
                if draft.id != nil { enabledCard }
                if showsNotificationPrimer {
                    // The one permission this app ever asks for, said before it
                    // is asked. `AppModel.saveScheduledTask` requests it at the
                    // first routine and nowhere else, so this is the only
                    // screen that can warn anybody.
                    Callout(symbol: "bell", text: "Pocketd will ask to send notifications. Next, tap Allow.")
                }
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.top, PDSpacing.xs)
            .padding(.bottom, PDSpacing.l)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar
        }
        .pdCanvas()
        .navigationTitle(draft.id == nil ? "New routine" : "Edit routine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    // MARK: The way out

    private var saveBar: some View {
        VStack(spacing: PDSpacing.xs) {
            if let problem = blockingProblem {
                Text(problem)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.caution)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PrimaryButton(title: "Save routine", arrow: false, isEnabled: blockingProblem == nil) {
                save(draft)
                dismiss()
            }
        }
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.top, PDSpacing.s)
        .padding(.bottom, PDSpacing.xs)
        .background(Color.pd.canvas)
        // The hairline is what turns a clipped sentence into an edge. Without
        // it the form's last line is simply sliced by an invisible boundary
        // halfway through scrolling, which reads as a rendering fault rather
        // than as a bar.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.pd.divider)
                .frame(height: 1)
        }
    }

    private var blockingProblem: String? { contentProblem ?? scheduleProblem }

    /// Whether the save is about to trigger the permission prompt.
    ///
    /// Only for a routine that does not exist yet, and only when there are none
    /// — `saveScheduledTask` asks exactly once, at the first one.
    private var showsNotificationPrimer: Bool {
        draft.id == nil && model.scheduledTasks.isEmpty
    }

    // MARK: Name

    private var nameCard: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                SectionLabel("Name")
                TextField("Morning brief", text: $draft.title)
                    .font(Font.pd.body)
                    .foregroundStyle(Color.pd.ink)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, PDSpacing.s)
                    .frame(height: 44)
                    .background(
                        Color.pd.fillTile,
                        in: RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous)
                    )
                if let problem = contentProblem, draft.cleanTitle.isEmpty {
                    note(problem, isTrouble: true)
                } else {
                    note("What you will see on the notification.")
                }
            }
        }
    }

    // MARK: What it does

    private var workCard: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                SectionLabel("What it does")

                Picker("What it does", selection: $draft.kind) {
                    ForEach(ScheduleDraft.Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch draft.kind {
                case .rule:
                    row("Look at") {
                        Picker("Look at", selection: $draft.source) {
                            ForEach(ScheduleDraft.Source.allCases) { source in
                                Text(source.label).tag(source)
                            }
                        }
                        .labelsHidden()
                    }
                    divider
                    switch draft.source {
                    case .events:
                        row("Which") {
                            Picker("Which", selection: $draft.calendarRange) {
                                ForEach(CalendarRange.allCases, id: \.self) { range in
                                    Text(ScheduleWords.title(range)).tag(range)
                                }
                            }
                            .labelsHidden()
                        }
                    case .reminders:
                        row("Which") {
                            Picker("Which", selection: $draft.reminderFilter) {
                                ForEach(ReminderFilter.allCases, id: \.self) { filter in
                                    Text(ScheduleWords.title(filter)).tag(filter)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    divider
                    Toggle("Tell me even when there is nothing", isOn: $draft.notifyWhenEmpty)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                        .tint(Color.pd.accent)
                        .frame(minHeight: 44)

                case .model:
                    promptEditor
                }

                if let warning = accessWarning {
                    Callout(
                        symbol: "exclamationmark.triangle",
                        text: warning.sentence,
                        tint: .pd.caution,
                        fill: .pd.cautionSoft
                    ) {
                        if warning.offersAbilities {
                            LinkPill(title: "Open You", symbol: "arrow.right") {
                                dismiss()
                                goTo(.you)
                            }
                        }
                    }
                }

                // Directly under the choice. This is the honesty requirement,
                // and it is two sentences rather than a paragraph because a
                // paragraph nobody reads is not an explanation.
                note(ScheduleWords.explanation(needsModel: draft.kind == .model))
                if let problem = contentProblem, !draft.cleanTitle.isEmpty {
                    note(problem, isTrouble: true)
                }
            }
        }
    }

    /// The box the user writes the actual question in.
    ///
    /// A plain `TextField` collapses a paragraph into one scrolling line, and
    /// what goes here is a paragraph.
    private var promptEditor: some View {
        TextEditor(text: $draft.prompt)
            .font(Font.pd.body)
            .foregroundStyle(Color.pd.ink)
            .scrollContentBackground(.hidden)
            // Tall enough that the templates' own prompts — three sentences of
            // instruction, which is what makes a 1.7B model write something
            // worth reading — are visible without scrolling a box inside a
            // scroll view.
            .frame(minHeight: 156)
            .padding(PDSpacing.xs)
            .background(
                Color.pd.fillTile,
                in: RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous)
            )
            .overlay(alignment: .topLeading) {
                if draft.prompt.isEmpty {
                    Text("What should it work out for you?")
                        .font(Font.pd.body)
                        .foregroundStyle(Color.pd.inkTertiary)
                        .padding(.top, PDSpacing.m)
                        .padding(.leading, PDSpacing.s + 5)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: When

    private var scheduleCard: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                SectionLabel("When")

                row("Repeat") {
                    Picker("Repeat", selection: $draft.repeats) {
                        ForEach(ScheduleDraft.Repeats.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                divider

                switch draft.repeats {
                case .once:
                    // Bounded below by now: a one-shot in the past has no firing
                    // at all — `FireSequence.next` returns nothing for it — so it
                    // would save cleanly and then sit in the list forever saying
                    // "nothing further".
                    row("At") {
                        DatePicker(
                            "At",
                            selection: $draft.onceAt,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                    }
                case .daily:
                    timeRow
                case .weekly:
                    dayRow
                    divider
                    timeRow
                case .monthly:
                    row("Day of the month") {
                        Picker("Day of the month", selection: $draft.monthDay) {
                            ForEach(1...31, id: \.self) { day in
                                Text(ScheduleWords.ordinal(day)).tag(day)
                            }
                        }
                        .labelsHidden()
                    }
                    if draft.monthDay > 28 {
                        divider
                        // Only asked when it can happen. There is no default
                        // answer to "what does the 31st mean in February" that
                        // does not surprise somebody, which is why `ShortMonth`
                        // makes the caller say.
                        row("In shorter months") {
                            Picker("In shorter months", selection: $draft.whenShort) {
                                Text("Use the last day").tag(ShortMonth.lastDay)
                                Text("Skip that month").tag(ShortMonth.skip)
                            }
                            .labelsHidden()
                        }
                    }
                    divider
                    timeRow
                }

                if let problem = scheduleProblem {
                    note(problem, isTrouble: true)
                } else {
                    // The rule, resolved against the real calendar, as dates.
                    // This is the only way a user can tell that "monthly on the
                    // 31st, skipping shorter months" means a four-month gap —
                    // and it catches a daylight-saving or first-weekday mistake
                    // in the one place where it is still cheap to notice.
                    note(preview)
                }
            }
        }
    }

    private var timeRow: some View {
        row("At") {
            DatePicker("At", selection: $draft.time, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
    }

    /// The days, as a row that pushes a list rather than as a row of chips.
    ///
    /// A row of seven tappable chips was written three times in v1 — as
    /// `Button`s, then as `Toggle`s, then with a bare `onTapGesture` — and all
    /// three looked exactly right and did nothing at all inside a `Form` row.
    /// The push is kept: it is the pattern the platform uses for this choice
    /// (the Clock app's Repeat screen is seven rows with checkmarks) and a
    /// full-width row is a target a thumb can hit, unlike a 32-point chip.
    private var dayRow: some View {
        NavigationLink {
            DayPicker(days: $draft.days)
        } label: {
            HStack(spacing: PDSpacing.s) {
                Text("Days")
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                Spacer(minLength: PDSpacing.s)
                Text(ScheduleWords.weekdayPhrase(draft.days))
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.pd.inkTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PDPressStyle())
    }

    // MARK: Paused or not

    private var enabledCard: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                Toggle("Runs", isOn: $draft.isEnabled)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .tint(Color.pd.accent)
                    .frame(minHeight: 44)
                // Pausing rather than deleting is the state somebody wants for a
                // holiday, and the one a delete cannot express.
                note("A paused routine keeps its schedule and produces nothing until you switch it back on.")
            }
        }
    }

    // MARK: Row furniture

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: PDSpacing.s) {
            Text(title)
                .font(Font.pd.rowTitle)
                .foregroundStyle(Color.pd.ink)
            Spacer(minLength: PDSpacing.s)
            control()
                .tint(Color.pd.accent)
        }
        .frame(minHeight: 44)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.pd.divider)
            .frame(height: 1)
    }

    private func note(_ text: String, isTrouble: Bool = false) -> some View {
        Text(text)
            .font(Font.pd.secondary)
            .foregroundStyle(isTrouble ? Color.pd.caution : Color.pd.inkSecondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The schedule refusals, which exist because a routine that can never fire
    /// is indistinguishable, once saved, from one whose next firing is simply
    /// far away. `Recurrence.isFireable` is written for exactly this check.
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

    /// Whether the thing this routine reads is actually readable.
    ///
    /// A watcher over a calendar the app was never given is not a routine, it is
    /// a daily notification saying permission is off — and the person who would
    /// have to work that out is the one who set it up weeks earlier. Said here,
    /// while they are looking at the rule.
    ///
    /// Only for rules. A brain-written routine's tools are decided at run time
    /// by what is switched on then, and guessing which of them the sentence will
    /// reach for would put a specific, confident and possibly wrong warning on
    /// the screen.
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
/// Its own screen rather than an inline row of chips: see `dayRow`. One
/// full-width `Button` per row is the shape that actually receives a tap, and a
/// full-width row is a target a thumb can hit.
private struct DayPicker: View {
    @Binding var days: Set<Weekday>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                PDCard(padding: PDSpacing.xs) {
                    VStack(spacing: 0) {
                        // In the order this device shows a week, which
                        // `ScheduleWords` works out from `Calendar.firstWeekday`
                        // — Sunday in the US, Monday across most of Europe,
                        // Saturday in much of the Gulf.
                        ForEach(
                            Array(ScheduleWords.ordered(Set(Weekday.allCases)).enumerated()),
                            id: \.element
                        ) { index, day in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.pd.divider)
                                    .frame(height: 1)
                                    .padding(.leading, PDSpacing.s)
                            }
                            dayRow(day)
                        }
                    }
                }

                if days.isEmpty {
                    // The same refusal the editor shows, said where the mistake
                    // is being made. `Recurrence.isFireable` exists because a
                    // weekly rule with no days is indistinguishable, once saved,
                    // from one whose next firing is simply far away.
                    Text("Pick at least one day, or this will never run.")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.caution)
                } else {
                    Text(ScheduleWords.weekdayPhrase(days))
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.top, PDSpacing.xs)
            .padding(.bottom, PDSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .pdCanvas()
        .navigationTitle("Days")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dayRow(_ day: Weekday) -> some View {
        Button {
            Haptics.tap()
            if days.contains(day) {
                days.remove(day)
            } else {
                days.insert(day)
            }
        } label: {
            HStack(spacing: PDSpacing.s) {
                Text(ScheduleWords.fullName(day))
                    .font(Font.pd.body)
                    .foregroundStyle(Color.pd.ink)
                Spacer(minLength: PDSpacing.s)
                if days.contains(day) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.pd.accent)
                }
            }
            .padding(.horizontal, PDSpacing.s)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(ScheduleWords.fullName(day))
        .accessibilityValue(days.contains(day) ? "On" : "Off")
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
    /// The raw values are snake_case because they are what the brain literally
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

// MARK: - Previews

#Preview("Editor light") {
    NavigationStack {
        ScheduleEditorView(draft: ScheduleDraft(.morningBrief)) { _ in }
    }
    .environment(AppModel())
}

#Preview("Editor dark") {
    NavigationStack {
        ScheduleEditorView(draft: ScheduleDraft(.overdueWatcher)) { _ in }
    }
    .environment(AppModel())
    .preferredColorScheme(.dark)
}
