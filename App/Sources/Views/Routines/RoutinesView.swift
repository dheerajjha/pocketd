import PocketdKit
import SwiftUI

/// Everything this phone does on its own, and what it last said.
///
/// v1 called these scheduled tasks and reached them through a bar above the tab
/// bar; they are a tab now, and the rename is the design. "Scheduled task" is
/// what the type is; "routine" is what a person is buying — something that
/// happens without them, on their phone, at a time they chose.
///
/// The screen answers three questions, top to bottom, in the order somebody
/// opening it actually has them: *is something waiting for me* (the results
/// row, which is the one fact about this feature nobody can discover on their
/// own), *is this working* (a card per routine with its next firing and what it
/// last said), and *what else could it do* (the templates grid, which is the
/// answer to an empty screen that an empty form is not).
///
/// It is a `List` rather than a `ScrollView` of cards, and that is a decision
/// about one gesture: swipe to delete. Every hand-rolled version of that inside
/// a `ScrollView` competes with the scroll for the same drag, and the failure
/// is a card that will not move or a page that will not scroll. The rows are
/// cards anyway — clear backgrounds, no separators, the page gutter as the row
/// inset — so the list is doing nothing here but carrying the swipe.
struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts

    @State private var editing: ScheduleDraft?
    @State private var showingResult: ScheduledTask?
    @State private var deleting: ScheduledTask?

    /// Whether the store has been read since this screen appeared.
    ///
    /// Distinct from "there are no routines", and the distinction is visible:
    /// the empty hero and the templates grid both describe a phone with nothing
    /// scheduled, and showing either for the frame before the list has been
    /// read makes a phone with four routines on it look like a fresh install —
    /// and, worse, offers to add one the person already has.
    @State private var hasLoaded = false

    /// Set when a save did not reach the disk. See `save(_:)`.
    @State private var saveFailed = false

    private var tasks: [ScheduledTask] { model.scheduledTasks }

    private var waiting: [(task: ScheduledTask, run: TaskRun)] {
        ScheduleSummary.pending(in: tasks)
    }

    /// The templates not already in use, in the order they are declared.
    ///
    /// Gated on `hasLoaded` for the reason above. Matched by title rather than
    /// by a stored provenance — see `RoutineTemplate.matching(_:)` — so a
    /// renamed routine reappears on the grid, which is right: the person is
    /// looking at a card for something they no longer have under that name.
    private var offeredTemplates: [RoutineTemplate] {
        guard hasLoaded else { return [] }
        return RoutineTemplate.offered.filter { template in
            !tasks.contains { $0.title.caseInsensitiveCompare(template.title) == .orderedSame }
        }
    }

    var body: some View {
        List {
            header
                .pdRoutineRow(0)

            if saveFailed {
                // Above everything, because the list underneath it is not what
                // the person just asked for and nothing else on screen admits
                // that.
                Callout(
                    symbol: "exclamationmark.triangle",
                    text: "That could not be saved. This phone may be out of space.",
                    tint: .pd.caution,
                    fill: .pd.cautionSoft
                )
                .pdRoutineRow(1)
            }

            if !waiting.isEmpty {
                resultsCard
                    .pdRoutineRow(1)
            }

            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                RoutineCard(
                    task: task,
                    edit: { editing = ScheduleDraft(task) },
                    openResult: { showingResult = task },
                    setEnabled: { enabled in Task { await setEnabled(enabled, task) } }
                )
                .pdRoutineRow(index + 2)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = task } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            if tasks.isEmpty, hasLoaded {
                emptyHero
                    .pdRoutineRow(1)
            }

            if !offeredTemplates.isEmpty {
                templatesSection
                    .pdRoutineRow(tasks.isEmpty ? 2 : tasks.count + 2)
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        // The floating bar's space, as safe area on the list rather than as
        // padding: the page keeps scrolling under the capsule, and the last row
        // still comes out from under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: PDMetric.tabBarClearance)
        }
        .scrollContentBackground(.hidden)
        // Wash first, canvas second, and the order is the whole effect.
        // `background` puts each new layer *behind* the last, so applying the
        // flat canvas afterwards paints it over the gradient.
        .pdHeroWash()
        .pdCanvas()
        .sheet(item: $editing) { draft in
            NavigationStack {
                ScheduleEditorView(draft: draft, goTo: { navigator.go($0) }) { edited in
                    Task { await save(edited) }
                }
            }
        }
        .sheet(item: $showingResult) { task in
            // Re-read from the list rather than rendering the captured copy: a
            // sweep can settle a run while this sheet is open, and the sheet is
            // the one place somebody is looking at exactly that.
            RoutineResultSheet(task: tasks.first { $0.id == task.id } ?? task)
        }
        .confirmationDialog(
            "Delete this routine?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleting {
                    Task { await model.deleteScheduledTask(target.id) }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            // Named, and explicit that the history goes with it: the runs are
            // the only record of what the phone read on those mornings, and
            // nothing else in the app keeps a copy.
            Text(deleting.map { "\($0.title) and everything it has reported will be removed." } ?? "")
        }
        // `AppModel` reads the store at launch and again after every sweep, so
        // this is a catch-up rather than the only load: a background refresh
        // settles runs into these files while the app is closed, and the sweep
        // that notices happens on the way back to `.active`, which can be after
        // this tab is already on screen.
        .task {
            await model.loadScheduledTasks()
            hasLoaded = true
        }
    }

    // MARK: - The top of the page

    private var header: some View {
        HStack(alignment: .center, spacing: PDSpacing.m) {
            Text("Routines")
                .pdTitle()
                .foregroundStyle(Color.pd.ink)
            Spacer(minLength: 0)
            CircleIconButton(symbol: "plus", label: "New routine") {
                editing = ScheduleDraft()
            }
        }
        .padding(.top, PDSpacing.xs)
        .padding(.bottom, PDSpacing.xs)
    }

    // MARK: - Promises not yet kept

    /// Prompt routines that came due where no brain could run.
    ///
    /// The honest face of the constraint the whole feature is built on, and it
    /// appears only when the constraint has actually bitten: the notification
    /// fired on time, the thinking did not happen, and the app is now open,
    /// which is the state that can fix it. The failure it exists to prevent is
    /// somebody who set a 7am brief, was notified at 7am with nothing useful in
    /// it, and has no idea the app is waiting on them.
    private var resultsCard: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                HStack(alignment: .top, spacing: PDSpacing.s) {
                    IconTile.small("tray.full", fill: .pd.cautionSoft, tint: .pd.caution)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(waitingTitle)
                            .font(Font.pd.headline)
                            .foregroundStyle(Color.pd.ink)
                        Text(ScheduleWords.waitingFooter(hasModel: model.loadedModelID != nil))
                            .font(Font.pd.secondary)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                waitingActions
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var waitingTitle: String {
        waiting.count == 1 ? "1 brief ready to write" : "\(waiting.count) briefs ready to write"
    }

    @ViewBuilder
    private var waitingActions: some View {
        if model.isLoadingModel {
            // Loading is a transition, not a fault. Sending somebody to choose
            // a brain to fix something that is in the middle of fixing itself
            // is the mistake this app takes care not to make about a server
            // that is restarting.
            Text("A brain is still loading.")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
        } else if model.loadedModelID == nil {
            // The remedy, not a complaint. A waiting prompt routine with no
            // brain loaded files a failed run the moment anything sweeps, and
            // there is no way to guess that from a screen about routines.
            PillButton(title: "Choose a brain", symbol: "brain") {
                navigator.openYou(.brain)
            }
        } else {
            HStack(spacing: PDSpacing.xs) {
                PillButton(title: "Write them now", symbol: "pencil.line") {
                    model.writePendingResults()
                    toasts.show("Writing now", symbol: "pencil.line")
                }
                if !model.deskMode {
                    PillButton(title: "Desk mode", symbol: "display") {
                        model.deskMode = true
                    }
                }
            }
        }
    }

    // MARK: - Nothing here yet

    private var emptyHero: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            Text("Let it work\nwhile you don’t.")
                .pdHero()
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick a routine. It runs on this phone at the time you choose.")
                .pdSubtitle()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PDSpacing.xs)
        .padding(.bottom, PDSpacing.xs)
    }

    // MARK: - What else it could do

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            if !tasks.isEmpty {
                SectionLabel("More routines")
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: PDSpacing.tileGap),
                    GridItem(.flexible(), spacing: PDSpacing.tileGap),
                ],
                spacing: PDSpacing.tileGap
            ) {
                ForEach(offeredTemplates, id: \.self) { template in
                    TemplateCard(template: template) {
                        // The editor, prefilled, rather than a silent save. The
                        // time and the days are the two things somebody wants
                        // to change about a routine before they have one, and a
                        // card that saves on tap makes them find it, open it
                        // and edit it instead.
                        editing = ScheduleDraft(template)
                    }
                }
            }
            Text(ScheduleWords.listFooter)
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, PDSpacing.xxs)
        }
    }

    // MARK: - Writing

    /// Saves through `AppModel`, and notices when that did not work.
    ///
    /// `AppModel.saveScheduledTask` swallows the write error — `try?` around a
    /// file write that a full disk makes throw — and then reloads the list, so
    /// the only observable difference between a saved routine and a failed one
    /// is whether the card comes back. Worth checking for a new routine, where
    /// the failure is total and silent: somebody fills in the editor, taps
    /// Save, and lands on a list that does not contain what they just made.
    private func save(_ draft: ScheduleDraft) async {
        var task: ScheduledTask
        let isNew = draft.id == nil || !tasks.contains { $0.id == draft.id }
        if let id = draft.id, let existing = tasks.first(where: { $0.id == id }) {
            // Built on the copy the list holds rather than on the one the
            // editor opened with. A background refresh settles runs into the
            // same file while the editor is open, and `saveScheduledTask`
            // writes the whole task; starting from a stale snapshot puts a hole
            // in the history.
            task = existing
            draft.apply(to: &task)
        } else {
            // An edit whose task went missing — the Privacy screen's delete
            // everything, while this editor was open — is written back under
            // its original id rather than as a new one.
            task = draft.newTask()
        }
        await model.saveScheduledTask(task)
        saveFailed = !tasks.contains { $0.id == task.id }
        guard !saveFailed else { return }
        if isNew {
            // Recorded here rather than in `createRoutine`, because this is the
            // path a template actually takes: the grid opens the editor and the
            // routine does not exist until Save. `origin` is nil for the plus
            // button, which is what `.custom` is for — and what makes the
            // number worth reading. See `RoutineOrigin`.
            model.record(.routineCreated(template: draft.origin?.origin ?? .custom))
            toasts.show("Routine saved", symbol: "checkmark.circle")
        }
    }

    private func setEnabled(_ enabled: Bool, _ task: ScheduledTask, now: Date = Date()) async {
        var updated = task
        updated.isEnabled = enabled
        if enabled {
            // Resuming skips what was missed while it was off. A daily 09:00
            // routine switched off for a week's holiday and switched back on at
            // 14:00 has seven unsettled firings behind it, the most recent
            // being this morning's — so without this the reward for coming home
            // is an immediate notification about a brief that was due five
            // hours ago. `ScheduledTask.settledThrough` makes exactly this
            // argument for newly created tasks; a resume is the same moment.
            updated.settledThrough = max(updated.settledThrough, now)
        }
        updated.updatedAt = now
        await model.saveScheduledTask(updated)
    }
}

