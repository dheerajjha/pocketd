import Foundation

/// The work a task has, once it is known that it has some.
public enum TaskWork: Sendable, Equatable {
    /// Run the rule here. Always possible, in every context.
    case watcher(WatcherRule, notifyWhenEmpty: Bool)
    /// Feed this to the engine. Only ever produced for a context where
    /// `ExecutionContext.mayRunModel` is true — see `ScheduleDispatch`.
    case prompt(PromptHandoff)
}

/// What to do with one task, right now, in this context.
public enum RunPlan: Sendable, Equatable {
    /// Nothing owed. `next` is when something will be, and is `nil` for a
    /// disabled task or a spent one-shot — which is the signal to cancel any
    /// pending notification request rather than leave one queued for a firing
    /// that will never come.
    case idle(next: Date?)

    /// Do it here.
    case run(TaskWork, firing: Date, missed: Int)

    /// It is due and cannot be done here. Tell the user; the thinking happens
    /// when they come back.
    case notify(firing: Date, missed: Int)
}

/// Decides what can be done with a task in a given execution context.
///
/// The entire interesting content of this type is four lines long, and they
/// encode the constraint the feature is built around: a watcher runs anywhere,
/// a prompt runs anywhere but the background, and the background is where most
/// firings land because that is where phones spend their time.
///
/// It is a pure function of a task, a context and a clock, with no I/O, so the
/// behaviour that actually matters — a prompt task never, under any
/// circumstances, being handed to a runner during a background refresh — is
/// something a test can assert exhaustively rather than something reviewed by
/// reading the app target's scheduler.
public enum ScheduleDispatch {

    public static func plan(
        for task: ScheduledTask,
        in context: ExecutionContext,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RunPlan {
        guard task.isEnabled else { return .idle(next: nil) }

        // A promise already made to the user outranks a new firing. The
        // notification for the 07:00 prompt task has been sitting in Notification
        // Centre since breakfast; when the app finally reaches a context that can
        // think, that is the thing the user is expecting to see — not a silent
        // jump to this evening's firing with the morning's quietly dropped.
        if context.mayRunModel,
           let pending = task.pendingRun(now: now, calendar: calendar),
           let handoff = task.handoff(firing: pending.firing) {
            return .run(.prompt(handoff), firing: pending.firing, missed: 0)
        }

        let dueness = task.dueness(now: now, calendar: calendar)
        guard let owed = dueness.owed else { return .idle(next: dueness.next) }

        switch task.body {
        case .watcher(let rule, let notifyWhenEmpty):
            // No model, no GPU, no foreground requirement. This is the case
            // that makes scheduled tasks worth shipping on a phone at all.
            return .run(.watcher(rule, notifyWhenEmpty: notifyWhenEmpty), firing: owed, missed: dueness.missed)

        case .prompt:
            guard context.mayRunModel, let handoff = task.handoff(firing: owed) else {
                // `ExecutionContext.backgroundRefresh` lands here and there is
                // no way around it: Metal refuses a backgrounded app's command
                // buffers, so the model cannot be loaded, let alone run. The
                // notification is not a consolation prize — it is the only
                // honest thing the app can do at this instant, and the work
                // still happens, in `.notificationResponse` or `.deskMode`.
                return .notify(firing: owed, missed: dueness.missed)
            }
            return .run(.prompt(handoff), firing: owed, missed: dueness.missed)
        }
    }
}
