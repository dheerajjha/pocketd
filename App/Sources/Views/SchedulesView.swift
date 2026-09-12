import PocketdKit
import SwiftUI

// MARK: - Two questions both surfaces ask

/// Readings over the schedule that more than one view needs.
///
/// Gathered so that `ScheduleBar`, which sits above the tab bar, and the sheet
/// it opens cannot disagree about what is due. They did, in the first version of
/// this, because each worked it out its own way.
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

// MARK: - The entry point above the tab bar

/// One row, above the tab bar on the Abilities tab, that says what the schedule
/// is doing and opens it.
///
/// This is the whole navigation for the feature, and it is a bar rather than a
/// sixth tab for a reason that is not aesthetic: iOS shows five tabs and folds
/// everything past the fifth into More, so a sixth tab does not cost a slot, it
/// costs Settings — which would be buried behind a disclosure list to make room
/// for a screen most people visit weekly. `RootView` has the longer version of
/// this argument at the tab bar itself.
///
/// It earns the space by carrying state rather than being a link: the next
/// firing, and — the part that matters — a count of results waiting because a
/// prompt task came due while the app was closed. That last fact is the one
/// thing about this feature a user cannot discover on their own.
struct ScheduleBar: View {
    @Environment(AppModel.self) private var model
    var open: () -> Void

    var body: some View {
        // The material and the divider belong to the container, not to the
        // button, and that is not cosmetic. A `safeAreaInset` at the bottom of a
        // tab also absorbs the bottom safe area — under iOS 26's floating tab
        // bar that is the best part of forty points — and whatever view carries
        // the background grows to fill it. With the background on the button,
        // the button's frame ran down behind the tab bar: its centre landed on
        // the tab bar's row, so a tap aimed at the middle of this bar selected
        // whichever tab was underneath. Found by tapping it in the simulator,
        // which is the only way this shows up at all.
        VStack(spacing: 0) {
            Divider()
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.body)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scheduled tasks")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(waiting > 0 ? scheduleWarningColour : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scheduled tasks. \(detail)")
        }
        .background(.bar)
    }

    private var waiting: Int { ScheduleSummary.pending(in: model.scheduledTasks).count }

    private var detail: String {
        // Ordered by what the user can do something about. A waiting result is
        // an action — open the app, which they have just done — and outranks a
        // countdown to something that has not happened yet.
        if waiting > 0 {
            return waiting == 1
                ? "1 result waiting to be written"
                : "\(waiting) results waiting to be written"
        }
        guard !model.scheduledTasks.isEmpty else {
            return "Have the phone check your day on its own"
        }
        guard let next = ScheduleSummary.nextFiring(in: model.scheduledTasks) else {
            // Two different reasons for no next firing, and they are not the
            // same sentence: every task paused is something the user did, and a
            // spent one-shot is a task that has finished. Saying "nothing
            // scheduled" over four visible rows reads as a bug either way.
            return model.scheduledTasks.contains(where: \.isEnabled)
                ? "Nothing more due"
                : "Nothing due — every task is paused"
        }
        return "Next: \(ScheduleWords.when(next))"
    }
}

// MARK: - The screen

