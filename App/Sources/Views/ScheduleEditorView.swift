import PocketdKit
import SwiftUI

// MARK: - The editor

/// Creating or changing one routine.
///
/// The first screen is what an alarm asks for — a name, a time, the days — and
/// one grey sentence saying what the routine will do. Everything else (how it
/// repeats, what it does, the question it asks) is under More options, because
/// the templates already chose it and a person editing a morning brief came to
/// move it to 7:45, not to read a prompt.
///
/// The model is `RoutineDraft`, in the Kit and tested. It used to be a struct
/// in this file whose `==` compared identity alone, and SwiftUI uses `==` to
/// decide whether a `@State` write changed anything — so nothing typed here
/// ever registered, and no routine could be made from scratch.
///
/// A stack of cards in a `ScrollView`, not a `Form`. The day chips are why: a
/// `Form` row holding seven buttons delivers a touch to none of them, which v1
/// found three times over. In a plain stack each chip is its own button with a
/// full-height target.
struct ScheduleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: RoutineDraft
    @State private var showsMore: Bool
    @State private var saving = false
    @State private var saveFailed = false
    @State private var confirmingDelete = false
    /// Whether iOS has never been asked about notifications, which is when a
    /// save is about to raise its sheet and the primer has something to say.
    @State private var notificationsUndecided = false
    /// What the connect door said, when it did not connect.
    @State private var connectNote: String?
    /// Re-reads the access warning after the connect door returns: the grant
    /// it reads is iOS's, which nothing here observes.
    @State private var grantGeneration = 0

    init(draft: RoutineDraft) {
        _draft = State(initialValue: draft)
        // Open when there is something under it that has to be filled in — a
        // question with no words yet — and closed for everything a template
        // already decided.
        _showsMore = State(initialValue: draft.kind == .ask && draft.prompt.isEmpty)
    }

    private var isNew: Bool { draft.taskID == nil || !model.scheduledTasks.contains { $0.id == draft.taskID } }

    /// Whether this Save is Pocketd Pro: a new routine here is Custom, and a
    /// free routine turned into something else is Custom the long way round.
    /// Changing the time, days or name of any routine — including one made
    /// before Pro — never is. The rule is the Kit's (`routineNeedsPro`).
    private var saveNeedsPro: Bool {
        let original = model.scheduledTasks.first { $0.id == draft.taskID }
        return ProAccess.routineNeedsPro(saving: draft.work, replacing: original?.body)
    }

    private var problem: String? { draft.problem() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                basicsCard
                Text(ScheduleWords.purpose(of: draft))
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PDSpacing.xxs)
                if let access = accessWarning {
                    accessCard(access)
                }
                moreOptions
                if !isNew {
                    deleteButton
                }
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.top, PDSpacing.xs)
            .padding(.bottom, PDSpacing.l)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .pdCanvas()
        .navigationTitle(isNew ? "New routine" : "Edit routine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .confirmationDialog(
            "Delete \(draft.cleanTitle.isEmpty ? "this routine" : draft.cleanTitle)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Explicit that the history goes with it: the runs are the only
            // record of what the phone said on those mornings.
            Text("Everything it has told you goes with it.")
        }
        .task {
            notificationsUndecided = await NotificationCentre.shared.authorizationStatus() == .notDetermined
        }
    }

    // MARK: Name, time, days

    private var basicsCard: some View {
        PDCard(padding: PDSpacing.m) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                TextField("Name", text: $draft.title)
                    .font(Font.pd.headline)
                    .foregroundStyle(Color.pd.ink)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .padding(.horizontal, PDSpacing.s)
                    .frame(minHeight: PDMetric.minHitTarget)
                    .background(
                        Color.pd.fillTile,
                        in: RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous)
                    )
                    .accessibilityLabel("Name")

                divider

                switch draft.repeats {
                case .once:
                    // Bounded below by now: a one-shot in the past has no
                    // firing at all, so it would save and then sit in the list
                    // forever doing nothing.
                    row("Time") {
                        DatePicker(
                            "Time",
                            selection: $draft.onceAt,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                    }
                case .weekly, .monthly:
                    row("Time") {
                        DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }

                if draft.repeats == .weekly {
                    divider
                    dayChips
                }
            }
        }
    }

    /// Seven chips in the order this phone shows a week.
    ///
    /// Inline rather than a pushed list (spec §3.4), and safe here because
    /// this is a stack and not a `Form` — see the type's note. Each chip takes
    /// a seventh of the row and at least 44 points of height, so the target is
    /// the whole column even where the circle is smaller.
    private var dayChips: some View {
        HStack(spacing: PDSpacing.xxs) {
            ForEach(ScheduleWords.ordered(Set(Weekday.allCases)), id: \.self) { day in
                let isOn = draft.days.contains(day)
                Button {
                    Haptics.tap()
                    draft.toggle(day)
                } label: {
                    Text(ScheduleWords.initial(day))
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(isOn ? Color.pd.onPrimary : Color.pd.ink)
                        .frame(width: 38, height: 38)
                        .background(isOn ? Color.pd.primaryButton : Color.pd.fillTile, in: Circle())
                        .frame(maxWidth: .infinity, minHeight: PDMetric.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PDPressStyle())
                .accessibilityLabel(ScheduleWords.fullName(day))
                .accessibilityValue(isOn ? "On" : "Off")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        // Seven chips have to share one row at every text size, so the
        // letters stop growing at xLarge, the size that still sits inside a
        // 38pt circle. They are single letters with the full day name for
        // VoiceOver, the way a tab bar's glyphs are capped and labelled.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days")
    }

    // MARK: More options

    private var moreOptions: some View {
        PDCard(padding: PDSpacing.m) {
            DisclosureGroup(isExpanded: $showsMore) {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    divider.padding(.top, PDSpacing.xs)
                    repeatRows
                    divider
                    kindRows
                }
            } label: {
                Text("More options")
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .frame(maxWidth: .infinity, minHeight: PDMetric.minHitTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .tint(Color.pd.inkSecondary)
        }
    }

    @ViewBuilder
    private var repeatRows: some View {
        row("Repeat") {
            Picker("Repeat", selection: $draft.repeats) {
                ForEach(RoutineDraft.Repeats.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
        }
        if draft.repeats == .monthly {
            divider
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
                // Only asked when it can happen. There is no default answer to
                // "what does the 31st mean in February" that does not surprise
                // somebody, which is why `ShortMonth` makes the caller say.
                row("In shorter months") {
                    Picker("In shorter months", selection: $draft.whenShort) {
                        Text("Use the last day").tag(ShortMonth.lastDay)
                        Text("Skip that month").tag(ShortMonth.skip)
                    }
                    .labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private var kindRows: some View {
        row("What it does") {
            Picker("What it does", selection: $draft.kind) {
                ForEach(RoutineDraft.Kind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
        }
        switch draft.kind {
        case .brief:
            EmptyView()
        case .rule:
            divider
            row("Look at") {
                Picker("Look at", selection: $draft.source) {
                    ForEach(RoutineDraft.Source.allCases) { source in
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
                .frame(minHeight: PDMetric.minHitTarget)
        case .ask:
            divider
            questionEditor
        }
    }

    /// The question, in the person's own words.
    ///
    /// A `TextEditor` because a question can be a sentence or two. The
    /// placeholder is drawn only while the text is empty — which it now
    /// actually is only while nothing has been typed; see the type's note.
    private var questionEditor: some View {
        TextEditor(text: $draft.prompt)
            .font(Font.pd.body)
            .foregroundStyle(Color.pd.ink)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
            .padding(PDSpacing.xs)
            .background(
                Color.pd.fillTile,
                in: RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous)
            )
            .overlay(alignment: .topLeading) {
                if draft.prompt.isEmpty {
                    Text("What should Pocketd tell you?")
                        .font(Font.pd.body)
                        .foregroundStyle(Color.pd.inkTertiary)
                        .padding(.top, PDSpacing.s + 4)
                        .padding(.leading, PDSpacing.s + 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Question")
    }

    // MARK: Delete

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            Text("Delete routine")
                .font(Font.pd.rowTitle)
                .foregroundStyle(Color.pd.danger)
                .frame(maxWidth: .infinity, minHeight: PDMetric.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PDPressStyle())
        .padding(.top, PDSpacing.xs)
    }

    private func delete() {
        guard let id = draft.taskID else { return }
        Task {
            await model.deleteScheduledTask(id)
            Haptics.success()
            dismiss()
        }
    }

    // MARK: The way out

    private var saveBar: some View {
        VStack(spacing: PDSpacing.xs) {
            if saveFailed {
                // Kept on this screen rather than reported on the list: the
                // person's edit is still here, and a second tap may well work.
                Text("That couldn't be saved. This iPhone may be out of space.")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.caution)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem {
                // The one reason Save is off, said once, where the button is.
                Text(problem)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if notificationsUndecided {
                Primer("Next, tap **Allow** so Pocketd can tell you when it's ready.", symbol: "bell")
            }
            ProGateReader { proGate in
                PrimaryButton(title: "Save", arrow: false, isLoading: saving, isEnabled: problem == nil && !saving) {
                    if saveNeedsPro {
                        proGate(.routines) { save() }
                    } else {
                        save()
                    }
                }
            }
        }
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.top, PDSpacing.s)
        .padding(.bottom, PDSpacing.xs)
        .background(Color.pd.canvas.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.pd.divider)
                .frame(height: 1)
        }
    }

    private func save() {
        guard problem == nil, !saving else { return }
        saving = true
        saveFailed = false
        let edit = draft
        Task {
            let saved = await model.saveRoutine(edit)
            saving = false
            if saved {
                Haptics.success()
                dismiss()
            } else {
                saveFailed = true
            }
        }
    }

    // MARK: What a check needs to read

    private struct AccessWarning {
        let ability: Ability
        let sentence: String
        /// The verb on the one button, or nil when nothing on this phone can
        /// change it (Screen Time, a profile).
        let action: String?
    }

    /// Whether the thing a check reads is actually readable.
    ///
    /// A check over a calendar iOS never granted is not a routine; it is a
    /// daily notification saying permission is off, discovered by the person
    /// who set it up weeks earlier. Said here, while they are looking at it,
    /// with the one door that fixes it.
    ///
    /// Only for checks, and only about iOS: a check reads with its own standing
    /// instruction rather than through the switches the brain is handed (see
    /// `ScheduleRunner`), so iOS's answer is the whole question.
    private var accessWarning: AccessWarning? {
        _ = grantGeneration
        guard draft.kind == .rule else { return nil }
        let ability: Ability = draft.source == .events ? .calendar : .reminders
        let name = ability.title
        switch model.standingGrant(for: ability) {
        case .granted, .neverReported, .inProgress, .unavailable:
            return nil
        case .notAsked, .failed:
            return AccessWarning(ability: ability, sentence: "Pocketd can't read your \(name.lowercased()) yet.", action: "Turn on")
        case .addOnly:
            return AccessWarning(
                ability: ability,
                sentence: "Pocketd can add to your \(name.lowercased()) but not read it.",
                action: "Turn on"
            )
        case .refused:
            return AccessWarning(ability: ability, sentence: "\(name) is off in iOS Settings.", action: "Open Settings")
        case .restricted:
            return AccessWarning(ability: ability, sentence: "\(name) is blocked on this iPhone.", action: nil)
        }
    }

    /// One sentence and one action (spec §1.7), through the one connect door:
    /// it sets the switch, asks iOS where iOS can still be asked, and opens
    /// Settings where it cannot.
    private func accessCard(_ warning: AccessWarning) -> some View {
        NoticeCard(
            symbol: "exclamationmark.triangle",
            tint: .pd.caution,
            text: connectNote ?? warning.sentence,
            linkTitle: warning.action,
            action: warning.action == nil ? nil : {
                Task {
                    let outcome = await model.connect(warning.ability, from: .settings)
                    connectNote = outcome.sentence(for: warning.ability)
                    grantGeneration += 1
                }
            }
        )
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
        .frame(minHeight: PDMetric.minHitTarget)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.pd.divider)
            .frame(height: 1)
    }
}

// MARK: - The words only the editor needs

extension ScheduleWords {
    /// "Monday", in the user's language, for VoiceOver on a day chip.
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
        ScheduleEditorView(draft: RoutineDraft(.morningBrief))
    }
    .environment(AppModel())
}

#Preview("Editor dark") {
    NavigationStack {
        ScheduleEditorView(draft: RoutineDraft(.overdueWatcher))
    }
    .environment(AppModel())
    .preferredColorScheme(.dark)
}
