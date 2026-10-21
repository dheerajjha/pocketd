import Foundation
import PocketdKit

// MARK: - Where a notification tap lands

/// Where a tap on a routine's notification should take the person.
///
/// Decided here rather than in the shell, because the answer depends on what
/// the routine is and the shell should not have to know: a brief's result *is*
/// Today's brief, so a brief goes to Today; anything else has a result of its
/// own, on its own page.
enum RoutineTapDestination: Equatable, Sendable {
    /// Pop to Today. The brief is being (re)written there.
    case today
    /// Push `RoutineResultView(taskID:)`.
    case result(UUID)
    /// The routine was deleted after its notification was delivered. The list
    /// is the honest place to land: the thing tapped no longer exists.
    case routines
}

// MARK: - Routines

/// What the Routines screen, the shell and onboarding ask of the app about
/// routines.
///
/// A thin arrangement of machinery that already exists — `RoutineTemplate`
/// builds a routine, `RoutineDraft` edits one, `AppModel+Schedule` stores, arms
/// and sweeps — kept out of the views so that the paths a routine takes into
/// the store are the same from every screen. There is no new copy of "what is
/// scheduled" here and there must not be, because a second copy is how a screen
/// and a scheduler come to disagree.
@MainActor
extension AppModel {

    // MARK: Adding

    /// The routine a template already has on this phone, if any.
    func existingRoutine(for template: RoutineTemplate) -> ScheduledTask? {
        scheduledTasks.first { RoutineTemplate.matching($0) == template }
    }

    /// Adds a template's routine in one tap, with its own defaults.
    ///
    /// Through `saveScheduledTask`, which is load-bearing rather than tidy:
    /// that is what asks for notification permission and arms the trigger. A
    /// routine written straight to disk sits in the list looking scheduled and
    /// never notifies anybody.
    ///
    /// - Returns: The saved routine, or `nil` when it did not reach the disk.
    @discardableResult
    func addRoutine(
        _ template: RoutineTemplate,
        at time: TimeOfDay? = nil,
        weekdaysOnly: Bool = true
    ) async -> ScheduledTask? {
        let task = template.task(time: time, weekdaysOnly: weekdaysOnly)
        guard await saveScheduledTask(task) else { return nil }
        record(.routineCreated(template: template.origin))
        return task
    }

    /// The morning brief at this time: made the first time, moved after that.
    ///
    /// For the intro's morning-brief step and the Routines promo. A replayed
    /// intro used to leave a second "Morning brief" behind every time it was
    /// finished; this one finds the first and changes its hour and days
    /// instead, and switches it back on if it had been paused.
    @discardableResult
    func setUpMorningBrief(
        at time: TimeOfDay = RoutineTemplate.morningBrief.defaultTime,
        weekdaysOnly: Bool = true
    ) async -> ScheduledTask? {
        guard let existing = existingRoutine(for: .morningBrief) else {
            return await addRoutine(.morningBrief, at: time, weekdaysOnly: weekdaysOnly)
        }
        var draft = RoutineDraft(existing)
        draft.kind = .brief
        draft.repeats = .weekly
        draft.days = weekdaysOnly ? Weekday.workdays : Set(Weekday.allCases)
        draft.time = RoutineDraft.date(from: time)
        draft.isEnabled = true
        let edit = draft
        let now = Date()
        return await updateScheduledTask(existing.id) { edit.apply(to: &$0, now: now) }
    }

    // MARK: Editing

    /// Saves what the editor holds. Returns whether it reached the disk.
    ///
    /// An edit is applied inside the store's `update` — onto the routine as it
    /// is on disk at that instant, not as it was when the editor opened — so a
    /// run a background refresh settled while the editor was open survives the
    /// save. An edit whose routine has disappeared underneath it (delete
    /// everything, on the Privacy screen, with the editor open) is written back
    /// under its original id rather than lost.
    func saveRoutine(_ draft: RoutineDraft) async -> Bool {
        let now = Date()
        if let id = draft.taskID, await updateScheduledTask(id, { draft.apply(to: &$0, now: now) }) != nil {
            return true
        }
        let task = draft.newTask(now: now)
        guard await saveScheduledTask(task) else { return false }
        // Recorded here, at the save, because a routine from scratch does not
        // exist until now. `origin` is nil for Custom, which is what `.custom`
        // is for.
        record(.routineCreated(template: draft.origin?.origin ?? .custom))
        return true
    }

    /// The card's switch. Resuming skips what was missed while it was off —
    /// the rule lives on `ScheduledTask.setEnabled`, shared with the editor.
    func setRoutineEnabled(_ enabled: Bool, id: UUID) async {
        let now = DemoClock.now
        await updateScheduledTask(id) { $0.setEnabled(enabled, at: now) }
    }

    // MARK: Notification taps

