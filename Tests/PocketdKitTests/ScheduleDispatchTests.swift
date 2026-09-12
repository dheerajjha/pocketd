import Foundation
import Testing
@testable import PocketdKit

/// The constraint the whole feature is built around, asserted rather than
/// documented.
///
/// llama.cpp runs every layer on Metal, and a backgrounded app's Metal command
/// buffers are refused — background GPU access is iPad M3 and better, which is
/// no iPhone this ships to. So a task that needs the model cannot think while
/// the app is closed, however exact its due time is. What follows from that is
/// the whole design: watchers run anywhere, prompt tasks are notified in the
/// background and thought about in the foreground, and Desk Mode — foreground,
/// on a charger, unattended for hours — is where unattended inference is legal.
///
/// The single most important assertion in this file is
/// `promptTaskIsNeverRunInTheBackground`: it walks every execution context and
/// fails if a prompt task is ever handed to a runner in one that cannot load a
/// model. That is a promise about hardware, and hardware does not negotiate.
@Suite("Scheduled task dispatch")
struct ScheduleDispatchTests {

    // MARK: - Fixtures

    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static let seven = TimeOfDay(hour: 7, minute: 0)
    /// Created the evening before, so its first real firing is the next morning.
    private static let created = date(2026, 9, 14, 20, 0)
    private static let firstFiring = date(2026, 9, 15, 7, 0)
    private static let justAfterFiring = date(2026, 9, 15, 7, 1)

    private static func prompt(_ text: String = "What is on today, and what should I do first?") -> ScheduledTask {
        ScheduledTask(
            title: "Morning briefing",
            body: .prompt(text),
            recurrence: .daily(at: seven),
            createdAt: created
        )
    }

    private static func watcher(notifyWhenEmpty: Bool = false) -> ScheduledTask {
        ScheduledTask(
            title: "Anything due today",
            body: .watcher(rule: .reminders(.today), notifyWhenEmpty: notifyWhenEmpty),
            recurrence: .daily(at: seven),
            createdAt: created
        )
    }

    private func plan(_ task: ScheduledTask, _ context: ExecutionContext, now: Date = justAfterFiring) -> RunPlan {
        ScheduleDispatch.plan(for: task, in: context, now: now, calendar: Self.calendar())
    }

    // MARK: - The hardware promise

    @Test("a prompt task is never handed to a runner in a context that cannot load a model")
    func promptTaskIsNeverRunInTheBackground() {
        // Exhaustive over the contexts, so adding one without thinking about
        // Metal breaks this test rather than shipping a task that silently
        // fails at 7am on somebody's phone.
        for context in ExecutionContext.allCases {
            switch plan(Self.prompt(), context) {
            case .run(.prompt, _, _):
                #expect(context.mayRunModel, "a prompt task was dispatched into \(context.rawValue)")
            case .notify:
                #expect(context.mayRunModel == false, "\(context.rawValue) can think and was told to notify instead")
            case .run(.watcher, _, _), .idle:
                Issue.record("a due prompt task produced neither a run nor a notification in \(context.rawValue)")
            }
        }
    }

    @Test("a due prompt task in the background is notified, not run")
    func promptInBackground() {
        #expect(plan(Self.prompt(), .backgroundRefresh) == .notify(firing: Self.firstFiring, missed: 0))
    }

    @Test("the same task in the foreground is run")
    func promptInForeground() {
        guard case .run(.prompt(let handoff), let firing, _) = plan(Self.prompt(), .foreground) else {
            Issue.record("expected a prompt run")
            return
        }
        #expect(firing == Self.firstFiring)
        #expect(handoff.prompt == "What is on today, and what should I do first?")
        #expect(handoff.firing == Self.firstFiring)
    }

