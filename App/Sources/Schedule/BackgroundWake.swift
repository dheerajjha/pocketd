import BackgroundTasks
import Foundation
import PocketdKit

/// The seam between iOS's background machinery and this app's schedule.
///
/// Everything here runs in a context with no user, no screen and — the fact the
/// whole feature is built around — no GPU. A backgrounded app's Metal command
/// buffers come back `notPermitted` on every iPhone, so nothing in this file
/// can load a model, and `ScheduleDispatch` is what makes that structural
/// rather than remembered: asked to plan in `.backgroundRefresh` it never
/// returns prompt work, so there is no branch here that could try.
///
/// What it can do is the watcher half, which is a sort and a template over
/// EventKit rows, and the bookkeeping that keeps the rest of the feature alive:
/// settling firings so they are not run twice, recording the promise a prompt
/// task owes, re-arming the next notification, and asking to be woken again.
///
/// It is an `enum` of static members rather than a type anybody owns, because
/// this is the one part of the app that runs when nothing has been constructed:
/// a background launch creates no scene, so there is no `AppModel`, no view and
/// nobody to hold an instance.
enum BackgroundWake {

    /// The identifier, and it has to match `BGTaskSchedulerPermittedIdentifiers`
    /// in project.yml exactly. Written out on both sides rather than derived
    /// from the bundle identifier — the reasoning is in project.yml, next to the
    /// array, because that is the half a reader is more likely to change.
    static let refreshIdentifier = "dev.pocketd.app.schedule.refresh"

    /// The process's only `ScheduledTaskStore`.
    ///
    /// Shared deliberately, and this is the one thing a caller here must not
    /// work around by constructing its own. The store's `update` is
    /// read-modify-write made indivisible by the actor — written for exactly the
    /// collision this file causes, a background refresh settling the 07:00
    /// firing while the user renames the same task in the app — and an actor
    /// only excludes itself. Two instances over one directory is last-writer-
    /// wins again, with the actor's guarantee on paper and not in force.
    ///
    /// The fallback mirrors `AppModel`'s: `defaultDirectory()` only throws when
    /// Application Support cannot be reached at all, and a temporary directory
    /// at least keeps the process working.
    static let store = ScheduledTaskStore(
        directory: (try? ScheduledTaskStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ScheduledTasks")
    )

    // MARK: - Registration

    /// Claims the refresh identifier. Called from
    /// `didFinishLaunchingWithOptions` and from nowhere else.
    ///
    /// The timing is not a style preference: registering after launch has
    /// finished is an error, and registering the same identifier twice
    /// terminates the app. Both of those are stated in the framework header and
    /// neither is recoverable at runtime, which is why this is a single call
    /// from a single place rather than something a screen does when it appears.
    static func register() {
        let accepted = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshIdentifier,
            // nil: iOS's own background queue. The sweep touches no UI and
            // hops to the main actor only to talk to `NotificationCentre`, so
            // taking the main queue here would buy nothing and block the first
            // frame of a launch that the user initiated.
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                // One identifier is registered and it is a refresh task, so this
                // is unreachable — but an unfinished BGTask is a process iOS
                // kills rather than a warning it logs.
                task.setTaskCompleted(success: false)
                return
            }
            run(refresh)
        }