/// Every scheduled task, what each one will do next, and what the last few runs
/// actually said — on one screen.
///
/// One screen and not three, which is the main structural decision here. The
/// obvious build is a list, a per-task history behind each row, and an activity
/// feed somewhere in Settings; that produces three places showing the same run
/// records, two of which always look stale because nobody opens them. Here the
/// row answers *is this working* — next firing, last result in one line — and
/// the section below it answers *what did it say*, in full, across every task.
/// Tapping a row edits the task. There is no fourth surface.
///
/// The schedule itself lives on `AppModel`, not here, and that is load-bearing
/// rather than tidy: `saveScheduledTask` also asks for notification permission
/// at the first task and reconciles the pending `UNCalendarNotificationTrigger`
/// requests afterwards. A screen that wrote to `ScheduledTaskStore` directly —
/// which is what this did first — produced tasks that were saved correctly, sat
/// in the list looking scheduled, and never notified anybody.
struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var goTo: (AppTab) -> Void = { _ in }

    @State private var editing: ScheduleDraft?
    @State private var deleting: ScheduledTask?

    /// Whether the store has been read since this screen appeared.
    ///
    /// Distinct from "there are no tasks". The empty state and the starter list
    /// both describe a phone with nothing scheduled, and showing either for the
    /// frame before the list has been read makes an app with four tasks in it
    /// look like a fresh install — and, worse, offers to add a starter the user
    /// already has.
    @State private var hasLoaded = false

    /// Set when a save did not reach the disk. See `save(_:)`.
    @State private var saveFailed = false

    private var tasks: [ScheduledTask] { model.scheduledTasks }

    var body: some View {
        NavigationStack {
            List {
                if saveFailed {
                    // Above everything, because the list underneath it is not
                    // what the user just asked for and nothing else on screen
                    // admits that.
                    Section {
                        Text("That could not be saved. This phone may be out of space.")
                            .font(.footnote)
                            .foregroundStyle(scheduleWarningColour)
                    }
                }
                if tasks.isEmpty {
                    if hasLoaded { emptySection }
                } else {
                    waitingSection
                    tasksSection
                    runsSection
                }
                startersSection
            }
            .navigationTitle("Scheduled tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = ScheduleDraft()
                    } label: {
                        Label("New task", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(item: $editing) { draft in
                ScheduleEditorView(draft: draft, goTo: goTo) { edited in
                    Task { await save(edited) }
                }
            }
            .confirmationDialog(
                "Delete this task?",
                isPresented: Binding(
                    get: { deleting != nil },
                    set: { if !$0 { deleting = nil } }
                ),
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
                // Named, and explicit that the history goes with it: the runs
                // are the only record of what the phone read on those mornings,
                // and nothing else in the app keeps a copy.
                Text(deleting.map { "\($0.title) and everything it has reported will be removed." } ?? "")
            }
        }
        // `AppModel` reads the store at launch and again after every sweep, so
        // this is a catch-up rather than the only load: a `BGAppRefreshTask`
        // settles runs into these files while the app is closed, and the sweep
        // that notices happens on the way back to `.active`, which can be after
        // this sheet is already on screen.
        .task {
            await model.loadScheduledTasks()
            hasLoaded = true
        }
    }

    // MARK: - Writing

    /// Saves through `AppModel`, and notices when that did not work.
    ///
    /// `AppModel.saveScheduledTask` swallows the write error — `try?` around a
    /// file write that a full disk makes throw — and then reloads the list, so
    /// the only observable difference between a saved task and a failed one is
    /// whether the row comes back. Worth checking for a new task, where the
    /// failure is total and silent: the user fills in the editor, taps Save, and
    /// lands on a list that does not contain what they just made. An edit that
    /// fails leaves the previous version on screen, which at least shows
    /// something. The handoff asks for a save that reports.
    private func save(_ draft: ScheduleDraft) async {
        var task: ScheduledTask
        if let id = draft.id, let existing = tasks.first(where: { $0.id == id }) {
            // Built on the copy the list holds rather than on the one the editor
            // opened with. A background refresh settles runs into the same file
            // while the editor is open, and `saveScheduledTask` writes the whole
            // task; starting from a stale snapshot puts a hole in the history.
            task = existing
            draft.apply(to: &task)
        } else {
            // An edit whose task went missing — the Data screen's delete
            // everything, while this editor was open — is written back under its
            // original id rather than as a new one. The runs are gone with the
            // file, but the task the user was in the middle of editing is not.
            task = draft.newTask()
        }
        await model.saveScheduledTask(task)
        saveFailed = !tasks.contains { $0.id == task.id }
    }

    private func setEnabled(_ enabled: Bool, _ task: ScheduledTask, now: Date = Date()) async {
        var updated = task
        updated.isEnabled = enabled
        if enabled {
            // Resuming skips what was missed while it was off. A daily 09:00
            // task switched off for a week's holiday and switched back on at
            // 14:00 has seven unsettled firings behind it, the most recent being
            // this morning's — so without this the reward for coming home is an
            // immediate notification about a briefing that was due five hours
            // ago. `ScheduledTask.settledThrough` makes exactly this argument
            // for newly created tasks; a resume is the same moment.
            updated.settledThrough = max(updated.settledThrough, now)
        }
        updated.updatedAt = now
        await model.saveScheduledTask(updated)
    }

    // MARK: - Nothing here yet

    private var emptySection: some View {
        Section {
            ContentUnavailableView {
                Label("Nothing scheduled", systemImage: "calendar.badge.clock")
            } description: {
                Text(
                    """
                    A scheduled task checks something on this phone at a time you pick, and tells you what it \
                    found. It all happens here: nothing is uploaded, and no server is involved.
                    """
                )
            }
        }
    }

    // MARK: - Promises not yet kept

    /// Prompt tasks that came due where no model could run.
    ///
    /// This section is the honest face of the constraint the whole feature is
    /// built on, and it appears only when the constraint has actually bitten:
    /// the notification fired on time, the thinking did not happen, and the app
    /// is now open, which is the state that can fix it. The failure it exists to
    /// prevent is a user who set a 7am briefing, was notified at 7am with
    /// nothing useful in it, and has no idea the app is waiting on them.
    @ViewBuilder
    private var waitingSection: some View {
        let waiting = ScheduleSummary.pending(in: tasks)
        if !waiting.isEmpty {
            Section {
                ForEach(waiting, id: \.run.id) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.task.title)
                            .font(.subheadline.weight(.medium))
                        Text("Due \(ScheduleWords.when(item.run.firing)). Not written yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                if model.isLoadingModel {
                    // Loading is a transition, not a fault. Sending somebody to
                    // the Models tab to fix something that is in the middle of
                    // fixing itself is the mistake `AbilitiesView` takes care
                    // not to make about a server that is restarting.
                    Text("A model is still loading.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.loadedModelID == nil {
                    // The remedy, not a complaint. A waiting prompt task with no
                    // model loaded files a `.noModelLoaded` run the moment
                    // anything sweeps, and there is no way to guess that from a
                    // screen about schedules.
                    Text("No model is loaded, so there is nothing to think with yet.")
                        .font(.caption)
                        .foregroundStyle(scheduleWarningColour)
                    Button("Choose a model") { goTo(.models) }
                } else if !model.deskMode {
                    Button("Turn on Desk Mode") { model.deskMode = true }
                }
            } header: {
                Label("Waiting for you", systemImage: "hourglass")
            } footer: {
                Text(ScheduleWords.waitingFooter(hasModel: model.loadedModelID != nil))
            }
        }
    }

    // MARK: - The tasks

    private var tasksSection: some View {
        Section {
            ForEach(tasks) { task in
                row(for: task)
            }
        } header: {
            Text("Tasks")
        } footer: {
            // The one sentence that has to survive somebody skimming. Both
            // halves, in the order that matters: what runs on its own, and what
            // needs you here.
            Text(ScheduleWords.listFooter)
        }
    }

    @ViewBuilder
    private func row(for task: ScheduledTask) -> some View {
        let dueness = task.dueness()
        Button {
            editing = ScheduleDraft(task)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.body)
                        .foregroundStyle(task.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    kindChip(for: task.body)
                }
                Text(scheduleLine(for: task, dueness: dueness))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = lastResultLine(for: task) {
                    Text(last.text)
                        .font(.caption)
                        .foregroundStyle(last.isTrouble ? scheduleWarningColour : Color.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            // The three lines are one thing to a screen reader, and without this
            // each is its own element: VoiceOver offered "Morning briefing",
            // "Runs on its own" and the schedule as three separate stops on a
            // row that does one thing. The label below is what they say.
            .accessibilityElement(children: .ignore)
        }
        // Without this the row is a Button and tints its whole label with the
        // accent colour, so every timestamp reads as a link — the same fix
        // `ConversationHistoryView` needed.
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = task } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                Task { await setEnabled(!task.isEnabled, task) }
            } label: {
                Label(task.isEnabled ? "Pause" : "Resume", systemImage: task.isEnabled ? "pause" : "play")
            }
            .tint(.indigo)
        }
        .accessibilityLabel(
            "\(task.title). \(ScheduleWords.kind(task.body).chip). \(scheduleLine(for: task, dueness: dueness))"
        )
    }

    private func kindChip(for body: TaskBody) -> some View {
        let kind = ScheduleWords.kind(body)
        return Label(kind.chip, systemImage: kind.symbol)
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.14), in: Capsule())
    }

    /// "Every day at 7:00 AM · next tomorrow", or why there is no next.
    private func scheduleLine(for task: ScheduledTask, dueness: Dueness) -> String {
        let pattern = ScheduleWords.recurrence(task.recurrence)
        guard task.isEnabled else { return "\(pattern) · paused" }
        guard let next = dueness.next else {
            // A spent `.once`, or a rule a corrupt file made unfireable. Either
            // way the row must not imply a countdown.
            return "\(pattern) · nothing further"
        }
        // `.once` has already named the instant in its pattern, and every other
        // case has already named the time — so the next firing is added as a day
        // and not as a whole date. "Every day at 7:00 AM · next tomorrow at 7:00
        // AM" was the first version, and saying the time twice in one line is
        // how a row stops being read at all.
        if case .once = task.recurrence { return pattern }
        return "\(pattern) · next \(ScheduleWords.day(next))"
    }

    private func lastResultLine(for task: ScheduledTask) -> (text: String, isTrouble: Bool)? {
        guard let run = task.lastCompletedRun else { return nil }
        let summary = ScheduleWords.summary(of: run, in: task)
        return ("\(ScheduleWords.when(run.ranAt).capitalisedFirst): \(summary.text)", summary.isTrouble)
    }

    // MARK: - What ran

    /// Every run, newest first, across every task.
    ///
    /// Merged rather than kept per task because that is the question people
    /// actually have — "what has this thing been telling me" — and because the
    /// merged order is the only view that makes the split visible: watcher runs
    /// land here saying they ran while the app was closed, prompt runs saying
    /// they ran when it was opened. Nothing else on this screen demonstrates the
    /// difference as plainly as the record does.
    @ViewBuilder
    private var runsSection: some View {
        let feed = recentRuns()
        if !feed.isEmpty {
            Section("What ran") {
                ForEach(feed, id: \.run.id) { item in
                    runRow(item.run, of: item.task)
                }
            }
        }
    }

    /// How many runs the feed shows.
    ///
    /// Twelve is a handful of days of the three starter tasks, which is the span
    /// somebody is looking at when they ask whether this has been working.
    /// `ScheduledTask.runHistoryLimit` keeps twenty *per task*, so a user with
    /// six tasks has 120 records on disk, and a list that scrolls forever is not
    /// a history, it is a log file.
    private static let feedLimit = 12

    private func recentRuns() -> [(task: ScheduledTask, run: TaskRun)] {
        tasks
            .flatMap { task in
                task.runs
                    // A promise is not a run. `waitingSection` already shows
                    // these, and listing them here as well describes one firing
                    // twice — the mistake `ScheduledTask.settle` goes out of its
                    // way to avoid inside the record itself.
                    .filter { !$0.isAwaitingForeground }
                    .map { (task: task, run: $0) }
            }
            .sorted { $0.run.ranAt > $1.run.ranAt }
            .prefix(Self.feedLimit)
            .map { $0 }
    }

    private func runRow(_ run: TaskRun, of task: ScheduledTask) -> some View {
        let summary = ScheduleWords.summary(of: run, in: task)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(task.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(ScheduleWords.when(run.ranAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(summary.text)
                .font(.callout)
                .foregroundStyle(summary.isTrouble ? scheduleWarningColour : Color.primary)
                // The run's own text is the user's calendar and reminders read
                // back to them. Selectable so it can be copied somewhere useful;
                // it is on disk either way.
                .textSelection(.enabled)
            Text(ScheduleWords.context(run.context))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Starters

    /// The three tasks somebody would actually have written, offered as one tap
    /// each.
    ///
    /// Nobody composes a cron entry into an empty box. Every one of these is a
    /// watcher, which is not a coincidence and is the point: a watcher needs no
    /// model, so all three genuinely run while the app is shut, and a first
    /// experience of this feature that arrives on time is worth more than one
    /// that shows off the model and then explains why it is late.
    @ViewBuilder
    private var startersSection: some View {
        // Gated on `hasLoaded` rather than on the list being empty: for the
        // frame before the store has been read every starter looks absent, and
        // offering to add one the user already has is how somebody ends up with
        // two morning briefings.
        let offered = hasLoaded
            ? ScheduleStarter.all.filter { starter in
                !tasks.contains { $0.title.caseInsensitiveCompare(starter.title) == .orderedSame }
            }
            : []
        if !offered.isEmpty {
            Section {
                ForEach(offered) { starter in
                    Button {
                        Task { await save(ScheduleDraft(starter)) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: starter.symbol)
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(starter.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(starter.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(tasks.isEmpty ? "Start with one of these" : "Add another")
            } footer: {
                Text(ScheduleStarter.footer)
            }
        }
    }
}

// MARK: - Starters

/// A task worth having on day one, ready to save.
struct ScheduleStarter: Identifiable, Sendable {
    var id: String { title }
    let title: String
    /// What it does and when, in one line, before anybody taps.
    let detail: String
    let symbol: String
    let work: TaskBody
    let recurrence: Recurrence

    /// Three, and every one of them a rule rather than a prompt.
    ///
    /// Each was chosen by asking whether the answer needs a model, and none of
    /// them do: "what is on today" is a sorted list of rows with a time in front
    /// of each, which is a template and not a thought. Making the morning
    /// briefing a prompt task would read better and would arrive whenever the
    /// user next picked up the phone — which, for a morning briefing, is the one
    /// thing it must not do.
    static let all: [ScheduleStarter] = [
        ScheduleStarter(
            title: "Morning briefing",
            detail: "Everything on today's calendar, at 7:00 each morning.",
            symbol: "sun.horizon",
            work: .watcher(rule: .events(.today), notifyWhenEmpty: false),
            recurrence: .daily(at: TimeOfDay(hour: 7, minute: 0))
        ),
        ScheduleStarter(
            title: "Overdue reminders",
            detail: "Anything you have let slip, at 18:00 — in time to still do it.",
            symbol: "exclamationmark.circle",
            work: .watcher(rule: .reminders(.overdue), notifyWhenEmpty: false),
            recurrence: .daily(at: TimeOfDay(hour: 18, minute: 0))
        ),
        ScheduleStarter(
            title: "What is on tomorrow",
            detail: "Tomorrow's calendar at 21:00, including when it is empty.",
            symbol: "moon.stars",
            // The one starter that asks to be told about an empty result, and
            // `TaskBody.watcher` names this exact case: "nothing on tomorrow" is
            // a result somebody went looking for, unlike "nothing today", which
            // is a buzz for no reason.
            work: .watcher(rule: .events(.tomorrow), notifyWhenEmpty: true),
            recurrence: .daily(at: TimeOfDay(hour: 21, minute: 0))
        )
    ]

    static let footer = """
        None of these need the model, so they run on their own — the notification arrives with the answer \
        already in it, even if Pocketd has not been opened for days.
        """
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
    /// needs the model, gets nothing useful for a week, and concludes the app is
    /// broken. Discovering the constraint while *making* one of these is fine;
    /// discovering it a week later is the thing that must not happen. So the
    /// sentence sits under the choice in the editor, and again under the list.
    static let listFooter = """
        A task built from a rule runs on its own, in the background, and its notification arrives with the \
        answer in it. A task that needs the model can only be answered while Pocketd is open — iOS refuses a \
        closed app the graphics chip the model runs on — so it notifies you on time and writes the answer when \
        you open the app, or by itself if the phone is charging in Desk Mode.
        """

    /// The same fact, at the moment it is being chosen.
    static func explanation(needsModel: Bool) -> String {
        needsModel
            ? """
            This one needs the model, and the model needs Pocketd to be open — iOS will not give a closed app \
            the graphics chip. You get the notification exactly on time; the answer is written when you open \
            the app, or on its own if the phone is charging in Desk Mode.
            """
            : """
            This one is a rule, not a question for the model, so the phone can answer it while Pocketd is \
            closed. The notification arrives with the answer already in it.
            """
    }

    static func waitingFooter(hasModel: Bool) -> String {
        hasModel
            ? """
            These were due while Pocketd was closed, which is where the model cannot run. They are written the \
            next time the schedule is swept — opening the app does it, and so does leaving the phone on a \
            charger in Desk Mode.
            """
            : """
            These were due while Pocketd was closed, which is where the model cannot run. Nothing can be \
            written for them until a model is loaded.
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
                text: "It could not read what it needed. Check what is switched on under Abilities.",
                isTrouble: true
            )

        case .awaitingForeground:
            return Summary(text: "Due, and not written yet.", isTrouble: false)

        case .failed(let failure):
            switch failure {
            case .noModelLoaded:
                return Summary(text: "No model was loaded, so there was nothing to think with.", isTrouble: true)
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

/// The one non-grey colour these screens use, given for both grounds.
///
/// `Color.orange` as `.caption` body copy measures 2.20:1 on the light grouped
/// background against WCAG AA's 4.5:1 — legible in dark mode, nearly invisible
/// in light, and invisible as a bug to anybody developing in dark.
/// `StoredDataPresentationTests` asserts the ratios these two components reach.
/// `AbilitiesView` carries the same helper; it is duplicated rather than shared
/// because that file belongs to another change. See the handoff.
var scheduleWarningColour: Color {
    Color(uiColor: UIColor { traits in
        let chosen = traits.userInterfaceStyle == .dark
            ? StoredDataPalette.warningOnDark
            : StoredDataPalette.warningOnLight
        return UIColor(
            red: CGFloat(chosen.red),
            green: CGFloat(chosen.green),
            blue: CGFloat(chosen.blue),
            alpha: 1
        )
    })
}