    @Test("Desk Mode runs it too, which is the point of Desk Mode")
    func promptInDeskMode() {
        // Foreground, so Metal works; on a charger, so the battery argument
        // does not apply; nobody watching, so a thirty-second generation costs
        // nothing. It is the one state this app has where an unattended
        // generation is legal, and treating it as a first-class execution
        // context rather than a screensaver is what makes a 7am briefing
        // actually arrive at 7am for a phone left on a desk.
        guard case .run(.prompt, let firing, _) = plan(Self.prompt(), .deskMode) else {
            Issue.record("expected a prompt run in Desk Mode")
            return
        }
        #expect(firing == Self.firstFiring)
        #expect(ExecutionContext.deskMode.mayRunModel)
        #expect(ExecutionContext.deskMode.isAttended == false)
    }

    @Test("a watcher runs in the background, which is why watchers exist")
    func watcherInBackground() {
        guard case .run(.watcher(let rule, let notifyWhenEmpty), let firing, _) = plan(Self.watcher(), .backgroundRefresh) else {
            Issue.record("expected a watcher run")
            return
        }
        #expect(rule == .reminders(.today))
        #expect(notifyWhenEmpty == false)
        #expect(firing == Self.firstFiring)
    }

    @Test("a watcher runs in every context, because it needs nothing but the CPU")
    func watcherRunsEverywhere() {
        for context in ExecutionContext.allCases {
            guard case .run(.watcher, _, _) = plan(Self.watcher(), context) else {
                Issue.record("a watcher declined to run in \(context.rawValue)")
                continue
            }
        }
    }

    @Test("notifyWhenEmpty travels with the rule rather than being decided by the runner")
    func notifyWhenEmptyIsCarried() {
        guard case .run(.watcher(_, let notifyWhenEmpty), _, _) = plan(Self.watcher(notifyWhenEmpty: true), .backgroundRefresh) else {
            Issue.record("expected a watcher run")
            return
        }
        #expect(notifyWhenEmpty)
    }

    // MARK: - Not due

