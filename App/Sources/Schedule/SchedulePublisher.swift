import Foundation
import PocketdKit
import WidgetKit

/// Keeps the widget's file in step with the schedule, from both processes.
///
/// Two callers, and they are the two that can change a task: the app, through
/// `AppModel.loadScheduledTasks()` — the single funnel every edit, delete and
/// sweep already passes through — and a background refresh, after it settles a
/// firing with no app around it. One helper rather than two call sites of the
/// same three lines, because the one that would drift is the background one.
enum SchedulePublisher {

    private static let store = SchedulePublicationStore()

    /// The last thing written, so an unchanged schedule costs nothing.
    ///
    /// `nonisolated(unsafe)` with a lock rather than an actor: this is read and
    /// written from the main actor and from a background refresh that has no
    /// actor at all, and an actor here would make `publish` async at a call
    /// site inside `setTaskCompleted`'s window.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastPublished: SchedulePublication?

    /// Publishes if anything a widget could show has actually changed.
    ///
    /// The guard is not an optimisation. Desk Mode sweeps on a timer, so
    /// publishing unconditionally would call `WidgetCenter.reloadTimelines`
    /// every sweep forever — and a widget's reloads are a budget iOS enforces
    /// by ignoring you, so spending them on identical content buys a widget
    /// that stops updating when something finally does change.
    static func publish(_ tasks: [ScheduledTask], now: Date = Date()) {
        let publication = SchedulePublication.make(from: tasks, now: now)

        lock.lock()
        // `generatedAt` differs on every call by construction, so the
        // comparison has to ignore it or the guard never fires once.
        let unchanged = lastPublished.map { $0.isEquivalent(to: publication) } ?? false
        if !unchanged { lastPublished = publication }
        lock.unlock()

        guard !unchanged else { return }
        guard store.write(publication) else { return }
        // Only this kind. `reloadAllTimelines` would also reload widgets this
        // app has not written yet, and the budget is shared.
        WidgetCenter.shared.reloadTimelines(ofKind: "dev.pocketd.widget.schedules")
    }

    // There is deliberately no `withdraw()`. Wiping the file looked necessary
    // — a widget still offering "Morning briefing, 7:00" after the task behind
    // it was erased is the deletion having visibly not happened — but
    // `deleteAllScheduledTasks()` goes through `loadScheduledTasks()` like
    // every other change, which publishes a snapshot of nothing, and the widget
    // renders that as "No scheduled tasks". A second path to the same state
    // would be one more thing to keep in step for no behaviour.
}

private extension SchedulePublication {
    /// Equal in everything a widget renders, which excludes when it was made.
    func isEquivalent(to other: SchedulePublication) -> Bool {
        next == other.next
            && latest == other.latest
            && enabledCount == other.enabledCount
            && waitingCount == other.waitingCount
    }
}
