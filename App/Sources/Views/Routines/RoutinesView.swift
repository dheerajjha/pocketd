import PocketdKit
import SwiftUI
import UIKit

/// Everything this phone does on its own, as a list of alarms.
///
/// A routine is a time, some days and a thing that happens — the same three
/// facts as an alarm — so it looks like one: the time is the hero, one grey
/// line says which days and what, a switch turns it off for a holiday, and one
/// line under it says what it last told you. "+" offers the four things people
/// actually want, each added with one tap; tapping a card edits it.
///
/// What is gone, and why: the "1 brief ready to write" card, "Write them now"
/// and the Desk mode button were all ways of working around a morning brief
/// that needed the brain and the app open. A morning brief is now Today's brief
/// arriving at its hour (`TaskBody.brief`), so there is nothing left to work
/// around. The "NEXT IN 9 H" line repeated the schedule the card already shows.
///
/// It brings no `NavigationStack` and assumes no tab bar: it is pushed from
/// Today, and pushes a routine's result page onto whatever stack it is in.
/// The result page is pushed with `navigationDestination(item:)`, which works
/// on a stack whatever its path type.
///
/// It is a `List` rather than a `ScrollView` of cards for one gesture: swipe to
/// delete. Every hand-rolled version of that inside a `ScrollView` competes
/// with the scroll for the same drag. The rows are cards anyway — clear
/// backgrounds, no separators, the page gutter as the inset.
struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var editing: RoutineDraft?
    @State private var addingRoutine = false
    /// An edit to open once the template sheet has finished going away —
    /// two sheets cannot be presented from one view at the same moment.
    @State private var editAfterSheet: RoutineDraft?
    @State private var openResult: UUID?
    @State private var deleting: ScheduledTask?
    @State private var showsPromo = false
    @State private var settingUp = false
    @State private var notificationsOff = false
    @State private var notificationsUndecided = false

    /// Whether the store has been read since this screen appeared.
    ///
    /// Distinct from "there are no routines", and the distinction is visible:
    /// the empty state and the promo both describe a phone with nothing set
    /// up, and showing either for the frame before the list has been read
    /// makes a phone with four routines on it look like a fresh install.
    @State private var hasLoaded = false

    /// The first-visit promo has been answered, either way. Asked once.
    @AppStorage("pocketd.routines.promoSeen") private var promoSeen = false

    /// In the order of a day, like a list of alarms: the store hands them back
    /// newest first, which is the order nobody thinks about their mornings in.
    /// Ties — two routines at 9:00 — fall back to the name, so the order does
    /// not shuffle between redraws.
    private var tasks: [ScheduledTask] {
        model.scheduledTasks.sorted { left, right in
            let l = ScheduleWords.minuteOfDay(left.recurrence)
            let r = ScheduleWords.minuteOfDay(right.recurrence)
            return l == r ? left.title < right.title : l < r
        }
    }

    var body: some View {
        List {
            if notificationsOff, tasks.contains(where: \.isEnabled) {
                notificationsCard
                    .routineRow(0)
            }

            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                RoutineCard(
                    task: task,
                    isWriting: model.isWritingRoutine(task),
                    edit: { editing = RoutineDraft(task) },
                    openResult: { openResult = task.id },
                    setEnabled: { enabled in Task { await model.setRoutineEnabled(enabled, id: task.id) } }
                )
                .routineRow(index + 1)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = task } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            if tasks.isEmpty, hasLoaded {
                emptyState
                    .routineRow(1)
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .pdCanvas()
        .navigationTitle("Routines")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingRoutine = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a routine")
            }
        }
        // The same page Today opens, so it carries the routine's own question
        // and the composer from both doors.
        .navigationDestination(item: $openResult) { id in
            RoutineResultDetail(taskID: id)
        }
        .sheet(isPresented: $addingRoutine, onDismiss: {
            if let next = editAfterSheet {
                editAfterSheet = nil
                editing = next
            }
        }) {
            RoutineTemplateSheet(
                existing: { model.existingRoutine(for: $0) },
                add: { template in
                    Task {
                        await model.addRoutine(template)
                        Haptics.success()
                        addingRoutine = false
                    }
                },
                open: { draft in
                    editAfterSheet = draft
                    addingRoutine = false
                }
            )
            // Tall enough for the five rows and the notification primer under
            // them without a scroll; large text gets the whole screen.
            .presentationDetents([.fraction(0.8), .large])
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                ScheduleEditorView(draft: draft)
            }
        }
        .sheet(isPresented: $showsPromo) {
            PromoSheet(
                symbol: "alarm",
                title: "Start every day briefed.",
                benefits: [
                    .init("sun.horizon", "Your day, waiting when you wake"),
                    .init("exclamationmark.circle", "Overdue things, caught early"),
                    .init("clock", "At the time you choose"),
                ],
                primaryTitle: "Set it up",
                // Only while iOS has never been asked: Set it up is what asks,
                // and a primer for a sheet that will not appear is a promise
                // the next screen breaks.
                primer: notificationsUndecided
                    ? "Next, tap **Allow** so Pocketd can tell you when your brief is ready."
                    : nil,
                onPrimary: setUp,
                onSecondary: {
                    promoSeen = true
                    showsPromo = false
                }
            )
            .interactiveDismissDisabled(settingUp)
        }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "this routine")?",
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
            Text("Everything it has told you goes with it.")
        }
        // `AppModel` reads the store at launch and again after every sweep, so
        // this is a catch-up rather than the only load: a background refresh
        // settles runs into these files while the app is closed.
        .task {
            await model.loadScheduledTasks()
            hasLoaded = true
            // Writes whatever is owed while somebody is looking — the reason a
            // card that says "Writing…" is telling the truth.
            model.sweepSchedule(in: .foreground)
            model.markRoutineResultsSeen()
            #if DEBUG
            // `-pocketd.routinesPromo`: the first-visit promo again, for a
            // capture or a walkthrough, without reinstalling the app.
            if ProcessInfo.processInfo.arguments.contains("-pocketd.routinesPromo") { promoSeen = false }
            #endif
            // Before the notification settings are read, not after: that read
            // is a round trip to a system daemon, and a promo that waited on
            // it would not appear at all on a phone where the daemon is slow
            // to answer (a freshly erased simulator never answered). The
            // primer arrives in the sheet once the answer does.
            if tasks.isEmpty, !promoSeen {
                showsPromo = true
            }
            await readNotificationSettings()
        }
        .onDisappear { model.markRoutineResultsSeen() }
        // Notifications may have been switched on in Settings while away.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await readNotificationSettings() } }
        }
    }

    // MARK: - First visit

    /// [Set it up]: the morning brief and the overdue nudge, at their usual
    /// times — the two the promo's rows promise. Notification permission is
    /// asked by the first save, now, after the person chose the feature.
    private func setUp() {
        guard !settingUp else { return }
        settingUp = true
        Task {
            await model.setUpMorningBrief()
            if model.existingRoutine(for: .overdueWatcher) == nil {
                await model.addRoutine(.overdueWatcher)
            }
            promoSeen = true
            settingUp = false
            showsPromo = false
            Haptics.success()
            await readNotificationSettings()
        }
    }

    // MARK: - Nothing set up

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            Text("No routines yet.")
                .font(Font.pd.headline)
                .foregroundStyle(Color.pd.ink)
            Text("Pocketd can brief you every morning, catch what slipped, and more — at the time you choose.")
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: "Add a routine", symbol: "plus") {
                addingRoutine = true
            }
            .padding(.top, PDSpacing.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PDSpacing.s)
    }

    // MARK: - Notifications off

    /// One sentence and one action, only when it is true and matters: a
    /// routine is switched on and iOS will not let it say anything.
    private var notificationsCard: some View {
        NoticeCard(
            symbol: "bell.slash",
            tint: .pd.caution,
            text: "Notifications are off, so routines can't tell you anything.",
            linkTitle: "Open Settings",
            linkSymbol: "arrow.up.right"
        ) {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    private func readNotificationSettings() async {
        let status = await NotificationCentre.shared.authorizationStatus()
        notificationsOff = status == .denied
        notificationsUndecided = status == .notDetermined
    }
}

// MARK: - One routine

/// A routine as an alarm: the time, one grey line, a switch, and what it last
/// said.
///
/// Its own view rather than a method on the screen so that the switch's
/// binding, the only piece of state a card owns, cannot be rebuilt from a
/// different routine on every redraw of the list.
private struct RoutineCard: View {
    let task: ScheduledTask
    let isWriting: Bool
    let edit: () -> Void
    let openResult: () -> Void
    let setEnabled: (Bool) -> Void

    private var hero: (time: String, period: String?) { ScheduleWords.hero(task.recurrence) }
    private var result: ScheduleWords.Summary? { ScheduleWords.cardResult(task, isWriting: isWriting) }

    var body: some View {
        PDCard(padding: PDSpacing.m) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                HStack(alignment: .center, spacing: PDSpacing.s) {
                    // The time and the line are the editor's tap target, and
                    // the switch sits beside them rather than inside: a card
                    // that is one big button with a switch in the corner is a
                    // card where half the taps on the switch open the editor.
                    Button(action: edit) {
                        VStack(alignment: .leading, spacing: 2) {
                            timeText
                            Text(ScheduleWords.cardLine(task))
                                .font(Font.pd.secondary)
                                .foregroundStyle(Color.pd.inkSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PDPressStyle())
                    .accessibilityLabel(
                        "\(task.title). \(ScheduleWords.recurrence(task.recurrence))\(task.isEnabled ? "" : ". Off")"
                    )
                    .accessibilityHint("Edits the routine")

                    Toggle("", isOn: Binding(get: { task.isEnabled }, set: { setEnabled($0) }))
                        .labelsHidden()
                        .tint(Color.pd.accent)
                        .accessibilityLabel(task.title)
                }

                if let result {
                    Rectangle()
                        .fill(Color.pd.divider)
                        .frame(height: 1)
                    Button(action: openResult) {
                        HStack(spacing: PDSpacing.xs) {
                            Text(result.text)
                                .font(Font.pd.secondary)
                                .foregroundStyle(result.isTrouble ? Color.pd.caution : Color.pd.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(Font.pd.chevron)
                                .foregroundStyle(Color.pd.inkTertiary)
                        }
                        .frame(minHeight: PDMetric.minHitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PDPressStyle())
                    .accessibilityLabel("Last result. \(result.text)")
                    .accessibilityHint("Opens what it said, and what it said before")
                }
            }
        }
    }

    /// "7:30" big, "AM" beside it at a reading size — the shape of an alarm.
    /// Proportional digits: this is a number to read, not a column to align.
    private var timeText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(hero.time)
                .font(Font.pd.timeHero)
                .tracking(-0.5)
            if let period = hero.period {
                Text(period)
                    .font(Font.pd.secondary)
            }
        }
        .foregroundStyle(task.isEnabled ? Color.pd.ink : Color.pd.inkTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - The row shape

private extension View {
    /// A list row that looks like a card on a canvas.
    ///
    /// Clear background, no separator, the page gutter as the leading and
    /// trailing inset, and the card gap as the bottom one. Gathered into a
    /// modifier because call sites repeating four list-row modifiers is where
    /// one of them quietly loses its separator hide.
    func routineRow(_ index: Int) -> some View {
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

#Preview("Routines light") {
    NavigationStack {
        RoutinesView()
    }
    .environment(AppModel())
}

#Preview("Routines dark") {
    NavigationStack {
        RoutinesView()
    }
    .environment(AppModel())
    .preferredColorScheme(.dark)
}
