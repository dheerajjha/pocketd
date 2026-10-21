#if DEBUG
import Foundation
import PocketdKit

/// Routines with a history, for previews and for `-pocketd.demoRoutines`.
///
/// A simulator cannot produce one — no background refresh ever runs there, and
/// the brain never fires a routine — so the only way to photograph a result is
/// to write one. Compiled into Debug only: nothing in a Release build needs to
/// fabricate a run.
///
/// Every result is computed from the seeded day (`DemoDay`) by the same code
/// the real routines run: the brief's line is `BriefPrompt.notificationSentence`
/// over that day, and the nudge's report is what `WatcherEvaluation` writes.
/// The walkthrough found a card saying "Two reminders are due today" beside a
/// Today tile reading "1 due", because the card's sentence was typed by hand.
enum RoutinePreviewData {
    static var tasks: [ScheduledTask] {
        [morningBrief, overdueNudge]
    }

    /// The demo clock's day, at a given hour: the runs below happened this
    /// morning, so the cards read as having run today.
    private static func today(at hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: DemoClock.now) ?? DemoClock.now
    }

    private static func daysAgo(_ days: Int, at hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: today(at: hour, minute)) ?? today(at: hour, minute)
    }

    /// What the brief's banner said at `date` about the seeded day.
    private static func briefLine(at date: Date) -> String {
        BriefPrompt.notificationSentence(snapshot: DemoDay.snapshot(at: date), now: date) ?? "Ready on Today."
    }

    static var morningBrief: ScheduledTask {
        var task = RoutineTemplate.morningBrief.task(now: daysAgo(6, at: 7, 30))
        task.runs = [
            .reported(
                firing: daysAgo(1, at: 7, 30),
                ranAt: daysAgo(1, at: 7, 30),
                context: .backgroundRefresh,
                // Written out rather than read, for `DemoDay.yesterdaysMorningBrief`'s
                // reason — the seed stages no rows for yesterday — and from the
                // same facts: standup at 9:30, two due, a 7h 10m night.
                output: Untrusted(
                    "Your next event is at 9:30\u{202F}AM, you have 2 reminders due today, and you slept 7h 10m."
                )
            ),
            .reported(
                firing: today(at: 7, 30),
                ranAt: today(at: 7, 30),
                context: .backgroundRefresh,
                output: Untrusted(briefLine(at: today(at: 7, 30)))
            ),
        ]
        task.settledThrough = DemoClock.now
        return task
    }

    static var overdueNudge: ScheduledTask {
        var task = RoutineTemplate.overdueWatcher.task(now: daysAgo(3, at: 9, 0))
        task.runs = [
            .nothingToReport(
                firing: daysAgo(1, at: 9, 0),
                ranAt: daysAgo(1, at: 9, 0),
                context: .backgroundRefresh
            ),
            .reported(
                firing: today(at: 9, 0),
                ranAt: today(at: 9, 0),
                context: .backgroundRefresh,
                output: Untrusted(DemoDay.overdueNudge(at: today(at: 9, 0)))
            ),
        ]
        task.settledThrough = DemoClock.now
        return task
    }
}
#endif