        if !accepted {
            // False means one thing: the identifier is missing from
            // BGTaskSchedulerPermittedIdentifiers. There is no runtime remedy
            // and no user-facing symptom — the app launches, shows a schedule,
            // and never wakes for it — so the only place to catch it is here,
            // loudly, in a build somebody is watching.
            assertionFailure("\(refreshIdentifier) is not in BGTaskSchedulerPermittedIdentifiers")
        }
    }

    /// Asks iOS to wake the app for the next firing.
    ///
    /// Fire-and-forget, for the call sites that are not `async` — scene phase,
    /// and the save of a task. The work is small and the result is advisory.
    static func scheduleNextRefresh() {
        Task { await submitRefresh() }
    }

    // MARK: - The wake-up

    /// Handles one granted refresh.
    ///
    /// The order is the contract. `expirationHandler` is set **first**, before a
    /// single read has started, because the budget is seconds and iOS shortens
    /// it whenever it likes: a task still running when its time is up has its
    /// process killed outright, and a handler installed after the work began is
    /// a handler that was not there for the run that overran. (It is also why
    /// `ScheduledTaskStore` writes atomically — being killed mid-write is the
    /// expected case here, not the exotic one.)
    ///
    /// Expiry cancels the sweep rather than completing the task from underneath
    /// it, so there is exactly one path to `setTaskCompleted`: the sweep's own
    /// exit, reporting honestly whether it got to the end.
    private static func run(_ task: BGAppRefreshTask) {
        let refresh = RefreshHandle(task)
        // The closure holds the handle rather than the task itself, which keeps
        // iOS's own note about this property true: it clears `expirationHandler`
        // once the handler has fired or the task has completed, precisely to
        // break the cycle a block referencing its own BGTask would make.
        task.expirationHandler = { refresh.expire() }
        refresh.adopt(Task {
            let finished = await sweep()
            refresh.complete(success: finished)
        })
    }

    /// Does everything this app can do without a user, a screen or a GPU.
    ///
    /// Returns whether it reached the end. A cancelled sweep — the refresh ran
    /// out of time — reports false, which is what tells iOS the work is worth
    /// retrying; every firing it did not reach is still owed and still
    /// collapses into one run the next time anything runs at all.
    ///
    /// Hard-coded to `.backgroundRefresh`. A foreground sweep is not this
    /// function with a different argument: it can run models, it has a view to
    /// stream into and a person waiting, and it belongs with the code that owns
    /// the engine.
    static func sweep(now: Date = Date(), calendar: Calendar = .current) async -> Bool {
        let tasks = await store.all()
        guard !tasks.isEmpty else { return true }

        var finished = true
        for task in tasks {
            // Between tasks rather than inside one. A task that has started is
            // two writes from finishing — the run record, then the notification
            // — and stopping between them leaves either a history entry nobody
            // was told about or, worse, a banner for a firing the store still
            // believes is owed and will announce again.
            if Task.isCancelled {
                finished = false
                break
            }

            switch ScheduleDispatch.plan(for: task, in: .backgroundRefresh, now: now, calendar: calendar) {
            case .idle:
                continue

            case .run(let work, let firing, _):
                // Only ever `.watcher` here, and that is the type system's
                // statement rather than this file's: `ScheduleDispatch` will not
                // produce prompt work for a context whose `mayRunModel` is
                // false. Restated as a guard because the alternative is a
                // default branch that silently does nothing if the two ever
                // disagree.
                guard case .watcher(let rule, let notifyWhenEmpty) = work else { continue }
                await settle(rule, of: task, firing: firing, notifyWhenEmpty: notifyWhenEmpty, now: now, calendar: calendar)

            case .notify(let firing, _):
                // A prompt task came due where it cannot think. The promise is
                // recorded against this firing so the app can collect it later —
                // `pendingRun` is what finds it — and settling is what stops the
                // next wake-up from making the same promise again.
                _ = try? await store.update(task.id) {
                    $0.settle(.awaitingForeground(firing: firing, context: .backgroundRefresh))
                }
                await NotificationCentre.shared.announceAwaitingForeground(task, firing: firing)
            }
        }

        // Both of these run even when the sweep was cancelled, because between
        // them they are what makes there be a next time, and both are a couple
        // of calls rather than any reading. Re-arming replaces triggers that
        // have already fired — a non-repeating trigger is spent — and the
        // refresh request was consumed by the wake-up that produced this call,
        // so failing to submit another ends background refresh outright until
        // the user next opens the app.
        //
        // Read back rather than reusing `tasks`: settling changed them, and
        // arming from the pre-settle copy would arm the firing just dealt with.
        let settled = await store.all()
        await NotificationCentre.shared.reconcile(settled, now: now, calendar: calendar)
        // Before `setTaskCompleted`, which the caller does immediately after
        // this returns: the process can be suspended the instant it is called.
        await submitRefresh(tasks: settled, now: now, calendar: calendar)
        return finished
    }

    /// Runs one watcher, records what it found, and says so.
    private static func settle(
        _ rule: WatcherRule,
        of task: ScheduledTask,
        firing: Date,
        notifyWhenEmpty: Bool,
        now: Date,
        calendar: Calendar
    ) async {
        let result = await WatcherEvaluation.run(
            rule,
            now: now,
            calendar: calendar,
            readEvents: { await EventAccess.shared.events(in: $0) },
            readReminders: { await EventAccess.shared.reminders(in: $0) }
        )

        let run: TaskRun = switch result {
        case .found(let report):
            // `Untrusted` because it is: every line is an event title or a
            // reminder name, written by whoever sent the invite, and a stored
            // run record is replayed into later prompts.
            .reported(firing: firing, context: .backgroundRefresh, output: Untrusted(report.text))
        case .nothing:
            .nothingToReport(firing: firing, context: .backgroundRefresh)
        case .unreadable(let authorization, _):
            .unauthorized(authorization, firing: firing, context: .backgroundRefresh)
        }

        // Stored before it is announced. A notification the user acts on and a
        // history that does not have it is the worse order of the two.
        _ = try? await store.update(task.id) { $0.settle(run) }
        await NotificationCentre.shared.announce(
            result, of: task, firing: firing, notifyWhenEmpty: notifyWhenEmpty
        )
    }

    // MARK: - Asking to be woken

    /// Submits the single refresh request iOS allows this app to have pending.
    ///
    /// `earliestBeginDate` is a floor and nothing more. It says "not before
    /// this"; it does not say "then", and iOS answers with its own judgement of
    /// battery, thermals, and how much the user actually opens this app. A wake
    /// may arrive twenty minutes late, six hours late, or never — Background App
    /// Refresh is a switch users turn off, Low Power Mode suspends it outright,
    /// and the simulator never runs one at all, which is why this code cannot be
    /// exercised by running the app on a Mac. (`e -l objc -- (void)[[BGTask-
    /// Scheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"…"]`
    /// in lldb is the only way to see the handler run on demand.)
    ///
    /// That unreliability is the reason the feature is split the way it is. A
    /// watcher's answer is worth having late. A prompt task's due moment is not,
    /// so it is kept by a notification trigger, which fires exactly and needs no
    /// background execution whatsoever.
    private static func submitRefresh(
        tasks: [ScheduledTask]? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        let schedule: [ScheduledTask]
        if let tasks {
            schedule = tasks
        } else {
            schedule = await store.all()
        }

        // `dueness(now:).next` is nil for a disabled task and for a spent
        // one-shot, so an app with nothing scheduled asks for nothing. That is
        // not politeness: iOS budgets background launches against how useful the
        // app has been with them, and waking to find no work is how an app
        // teaches the scheduler to stop bothering.
        guard let earliest = schedule.compactMap({ $0.dueness(now: now, calendar: calendar).next }).min() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = earliest

        do {
            if #available(iOS 27.0, *) {
                // iOS 27 deprecated the throwing form because it could not
                // report every way a submission fails.
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
        } catch {
            // Swallowed, and the reasons are all states rather than faults:
            // `.unavailable` (1) is the simulator, and a user who has switched
            // Background App Refresh off; `.notPermitted` (3) is a build whose
            // Info.plist lost its background mode. None of them has a remedy
            // here, and none of them should take a save or a scene transition
            // down with it — the schedule still arms its notifications, which is
            // the half that does not need this to work.
        }
    }
}