// MARK: - One routine

/// A routine as a card: what it is, when it next runs, what it last said.
///
/// Its own view rather than a method on the screen so that the `Toggle`'s
/// binding, which is the only piece of state a card owns, cannot be rebuilt
/// from a different task on every redraw of the list.
private struct RoutineCard: View {
    let task: ScheduledTask
    let edit: () -> Void
    let openResult: () -> Void
    let setEnabled: (Bool) -> Void

    private var dueness: Dueness { task.dueness() }

    private var symbol: String {
        RoutineTemplate.matching(task)?.symbolName ?? "clock"
    }

    private var lastResult: (text: String, isTrouble: Bool)? {
        guard let run = task.lastCompletedRun else { return nil }
        let summary = ScheduleWords.summary(of: run, in: task)
        return (ScheduleWords.preview(of: summary.text), summary.isTrouble)
    }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                HStack(alignment: .top, spacing: PDSpacing.s) {
                    // The title block is the tap target for the editor, and the
                    // toggle is beside it rather than inside it: a card that is
                    // one big button with a switch in the corner is a card
                    // where half the taps on the switch open the editor.
                    Button(action: edit) {
                        HStack(alignment: .top, spacing: PDSpacing.s) {
                            IconTile.small(symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(Font.pd.headline)
                                    .foregroundStyle(task.isEnabled ? Color.pd.ink : Color.pd.inkSecondary)
                                    .multilineTextAlignment(.leading)
                                Text(ScheduleWords.recurrence(task.recurrence))
                                    .font(Font.pd.secondary)
                                    .foregroundStyle(Color.pd.inkSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PDPressStyle())
                    .accessibilityLabel("\(task.title). \(ScheduleWords.recurrence(task.recurrence))")
                    .accessibilityHint("Opens the editor")

                    Toggle(
                        "",
                        isOn: Binding(get: { task.isEnabled }, set: setEnabled)
                    )
                    .labelsHidden()
                    .tint(Color.pd.accent)
                    .accessibilityLabel("\(task.title) runs")
                }

                nextRow

                if let lastResult {
                    Button(action: openResult) {
                        HStack(alignment: .top, spacing: PDSpacing.xs) {
                            Text(lastResult.text)
                                .font(Font.pd.secondary)
                                .foregroundStyle(lastResult.isTrouble ? Color.pd.caution : Color.pd.inkSecondary)
                                .lineSpacing(4)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.pd.inkTertiary)
                                .padding(.top, 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PDPressStyle())
                    .accessibilityLabel("Last result. \(lastResult.text)")
                    .accessibilityHint("Opens the full result and the run history")
                }
            }
        }
    }

    /// The countdown, or the reason there is not one.
    ///
    /// Three different states and three different sentences. A paused routine
    /// keeps its schedule and produces nothing, so it must not show a
    /// countdown; a spent one-shot has finished, which is not the same as being
    /// paused; and a rule a corrupt file made unfireable is neither.
    @ViewBuilder
    private var nextRow: some View {
        HStack(spacing: PDSpacing.xs) {
            if !task.isEnabled {
                MiniLabel("Paused", tint: .pd.inkTertiary)
            } else if let next = dueness.next {
                MiniLabel("Next")
                Text(ScheduleWords.nextLabel(next))
                    .font(Font.pd.label.weight(.medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.pd.ink)
                    .accessibilityLabel(ScheduleWords.nextSpoken(next))
            } else {
                MiniLabel("Nothing further", tint: .pd.inkTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One template

/// A routine somebody could have in one tap, as a card on the grid.
private struct TemplateCard: View {
    let template: RoutineTemplate
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                IconTile(symbol: template.symbolName)
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    Text(template.title)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                        .multilineTextAlignment(.leading)
                    Text(template.blurb)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Pushes the pill to the bottom of whichever card in this row
                // is the taller, so the two pills line up.
                Spacer(minLength: PDSpacing.xs)
                addPill
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(PDSpacing.m)
            .pdCardSurface(radius: PDRadius.smallCard)
            .contentShape(RoundedRectangle(cornerRadius: PDRadius.smallCard, style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel("Add \(template.title). \(template.blurb)")
    }

    /// Not a `Button`. The whole card is the control, and a second one inside
    /// it would give the grid two tap targets that do the same thing and one
    /// that swallows the other's taps.
    private var addPill: some View {
        HStack(spacing: PDSpacing.xxs) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
            Text("Add")
                .font(Font.pd.caption.weight(.medium))
        }
        .foregroundStyle(Color.pd.ink)
        .padding(.horizontal, PDSpacing.s)
        .frame(height: PDMetric.linkPillHeight)
        .background(Color.pd.chip, in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - The row shape

private extension View {
    /// A list row that looks like a card on a canvas.
    ///
    /// Clear background, no separator, the page gutter as the leading and
    /// trailing inset, and the card gap as the bottom one. Gathered into a
    /// modifier because six call sites repeating four list-row modifiers is
    /// where one of them quietly loses its separator hide.
    func pdRoutineRow(_ index: Int) -> some View {
        self
            .listRowInsets(
                EdgeInsets(
                    top: 0,
                    leading: PDSpacing.gutter,
                    bottom: PDSpacing.cardGap,
                    trailing: PDSpacing.gutter
                )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .pdStaggerIn(index)
    }
}

// MARK: - Previews

#Preview("Routines empty light") {
    RoutinesPreview(tasks: [])
}

#Preview("Routines empty dark") {
    RoutinesPreview(tasks: []).preferredColorScheme(.dark)
}

/// The screen with real routines on it, which a simulator cannot produce
/// without a brain: the run history below comes from a fabricated `TaskRun`.
#Preview("Routines list light") {
    RoutinesPreview(tasks: RoutinePreviewData.tasks)
}

#Preview("Routines list dark") {
    RoutinesPreview(tasks: RoutinePreviewData.tasks).preferredColorScheme(.dark)
}

/// A stand-in for the screen, built from a fixed list rather than from
/// `AppModel`.
///
/// `AppModel.scheduledTasks` is `private(set)` and reads the real container, so
/// a preview of the populated state cannot be made by handing the real screen a
/// model. This draws the same cards from the same components against fabricated
/// tasks, which is what a preview is for.
private struct RoutinesPreview: View {
    let tasks: [ScheduledTask]

    var body: some View {
        List {
            HStack {
                Text("Routines").pdTitle().foregroundStyle(Color.pd.ink)
                Spacer()
                CircleIconButton(symbol: "plus", label: "New routine") {}
            }
            .pdRoutineRow(0)

            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                RoutineCard(task: task, edit: {}, openResult: {}, setEnabled: { _ in })
                    .pdRoutineRow(index + 1)
            }

            VStack(alignment: .leading, spacing: PDSpacing.s) {
                if !tasks.isEmpty { SectionLabel("More routines") }
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: PDSpacing.tileGap),
                        GridItem(.flexible(), spacing: PDSpacing.tileGap),
                    ],
                    spacing: PDSpacing.tileGap
                ) {
                    ForEach(RoutineTemplate.offered, id: \.self) { template in
                        TemplateCard(template: template) {}
                    }
                }
            }
            .pdRoutineRow(tasks.count + 1)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .pdHeroWash()
        .pdCanvas()
    }
}

/// Routines and runs that cannot exist on a simulator, for the previews.
enum RoutinePreviewData {
    static var tasks: [ScheduledTask] {
        [morningBrief, overdueWatcher]
    }

    static var morningBrief: ScheduledTask {
        var task = RoutineTemplate.morningBrief.task(now: Date().addingTimeInterval(-86_400 * 6))
        task.runs = [
            .reported(
                firing: Date().addingTimeInterval(-86_400 - 3_600),
                ranAt: Date().addingTimeInterval(-86_400 - 3_000),
                context: .notificationResponse,
                output: Untrusted(
                    """
                    You have the design review at ten and nothing after four, so the afternoon is yours. \
                    Two things are still open on your list, both from last week. You slept six and a half \
                    hours, a little under your usual.
                    """
                )
            ),
            .reported(
                firing: Date().addingTimeInterval(-3_600 * 5),
                ranAt: Date().addingTimeInterval(-3_600 * 4),
                context: .deskMode,
                output: Untrusted(
                    """
                    A quiet morning: nothing on until the one-to-one at two. Three reminders are due today \
                    and one of them has slipped. Seven hours and ten minutes of sleep, which is the best \
                    this week.
                    """
                )
            ),
        ]
        return task
    }

    static var overdueWatcher: ScheduledTask {
        var task = RoutineTemplate.overdueWatcher.task(now: Date().addingTimeInterval(-86_400 * 3))
        task.runs = [
            .nothingToReport(
                firing: Date().addingTimeInterval(-86_400),
                ranAt: Date().addingTimeInterval(-86_400),
                context: .backgroundRefresh
            ),
            .reported(
                firing: Date().addingTimeInterval(-3_600 * 9),
                ranAt: Date().addingTimeInterval(-3_600 * 9),
                context: .backgroundRefresh,
                output: Untrusted("2 overdue\nSend the signed lease — due Friday\nBook the dentist — due 4 September")
            ),
        ]
        return task
    }
}
