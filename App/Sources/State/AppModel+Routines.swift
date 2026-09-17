import Foundation
import PocketdKit

// MARK: - Routines

/// The three things the Routines tab asks of the app, and nothing else.
///
/// An extension rather than members on `AppModel` because everything here is a
/// thin arrangement of machinery that already exists — `RoutineTemplate` builds
/// the task, `saveScheduledTask` persists it and arms its notification,
/// `sweepSchedule` runs what is owed. Keeping the arrangement out of the
/// four-thousand-line file is the point; there is no new state here and there
/// must not be, because a second copy of "what is scheduled" is how a screen
/// and a scheduler come to disagree.
@MainActor
extension AppModel {

    /// Creates a routine from one of the offered templates and saves it.
    ///
    /// The one call the templates grid and the onboarding step both make. It
    /// goes through `saveScheduledTask` rather than to the store, and that is
    /// load-bearing rather than tidy: that method is what asks for notification
    /// permission at the first routine and what arms the trigger afterwards. A
    /// routine written straight to disk is saved correctly, sits in the list
    /// looking scheduled, and never notifies anybody — which is the exact bug
    /// `ScheduleDraft(_ starter:)` was written to avoid in v1.
    ///
    /// - Parameter time: Overrides the template's own default. The editor and
    ///   the onboarding time picker pass one; a tap on a template card does
    ///   not.
    /// - Returns: The saved task, so a caller that wants to open it — the
    ///   editor, prefilled — does not have to search the list for what it just
    ///   made.
    @discardableResult
    func createRoutine(
        from template: RoutineTemplate,
        at time: TimeOfDay? = nil,
        weekdaysOnly: Bool = true
    ) async -> ScheduledTask {
        let task = template.task(time: time, weekdaysOnly: weekdaysOnly)
        await saveScheduledTask(task)
        record(.routineCreated(template: template.origin))
        return task
    }

    /// Prompt runs that were promised and have not been written yet.
    ///
    /// The number on Today's bell and on the results row at the top of
    /// Routines. `ScheduleSummary.pending` is the single reading — it is
    /// `ScheduledTask.pendingRun` per task, which is what decides whether an
    /// uncollected 07:00 is still worth collecting — so this is a count and not
    /// a second opinion.
    var pendingResultsCount: Int {
        ScheduleSummary.pending(in: scheduledTasks).count
    }

    /// Writes whatever is owed, here, now, with somebody watching.
    ///
    /// Deliberately not `runNow(_ task:)`. There is no per-task trigger in this
    /// app and adding one would be a second scheduler: `ScheduleDispatch.plan`
    /// decides what a task may do in a context, it is a pure function, and it
    /// is tested exhaustively so that nothing can quietly disagree with it. A
    /// "run this one now" button would have to either ignore that function —
    /// running a routine that is not due, which is not what the row promises —
    /// or call it and do nothing for every task but the ones a sweep would have
    /// picked up anyway.
    ///
    /// So the results row runs the sweep, in `.foreground`, which is exactly
    /// what the app already does on the way back from the app switcher. The
    /// only difference is that the person asked for it.
    func writePendingResults() {
        sweepSchedule(in: .foreground)
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

    /// The template a saved task came from, if any.
    ///
    /// Matched on the title, which is the only thing a `ScheduledTask` carries
    /// that could say. That is a deliberate limit rather than an oversight: a
    /// stored `template` field would be a second source of truth about a task
    /// the user is free to rename, retime and rewrite until it has nothing to
    /// do with the card it started from, and the one thing it is used for here
    /// — not offering a routine somebody already has — is better served by the
    /// name they are looking at than by a provenance they cannot see.
    static func matching(_ task: ScheduledTask) -> RoutineTemplate? {
        allCases.first { $0.title.caseInsensitiveCompare(task.title) == .orderedSame }
    }
}