// MARK: - One wake-up's worth of state

/// Owns the `BGAppRefreshTask` for the life of one refresh.
///
/// It exists because a `BGTask` is not `Sendable` and the two things anyone does
/// with one — cancel the work when time runs out, report completion when it
/// finishes — happen from outside the callback it arrived in. Without a box the
/// sweep cannot be handed the task at all: a `Task` closure is `sending`, a
/// parameter belongs to its caller's region, and the compiler refuses the
/// capture. That refusal is right about the general case and wrong about this
/// one, so the exception is made once, here, with the reasoning attached rather
/// than sprinkled as `nonisolated(unsafe)` over the call site.
///
/// `@unchecked Sendable` is earned rather than asserted: every access is under
/// the lock, and `BGTask`'s two methods are documented to be callable from
/// whatever queue the work finished on — Apple's own samples complete one from
/// inside a URLSession callback.
///
/// `complete` is idempotent because the failure it prevents is not a warning.
/// Completing a BGTask twice is API misuse and terminates the process, and the
/// tempting shape — expiry completes it, then the sweep unwinds and completes it
/// again — is exactly that. Here expiry only cancels; the sweep's own exit is
/// the single path to `setTaskCompleted`.
private final class RefreshHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let task: BGAppRefreshTask
    private var sweep: Task<Void, Never>?
    private var isExpired = false
    private var hasCompleted = false

    init(_ task: BGAppRefreshTask) {
        self.task = task
    }

    func adopt(_ sweep: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        // Expiry before the sweep was even handed over is vanishingly unlikely
        // and free to get right; the alternative is a sweep that outlives the
        // task that owns it.
        if isExpired {
            sweep.cancel()
        } else {
            self.sweep = sweep
        }
    }

    /// Time is up. Cancels rather than completes: the sweep is what completes,
    /// and it is mid-write often enough that letting it unwind matters.
    func expire() {
        lock.lock()
        defer { lock.unlock() }
        isExpired = true
        sweep?.cancel()
    }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasCompleted else { return }
        hasCompleted = true
        task.setTaskCompleted(success: success)
    }
}
