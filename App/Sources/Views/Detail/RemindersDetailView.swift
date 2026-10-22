import PocketdKit
import SwiftUI

/// Reminders: what slipped, what is due today, and the rest of the list.
///
/// Behind the Due tile. Grouped by the Kit's `ReminderAgenda`, with the same
/// overdue rule the tile and the brief use (`DueSplit`), so "1 overdue" on
/// Today is one row under OVERDUE here.
///
/// The circles tick reminders off. That is a write to the person's own list,
/// made by the person's own tap, so it happens at once and the toast offers
/// Undo — which un-ticks, never deletes (`ReminderCompletion`). Priority is a
/// single amber "!" or nothing: EventKit's scale runs backwards ("9" is the
/// lowest), and "P1" is a code to decode rather than a mark that means "this
/// one matters".
struct RemindersDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var agenda: ReminderAgenda?
    /// Ticked here and still on screen, showing their filled circle.
    @State private var ticking: Set<String> = []
    /// Ticked off and gone from the page, until the next reading drops them
    /// for real.
    @State private var gone: Set<String> = []
    @State private var expanded: Set<ReminderAgenda.Group> = []

    private var reads = true

    /// Rows a group shows before "Show N more". More than Your day's two: a
    /// reminder is one line and the point of this page is the list.
    static let rowsPerGroup = 5

    /// How long a filled circle stays before its row leaves: long enough to
    /// see that the tap landed.
    private static let tickPause: Duration = .milliseconds(450)

    init() {}

    /// A page with its list already read, for previews.
    init(agenda: ReminderAgenda) {
        _agenda = State(initialValue: agenda)
        reads = false
    }

    var body: some View {
        DetailPage(
            title: "Reminders",
            summary: agenda?.summary,
            composer: PageQuestion.composer(
                agenda?.suggestion ?? "Remind me to…",
                navigator: navigator,
                model: model
            )
        ) {
            if let agenda {
                content(agenda)
            }
        }
        .refreshable { await read() }
        .task(id: model.briefing.snapshot) { await read() }
        // Read and left: one useful answer for the review gate, when the page
        // showed something of the person's own. See `ReviewMoment`.
        .onDisappear { if agenda?.reportsSomething == true { model.noteUsefulAnswer() } }
    }

    private func read() async {
        guard reads else { return }
        let fresh = await model.reminderAgenda()
        // A tick re-reads the day the moment it lands, which re-reads this
        // page — and the row would vanish before its filled circle had been
        // seen. The tick reads again itself once its beat is over.
        guard ticking.isEmpty else { return }
        agenda = fresh
        // What the store no longer has is gone for real now; what it still
        // has came back (an Undo, or a tick that did not land) and shows.
        gone = []
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ agenda: ReminderAgenda) -> some View {
        if !agenda.availability.isReadable {
            ConnectSourceLink(ability: .reminders, availability: agenda.availability)
        } else {
            ForEach(agenda.sections) { section in
                let rows = section.reminders.filter { !gone.contains($0.id) }
                if !rows.isEmpty {
                    PageSection(section.group.title) {
                        let isOpen = expanded.contains(section.group)
                        let hidden = max(0, rows.count - Self.rowsPerGroup)
                        RowCard(isOpen ? rows : Array(rows.prefix(Self.rowsPerGroup))) { reminder in
                            ReminderRow(
                                reminder: reminder,
                                group: section.group,
                                isTicked: ticking.contains(reminder.id)
                            ) {
                                tick(reminder)
                            }
                        } footer: {
                            if hidden > 0 {
                                ShowMoreButton(hiddenCount: hidden, isExpanded: isOpen) {
                                    toggle(section.group)
                                }
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func toggle(_ group: ReminderAgenda.Group) {
        withAnimation(reduceMotion ? nil : PDMotion.standard) {
            if expanded.contains(group) {
                expanded.remove(group)
            } else {
                expanded.insert(group)
            }
        }
    }

    // MARK: - Ticking off

    private func tick(_ reminder: DayReminder) {
        guard reads, !ticking.contains(reminder.id) else { return }
        Haptics.success()
        withAnimation(reduceMotion ? nil : PDMotion.gentle) {
            _ = ticking.insert(reminder.id)
        }
        Task {
            let started = ContinuousClock.now
            let completion = await model.completeReminder(id: reminder.id, title: reminder.title)
            // The circle stays filled for a beat even when the store answered
            // at once, or the row vanishes before anyone sees why.
            let waited = started.duration(to: .now)
            if waited < Self.tickPause {
                try? await Task.sleep(for: Self.tickPause - waited)
            }
            withAnimation(reduceMotion ? nil : PDMotion.standard) {
                ticking.remove(reminder.id)
                if completion != nil { gone.insert(reminder.id) }
            }
            if let completion {
                toasts.show(
                    completion.sentence,
                    symbol: "checkmark.circle",
                    tint: .pd.positive,
                    action: ToastAction(title: "Undo") { undo(completion) }
                )
            } else {
                Haptics.warning()
                toasts.show(
                    "Pocketd couldn't tick that off. Try again.",
                    symbol: "exclamationmark.circle",
                    tint: .pd.caution
                )
            }
            await read()
        }
    }

    private func undo(_ completion: ReminderCompletion) {
        Task {
            if await model.undoCompletion(completion) {
                toasts.show(completion.undoneSentence, symbol: "arrow.uturn.backward")
            } else {
                toasts.show(
                    "That one can't be undone now. It's ticked off in Reminders.",
                    symbol: "exclamationmark.circle",
                    tint: .pd.caution
                )
            }
            await read()
        }
    }
}

// MARK: - A row

/// ○  ! Call the plumber                  5:00 PM
///
/// The circle is the only part that ticks: a tap on the words is far too easy
/// to make by accident for something that changes the person's own list.
/// VoiceOver gets the whole row as one element whose action is the tick.
private struct ReminderRow: View {
    let reminder: DayReminder
    let group: ReminderAgenda.Group
    let isTicked: Bool
    let onTick: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var now: Date { DemoClock.now }

    /// The right-hand column. A time for anything with one today; the day
    /// otherwise; nothing for a date-only reminder in TODAY, whose group label
    /// already says it.
    private var due: String? {
        if group == .today, !reminder.dueHasTime { return nil }
        return reminder.dueText(now: now)
    }

    /// Whether the column holds a time — the one thing set in mono, so a
    /// column of them lines up. "Yesterday", "Tomorrow" and "Fri 2 Oct" are
    /// words, and a word in mono is a word in costume.
    private var dueIsTime: Bool {
        guard reminder.dueHasTime, let date = reminder.due else { return false }
        return Calendar.current.isDate(date, inSameDayAs: now)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xxs) {
            Button(action: onTick) {
                Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                    .font(Font.pd.lead)
                    .foregroundStyle(isTicked ? Color.pd.positive : Color.pd.inkTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .pdHitTarget()
            }
            .buttonStyle(PDPressStyle())
            // The 44pt target overhangs the card's padding on the left and
            // the gap between rows above and below, rather than pushing the
            // circle away from its words and every row taller.
            .padding(.leading, -PDSpacing.xs - 2)
            .padding(.vertical, -PDSpacing.xs - 2)
            .disabled(isTicked)
            .accessibilityHidden(true)

            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    if let due { dueText(due) }
                }
            } else {
                title
                Spacer(minLength: PDSpacing.xs)
                if let due {
                    dueText(due).layoutPriority(1)
                }
            }
        }
        .opacity(isTicked ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(spokenDue)
        .accessibilityHint("Ticks it off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTick() }
    }

    private var title: some View {
        Group {
            if reminder.priorityMark != nil {
                Text("\(Text("!").foregroundStyle(Color.pd.caution).fontWeight(.bold))\u{00A0}\(reminder.title)")
            } else {
                Text(reminder.title)
            }
        }
        .font(Font.pd.body)
        .foregroundStyle(Color.pd.ink)
        .strikethrough(isTicked, color: Color.pd.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func dueText(_ text: String) -> some View {
        Text(text)
            .font(dueIsTime ? Font.pd.monoValue : Font.pd.secondary)
            .foregroundStyle(group == .overdue ? Color.pd.caution : Color.pd.inkSecondary)
            .lineLimit(1)
    }

    private var spokenTitle: String {
        reminder.priorityMark == nil ? reminder.title : "\(reminder.title), high priority"
    }

    private var spokenDue: String {
        let when = reminder.dueText(now: now)
        switch group {
        case .overdue: return when.map { "Overdue, due \($0)" } ?? "Overdue"
        case .today: return reminder.dueHasTime ? (when.map { "Due today at \($0)" } ?? "Due today") : "Due today"
        case .later: return when.map { "Due \($0)" } ?? "No date"
        }
    }
}

// MARK: - Previews

#Preview("Reminders light") {
    NavigationStack {
        RemindersDetailView(agenda: DetailPreviewData.reminders)
    }
    .detailPreviewEnvironment()
}

#Preview("Reminders dark") {
    NavigationStack {
        RemindersDetailView(agenda: DetailPreviewData.reminders)
    }
    .detailPreviewEnvironment()
    .preferredColorScheme(.dark)
}

#Preview("Reminders AX") {
    NavigationStack {
        RemindersDetailView(agenda: DetailPreviewData.reminders)
    }
    .detailPreviewEnvironment()
    .dynamicTypeSize(.accessibility3)
}