    /// Takes the outstanding notification tap and says where it goes.
    ///
    /// For the shell to call when it appears and whenever
    /// `NotificationCentre.shared.requestedTask` changes. A brief goes to Today
    /// and has its brief rewritten there — the tap is the person asking for
    /// it. Anything else goes to its result page, and the sweep runs in the
    /// context the tap was promised: a question that came due while the app
    /// was closed is written now, with the person looking at the page it will
    /// appear on.
    func takeRoutineTap() async -> RoutineTapDestination? {
        guard let id = NotificationCentre.shared.takeRequestedTask() else { return nil }
        // The store rather than the list: on a cold launch from the banner
        // this can run before `bootstrap` has read the list for the first time.
        guard let task = await tasks.task(id) else { return .routines }
        if case .brief = task.body {
            Task { await self.refreshBrief(force: true) }
            sweepSchedule(in: .notificationResponse)
            return .today
        }
        sweepSchedule(in: .notificationResponse)
        return .result(id)
    }

    // MARK: Today's brief

    /// The latest moment a brief routine came due at or before `now`.
    ///
    /// Worked out from the schedule rather than from run records, so it does
    /// not wait for a sweep to have settled anything: the 21:00 wrap-up has
    /// fired at 21:00 whether or not anything has been written down about it.
    func latestBriefFiring(onOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        scheduledTasks
            .filter { $0.isEnabled && $0.body == .brief }
            .compactMap { task -> Date? in
                guard let last = FireSequence.last(onOrBefore: now, of: task.recurrence, calendar: calendar),
                      last >= task.createdAt
                else { return nil }
                return last
            }
            .max()
    }

    /// Whether a brief routine has fired since a brief was written.
    ///
    /// The rule that makes "Evening wrap-up, 21:00" produce an evening brief:
    /// Today keeps a brain-written brief for the rest of the day unless asked
    /// again, and a brief routine firing *is* being asked again. For
    /// `refreshBrief` to treat a brief written before the latest firing as
    /// stale.
    func briefRoutineFired(since written: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let last = latestBriefFiring(onOrBefore: now, calendar: calendar) else { return false }
        return last > written
    }

    // MARK: Results somebody has not seen

    /// Results routines have written since Routines was last open, newest
    /// first.
    ///
    /// What earns Today's ⏰ its badge, and what a Today card can lead with.
    /// Briefs are left out — a brief's result is the brief, already on Today —
    /// and so are "nothing to report" and the promises still being written:
    /// neither is something to go and read.
    var unreadRoutineResults: [(task: ScheduledTask, run: TaskRun)] {
        guard let seen = RoutineInbox.shared.lastSeen else { return [] }
        return scheduledTasks
            .filter { $0.body != .brief }
            .flatMap { task in
                task.runs
                    .filter { run in
                        guard run.ranAt > seen else { return false }
                        switch run.outcome {
                        case .reported, .unauthorized, .failed: return true
                        case .nothingToReport, .awaitingForeground: return false
                        }
                    }
                    .map { (task: task, run: $0) }
            }
            .sorted { $0.run.ranAt > $1.run.ranAt }
    }

    /// Everything routines have said counts as seen from now.
    func markRoutineResultsSeen() {
        RoutineInbox.shared.markSeen()
    }

    // MARK: Writing

    /// Whether a question's answer is owed and is being — or is about to be —
    /// written.
    ///
    /// Owed means the run was promised in the background and not collected,
    /// or the firing has come and gone with the app open. The Routines screen
    /// sweeps on appearance, so a card that says "Writing…" is a card whose
    /// answer is genuinely on its way: written by the brain, or filed as a
    /// failure that says why not.
    func isWritingRoutine(_ task: ScheduledTask, now: Date = Date()) -> Bool {
        guard task.isEnabled, task.body.needsModel else { return false }
        return task.pendingRun(now: now) != nil || task.dueness(now: now).isDue
    }
}

// MARK: - Which template, for the analytics taxonomy

extension RoutineTemplate {
    /// The bounded wire value for `AnalyticsEvent.routineCreated`.
    ///
    /// Written out rather than `RoutineOrigin(rawValue:)` off this enum's own
    /// raw string, for the reason `RoutineOrigin`'s own note gives: the two
    /// types are a domain type and a wire type, they already differ by a
    /// `custom` case, and a lookup that happens to succeed today would fail
    /// silently — as a `nil` and then a wrong default — the first time either
    /// grows a case the other should not have. An exhaustive switch breaks the
    /// build instead.
    var origin: RoutineOrigin {
        switch self {
        case .morningBrief: .morningBrief
        case .eveningWrapUp: .eveningWrapUp
        case .weeklyReview: .weeklyReview
        case .overdueWatcher: .overdueWatcher
        case .sleepWatcher: .sleepWatcher
        }
    }
}
