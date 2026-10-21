import Foundation
import PocketdKit

/// The machinery under Routines: the task store, the sweep that runs what is
/// owed, Desk Mode's timer, and the notifications that announce results.
///
/// `AppModel+Routines` is the screen-facing half and stays separate; this is
/// what it arranges.
@MainActor
extension AppModel {

    #if DEBUG
    /// `-pocketd.demoRoutines`: two routines with a run history, for store
    /// captures. A simulator cannot run a routine — the brain never fires there —
    /// so the only way to photograph a result is to write one. Saved straight
    /// through the store rather than `saveScheduledTask`, which would put the
    /// notification permission sheet in the middle of a capture.
    func seedDemoRoutinesIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-pocketd.demoRoutines") else { return }
        let existing = Set(scheduledTasks.map(\.title))
        for task in RoutinePreviewData.tasks where !existing.contains(task.title) {
            try? await tasks.save(task)
        }
        await loadScheduledTasks()
    }
    #endif

    func loadScheduledTasks() async {
        scheduledTasks = await tasks.all()
        // The single funnel every edit, delete and sweep already passes
        // through, which is why the widget is fed from here rather than from
        // each of them. `publish` is a no-op when nothing a widget shows has
        // changed, so the desk sweep's timer does not spend the reload budget.
        SchedulePublisher.publish(scheduledTasks)
    }

    /// Writes a routine and does everything a write owes: the list, the widget,
    /// the permission the first one needs, and the armed notifications.
    ///
    /// Returns whether the file reached the disk. It used to swallow the error
    /// — `try?` around a write a full disk makes throw — and the Routines
    /// screen then had to infer a failure from whether the card came back.
    @discardableResult
    func saveScheduledTask(_ task: ScheduledTask) async -> Bool {
        let saved: Bool
        do {
            try await tasks.save(task)
            saved = true
        } catch {
            saved = false
        }
        await afterScheduleChange(askingPermission: saved)
        return saved
    }

    /// Changes one stored routine in place and does what a save owes.
    ///
    /// Through the store's `update`, which reads, changes and writes inside the
    /// actor: a background refresh settling this morning's run while the
    /// editor saves a new time must not have one of the two writes erase the
    /// other. Returns the routine as written, or `nil` when it no longer exists
    /// or the write failed.
    @discardableResult
    func updateScheduledTask(
        _ id: UUID,
        _ change: @Sendable (inout ScheduledTask) -> Void
    ) async -> ScheduledTask? {
        let written: ScheduledTask?
        do {
            written = try await tasks.update(id, change)
        } catch {
            written = nil
        }
        await afterScheduleChange(askingPermission: written != nil)
        return written
    }

    /// What every change to the schedule is followed by.
    ///
    /// Permission is asked at a save and nowhere else. This app opens without a
    /// single permission prompt — which is unusual enough that people comment
    /// on it — and the moment somebody schedules something is the one moment a
    /// notification permission is obviously about what they just did. It is
    /// asked whenever iOS has never been asked, rather than only at the first
    /// routine: a phone whose routines arrived some other way (a demo seed, a
    /// restore) would otherwise never be asked and never be told anything.
    ///
    /// The list is reloaded here, before returning; the permission and the
    /// arming are queued on `NotificationCentre` and not waited for — see
    /// `enqueue` for the hang that taught that. A new or edited routine has a
    /// different next firing, and an edited one may have a request armed for a
    /// firing that no longer exists.
    private func afterScheduleChange(askingPermission: Bool) async {
        await loadScheduledTasks()
        NotificationCentre.shared.scheduleChanged(askingPermission: askingPermission) { self.scheduledTasks }
    }

    func deleteScheduledTask(_ id: UUID) async {
        await tasks.delete(id)
        // Withdrawn, or iOS delivers a notification at 07:00 for a routine the
        // user deleted on Tuesday: a pending request outlives the file it was
        // armed from.
        await afterScheduleChange(askingPermission: false)
    }

    /// For the Data screen's delete-everything, which has to reach the files it
    /// counts. Goes through the store rather than the in-memory list for the
    /// reason `deleteAllConversations` gives: `all()` skips a file it cannot
    /// decode, so deleting only what the list knows about would leave real
    /// tasks on disk and report success.
    func deleteAllScheduledTasks() async {
        await cancelScheduleSweep()
        await tasks.deleteAll()
        await afterScheduleChange(askingPermission: false)
    }

    /// How often Desk Mode looks.
    ///
    /// A minute, because that is the resolution the schedule itself has —
    /// `TimeOfDay` is two numbers off a clock face — so a task due at 09:00 runs
    /// by 09:01 at worst and nothing finer would be visible. It is also the
    /// interval `DeskModeView` already drifts its content on, and a phone left
    /// on a charger for eight hours should not be waking up more often than the
    /// screen it is drawing.
    private static let deskSweepSeconds = 60

    /// Runs whatever this context allows, once.
    ///
    /// Deliberately not `async`: the callers are scene-phase changes and a
    /// timer, none of which can wait out a sixty-second generation, and a sweep
    /// that blocked the transition would make the app look hung on the way back
    /// from the app switcher.
    func sweepSchedule(in context: ExecutionContext) {
        guard scheduleSweep == nil, scheduleRunner != nil else { return }
        scheduleSweep = Task { [weak self] in
            defer { self?.scheduleSweep = nil }
            guard let self, let runner = self.scheduleRunner else { return }
            // The same suppression a generation in Chat takes, and for the same
            // reason: `releaseIfIdle` would otherwise unload the model out from
            // under an unattended run — which is exactly the state Desk Mode is
            // in, idle by every measure this app has, for hours.
            self.suppressAutoRelease("scheduled")
            defer { self.resumeAutoRelease("scheduled") }
            let completions = await runner.sweep(in: context)
            await self.loadScheduledTasks()
            // Queued rather than awaited: the sweep's slot must free up when
            // its runs are written, not when the notification daemon answers.
            // A sweep that waited on it would, with the daemon slow, hold
            // `scheduleSweep` and so block every sweep after it.
            NotificationCentre.shared.enqueue { await self.announceSchedule(completions) }
        }
    }

    /// Says what a sweep produced, and re-arms what comes next.
    ///
    /// Announced from here rather than from inside `ScheduleRunner` so that both
    /// halves of this app's scheduling — `BackgroundWake`'s refresh and this
    /// foreground sweep — post through the one type that knows how loudly to do
    /// it. `NotificationCentre` is what decides between an alert and a silent
    /// update for a firing the user has already been buzzed about, and that
    /// decision is only right if every announcement goes through it.
    ///
    /// `reconcile` runs whether or not anything ran, which is the half that is
    /// easy to forget: a notification trigger is spent once it fires, so a task
    /// that has just been collected needs its *next* firing armed or it never
    /// notifies again — and a task disabled or deleted since the last sweep
    /// needs its pending request withdrawn.
    private func announceSchedule(_ completions: [ScheduleRunner.Completion]) async {
        for completion in completions {
            if let watched = completion.watched {
                await NotificationCentre.shared.announce(
                    watched,
                    of: completion.task,
                    firing: completion.run.firing,
                    notifyWhenEmpty: completion.notifyWhenEmpty
                )
            } else if completion.run.isAwaitingForeground {
                await NotificationCentre.shared.announceAwaitingForeground(
                    completion.task,
                    firing: completion.run.firing
                )
            }
        }
        // From the store's own answer rather than from the completions above:
        // settling changed the tasks, and arming from the pre-settle copy would
        // arm the firing that has just been dealt with.
        await NotificationCentre.shared.reconcile(scheduledTasks)
    }

    /// Stops a scheduled run and waits for it to finish unwinding.
    ///
    /// Awaited rather than fired and forgotten, for the reason
    /// `releaseForBackground` flushes the conversation before doing anything
    /// else: suspension is the last moment this process is guaranteed to run,
    /// and the run record for the generation being cancelled is written on the
    /// way out of it.
    ///
    /// The slot is cleared by the task's own `defer` rather than here, so a
    /// sweep started while the previous one is still unwinding cannot end up
    /// holding a handle that something else already nilled.
    func cancelScheduleSweep() async {
        guard let sweep = scheduleSweep else { return }
        sweep.cancel()
        await sweep.value
    }

    /// Starts, restarts or tears down the Desk Mode sweep.
    ///
    /// Desk Mode is the only unattended state in this app where a model may
    /// legally run — the app is in the foreground so Metal answers, nobody is
    /// waiting so a thirty-second generation costs nothing, and the phone is on
    /// a charger so the battery argument does not apply — which makes this
    /// timer the place the prompt half of scheduling actually lives.
    ///
    /// Shaped like `restartIdleWatch`, down to the cancellation check on both
    /// sides of the sleep: a `Task.sleep` that is cancelled returns rather than
    /// throwing into the loop, and without the second check the body runs once
    /// more after the handle has been dropped.
    func restartDeskSweep() {
        deskSweep?.cancel()
        guard deskMode else { deskSweep = nil; return }
        deskSweep = Task { [weak self] in
            // Immediately, before the first sleep. Putting the phone on the
            // charger is itself the event: waiting a minute to notice a task
            // that has been due since breakfast would make the feature look
            // broken in exactly the moment somebody is watching it start.
            self?.sweepSchedule(in: .deskMode)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.deskSweepSeconds))
                if Task.isCancelled { return }
                guard let self else { return }
                self.sweepSchedule(in: .deskMode)
            }
        }
    }
}
