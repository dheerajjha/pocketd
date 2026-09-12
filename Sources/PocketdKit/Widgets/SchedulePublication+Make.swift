import Foundation

public extension SchedulePublication {

    /// Builds what a widget may see from what the app knows.
    ///
    /// In `PocketdKit` rather than beside the view that first needed it,
    /// because two processes publish: the app after an edit or a sweep, and a
    /// background refresh after settling a firing with no app around it. Two
    /// implementations would drift, and the one that drifts is the background
    /// one — the path nobody watches.
    ///
    /// Note what this does NOT read. `TaskRun.output` is never touched, so
    /// there is no version of this function that could accidentally put a
    /// model's answer or somebody's event titles on a home screen; the closest
    /// it comes is `Standing(run.outcome)`, which maps a case to a case.
    static func make(
        from tasks: [ScheduledTask],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SchedulePublication {

        // Only enabled tasks can fire, and a paused one appearing as "next up"
        // would be the widget contradicting the switch the user just turned off.
        let live = tasks.filter(\.isEnabled)

        let next = live
            .compactMap { task -> Upcoming? in
                guard let firing = task.dueness(now: now, calendar: calendar).next else { return nil }
                return Upcoming(title: task.title, firing: firing, needsModel: task.body.needsModel)
            }
            .min { $0.firing < $1.firing }

        // Across every task, including disabled ones: a run that happened,
        // happened, and hiding the last thing a task did because it was paused
        // afterwards loses the reason somebody paused it.
        let latest = tasks
            .flatMap { task in
                task.runs
                    // A promise is not a run — the same filter the in-app feed
                    // uses. An owed firing is reported by `waitingCount`, and
                    // counting it here as well describes one firing twice.
                    .filter { !$0.isAwaitingForeground }
                    .map { (title: task.title, run: $0) }
            }
            .max { $0.run.ranAt < $1.run.ranAt }
            .map { Latest(title: $0.title, ranAt: $0.run.ranAt, standing: Standing($0.run.outcome)) }

        return SchedulePublication(
            generatedAt: now,
            next: next,
            latest: latest,
            enabledCount: live.count,
            waitingCount: live.compactMap { $0.pendingRun(now: now, calendar: calendar) }.count
        )
    }
}

public extension SchedulePublication.Standing {
    /// Maps a run's outcome without ever reading its text.
    ///
    /// Takes the outcome rather than the `TaskRun` so there is no call site
    /// holding a run with an `output` on it at the moment it builds something
    /// bound for a home screen.
    init(_ outcome: TaskRun.Outcome) {
        switch outcome {
        case .reported: self = .reported
        case .nothingToReport: self = .nothingToReport
        case .awaitingForeground: self = .waiting
        case .unauthorized, .failed: self = .trouble
        }
    }
}