    @Test("nothing owed is idle, and says when something will be")
    func idleReportsTheNextFiring() {
        #expect(plan(Self.prompt(), .foreground, now: Self.date(2026, 9, 14, 21, 0))
                == .idle(next: Self.firstFiring))
    }

    @Test("a disabled task is idle with nothing to schedule")
    func disabledIsInert() {
        var task = Self.prompt()
        task.isEnabled = false
        // nil rather than a date: the app cancels its pending notification
        // request off this, and a date here leaves one queued for a firing that
        // will not happen.
        #expect(plan(task, .deskMode) == .idle(next: nil))
        #expect(plan(task, .backgroundRefresh) == .idle(next: nil))
    }

    @Test("a spent one-shot is idle forever, not due forever")
    func spentOneShot() {
        var task = Self.prompt()
        task.recurrence = .once(Self.firstFiring)
        task.settle(.reported(firing: Self.firstFiring, ranAt: Self.justAfterFiring,
                              context: .foreground, output: Untrusted("done")),
                    at: Self.justAfterFiring)
        #expect(plan(task, .foreground, now: Self.date(2026, 9, 16, 9, 0)) == .idle(next: nil))
    }

    @Test("missed firings reach the plan so the UI can say the schedule was not kept")
    func missedReachesThePlan() {
        var task = Self.watcher()
        task.settledThrough = Self.firstFiring
        guard case .run(_, let firing, let missed) = plan(task, .backgroundRefresh, now: Self.date(2026, 9, 18, 8, 0)) else {
            Issue.record("expected a run")
            return
        }
        #expect(firing == Self.date(2026, 9, 18, 7, 0))
        // The 16th and the 17th. One run, not three — but the user is told.
        #expect(missed == 2)
    }

    // MARK: - The promise a notification makes

    @Test("a notified prompt task is collected when the app reaches somewhere it can think")
    func pendingRunIsCollected() {
        var task = Self.prompt()
        // What the background refresh did at 07:00.
        task.settle(.awaitingForeground(firing: Self.firstFiring, ranAt: Self.firstFiring,
                                        context: .backgroundRefresh),
                    at: Self.firstFiring)
        // Settled, so nothing is *due* any more...
        #expect(task.dueness(now: Self.date(2026, 9, 15, 9, 40), calendar: Self.calendar()).owed == nil)

        // ...but the promise stands, and the tap at 09:40 is what collects it.
        guard case .run(.prompt(let handoff), let firing, _) =
                plan(task, .notificationResponse, now: Self.date(2026, 9, 15, 9, 40)) else {
            Issue.record("the notification tap found nothing to do")
            return
        }
        #expect(firing == Self.firstFiring)
        #expect(handoff.firing == Self.firstFiring)
    }

    @Test("Desk Mode collects an uncollected promise as readily as a tap does")
    func pendingRunIsCollectedInDeskMode() {
        var task = Self.prompt()
        task.settle(.awaitingForeground(firing: Self.firstFiring, ranAt: Self.firstFiring,
                                        context: .backgroundRefresh),
                    at: Self.firstFiring)
        guard case .run(.prompt, _, _) = plan(task, .deskMode, now: Self.date(2026, 9, 15, 9, 40)) else {
            Issue.record("Desk Mode left an outstanding promise sitting there")
            return
        }
    }

    @Test("a promise is not collected in the background, where it still cannot be kept")
    func pendingRunIsNotCollectedInBackground() {
        var task = Self.prompt()
        task.settle(.awaitingForeground(firing: Self.firstFiring, ranAt: Self.firstFiring,
                                        context: .backgroundRefresh),
                    at: Self.firstFiring)
        // The next background wake-up must not re-notify for the same firing
        // either: `settledThrough` moved when the promise was made.
        #expect(plan(task, .backgroundRefresh, now: Self.date(2026, 9, 15, 9, 40))
                == .idle(next: Self.date(2026, 9, 16, 7, 0)))
    }

    @Test("an uncollected promise lapses once the next firing replaces it")
    func pendingRunLapses() {
        var task = Self.prompt()
        task.settle(.awaitingForeground(firing: Self.firstFiring, ranAt: Self.firstFiring,
                                        context: .backgroundRefresh),
                    at: Self.firstFiring)

        // Tomorrow morning. Running yesterday's "what is on today" now would
        // answer a question about the wrong day, which is worse than not
        // answering it — so the promise expires against the schedule rather
        // than against a fixed staleness window.
        let tomorrow = Self.date(2026, 9, 16, 8, 0)
        #expect(task.pendingRun(now: tomorrow, calendar: Self.calendar()) == nil)

        guard case .run(.prompt, let firing, _) = plan(task, .foreground, now: tomorrow) else {
            Issue.record("expected today's firing to be run")
            return
        }
        #expect(firing == Self.date(2026, 9, 16, 7, 0))
    }

    @Test("a one-shot's promise has no successor, so it stands until collected")
    func oneShotPromiseStands() {
        var task = Self.prompt()
        task.recurrence = .once(Self.firstFiring)
        task.settle(.awaitingForeground(firing: Self.firstFiring, ranAt: Self.firstFiring,
                                        context: .backgroundRefresh),
                    at: Self.firstFiring)
        // Dropping it on a timer would discard the only firing the task will
        // ever have.
        let muchLater = Self.date(2026, 9, 25, 12, 0)
        #expect(task.pendingRun(now: muchLater, calendar: Self.calendar()) != nil)
        guard case .run(.prompt, _, _) = plan(task, .foreground, now: muchLater) else {
            Issue.record("a one-shot promise was silently dropped")
            return
        }
    }

    // MARK: - Settling

    @Test("collecting a promise replaces its placeholder rather than doubling the history")
    func collectingReplacesThePlaceholder() {
        var task = Self.prompt()
        task.settle(.awaitingForeground(firing: Self.firstFiring, ranAt: Self.firstFiring,
                                        context: .backgroundRefresh),
                    at: Self.firstFiring)
        let collected = Self.date(2026, 9, 15, 9, 40)
        task.settle(.reported(firing: Self.firstFiring, ranAt: collected,
                              context: .notificationResponse, output: Untrusted("Two meetings.")),
                    at: collected)

        // One row for one firing. Showing both "awaiting" and "reported" for
        // 07:00 is describing one event twice; the run's context is what
        // records that it was deferred.
        #expect(task.runs.count == 1)
        #expect(task.runs.first?.context == .notificationResponse)
        #expect(task.runs.first?.output?.attackerControlledValue() == "Two meetings.")
    }

    @Test("an older promise is marked lapsed rather than quietly deleted")
    func olderPromisesLapse() {
        var task = Self.prompt()
        task.settle(.awaitingForeground(firing: Self.firstFiring, ranAt: Self.firstFiring,
                                        context: .backgroundRefresh),
                    at: Self.firstFiring)
        let second = Self.date(2026, 9, 16, 7, 0)
        task.settle(.awaitingForeground(firing: second, ranAt: second, context: .backgroundRefresh), at: second)

        #expect(task.runs.count == 2)
        // Visible in the history, because a user whose prompt tasks never get
        // collected should be able to see that — the remedy is to make it a
        // watcher, or to leave the phone in Desk Mode.
        #expect(task.runs.first?.outcome == .failed(.lapsed))
        #expect(task.runs.last?.isAwaitingForeground == true)
        #expect(task.lastCompletedRun?.outcome == .failed(.lapsed))
    }

    @Test("settling never winds the schedule backwards")
    func settlingIsMonotonic() {
        var task = Self.watcher()
        let later = Self.date(2026, 9, 18, 7, 0)
        task.settle(.nothingToReport(firing: later, context: .backgroundRefresh), at: later)
        // Collecting a promise settles a firing the task has already passed.
        // Assignment rather than `max` here would make every firing since then
        // due all over again.
        task.settle(.reported(firing: Self.firstFiring, ranAt: later, context: .foreground,
                              output: Untrusted("late")),
                    at: later)
        #expect(task.settledThrough == later)
    }

    @Test("the run history is bounded, oldest first out")
    func historyIsTrimmed() {
        var task = Self.watcher()
        for day in 1...(ScheduledTask.runHistoryLimit + 5) {
            let firing = Self.date(2026, 10, day, 7, 0)
            task.settle(.nothingToReport(firing: firing, context: .backgroundRefresh), at: firing)
        }
        // The store rewrites the whole task on every settle, so an unbounded
        // history makes each background wake-up slower than the last, forever.
        #expect(task.runs.count == ScheduledTask.runHistoryLimit)
        #expect(task.runs.first?.firing == Self.date(2026, 10, 6, 7, 0))
        #expect(task.runs.last?.firing == Self.date(2026, 10, 25, 7, 0))
    }

    // MARK: - The handoff

    @Test("a handoff reaches personal data as itself, not as the chat tab")
    func handoffOrigin() throws {
        let task = Self.prompt()
        let handoff = try #require(task.handoff(firing: Self.firstFiring))

        // `ToolContext.origin` fails closed to `.network`, so a scheduled
        // generation that binds nothing gets every personal-data tool refusing
        // — the 7am briefing comes back saying "Personal data is not available
        // to network clients", which is useless and, since the caller is the
        // phone itself, untrue. So it must reach personal data.
        #expect(handoff.origin.mayReachPersonalData)

        // But NOT by claiming to be `.onDeviceChat`, which this asserted for
        // one commit. That case means a human is holding the phone, and
        // forging it turns `mayReachPersonalData` from a fact derived from the
        // accepted socket into a claim the caller makes about itself — the
        // forgeable property the whole type exists to avoid.
        #expect(handoff.origin != .onDeviceChat)
        #expect(handoff.origin == .scheduledTask(id: task.id))

        // And it tells the truth about the thing that is actually different:
        // at 7am there is nobody there.
        #expect(handoff.origin.hasSomeoneWatching == false)
    }

    @Test("a watcher has no prompt to hand over")
    func watcherHasNoHandoff() {
        #expect(Self.watcher().handoff(firing: Self.firstFiring) == nil)
        #expect(Self.watcher().body.needsModel == false)
        #expect(Self.prompt().body.needsModel)
    }
}
