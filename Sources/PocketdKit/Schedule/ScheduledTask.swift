import Foundation

// MARK: - The two kinds of task

/// What a scheduled task actually does, split by the one thing that decides
/// where it can run.
///
/// This enum is the load-bearing part of the whole feature. A **watcher** is a
/// deterministic rule over calendar events or reminders, rendered from a
/// template: no model, a few milliseconds of CPU, and therefore a real answer
/// produced inside a `BGAppRefreshTask` while the app is closed. A **prompt**
/// needs the model, and the model needs Metal, and Metal is refused to a
/// backgrounded app on every iPhone this ships to — so a prompt task's due time
/// can be exact while its thinking is not, and the thinking happens in the
/// foreground: on the notification tap, when the app is next opened, or in Desk
/// Mode, which is the one state where nobody is waiting and the GPU is legal.
///
/// Keeping them as two cases rather than one type with a `usesModel` flag is
/// what makes the confusion unrepresentable. A watcher carries a `WatcherRule`,
/// which `WatcherEvaluation` can run anywhere; a prompt carries text, and there
/// is no function in this package that turns text into an answer. Nothing in
/// PocketdKit can accidentally try to think in the background, because the
/// machinery to think is not here.
public enum TaskBody: Sendable, Codable, Equatable {

    /// - Parameter notifyWhenEmpty: Whether "nothing today" is worth a
    ///   notification. Off by default at every call site that builds one,
    ///   because a daily watcher that buzzes to say nothing happened is the
    ///   fastest way to get the app's notifications switched off. Some watchers
    ///   genuinely want it — "nothing on tomorrow" is a result somebody asked
    ///   for — which is why it is a stored answer and not a rule.
    ///
    ///   It sits inside this case rather than on `ScheduledTask` so that a
    ///   prompt task cannot carry a setting that means nothing for it.
    case watcher(rule: WatcherRule, notifyWhenEmpty: Bool)

    /// The user's own words, so a plain `String`: this is the one piece of text
    /// in the whole feature that arrives from the keyboard of the person who
    /// owns the phone. Everything a task *reads* is `Untrusted`.
    case prompt(String)

    /// Whether running this requires the GPU, and therefore the foreground.
    public var needsModel: Bool {
        switch self {
        case .watcher: false
        case .prompt: true
        }
    }
}

/// Everything the foreground runner needs to execute a prompt task, and nothing
/// it could use to execute one somewhere it should not.
///
/// Derived, never stored: there is no `Codable` conformance and no public
/// initialiser, so the only way to hold one is to have asked a `ScheduledTask`
/// for it. That is what keeps `origin` honest.
public struct PromptHandoff: Sendable, Equatable {
    public let taskID: UUID
    public let title: String
    public let prompt: String
    /// The scheduled instant this run settles, which is generally not now.
    public let firing: Date

    /// The origin the run adopts: `.scheduledTask(id:)`, and specifically NOT
    /// `.onDeviceChat`.
    ///
    /// It was `.onDeviceChat` for one commit, with a persuasive comment, and
    /// that is worth leaving on the record because the argument was good and
    /// the conclusion was wrong. `ToolContext.origin` fails closed to
    /// `.network`, so a scheduled run that sets nothing has every personal-data
    /// tool refuse it — the 7am briefing comes back saying "Personal data is
    /// not available to network clients", which is useless and untrue. The
    /// tempting repair is to claim to be the chat tab.
    ///
    /// That repair costs the thing the type exists for. `.onDeviceChat` means
    /// a human is holding this phone. Forging it converts `mayReachPersonalData`
    /// from a fact derived from the accepted socket into a claim the caller
    /// makes about itself — which is precisely the forgeable property this enum
    /// was written to avoid, and the reason the comment at the top of
    /// RequestOrigin.swift talks about X-Forwarded-For.
    ///
    /// So the run gets its own case, which reaches personal data deliberately
    /// and answers `hasSomeoneWatching` honestly with false.
    public let origin: RequestOrigin

    init(taskID: UUID, title: String, prompt: String, firing: Date) {
        self.taskID = taskID
        self.title = title
        self.prompt = prompt
        self.firing = firing
        self.origin = .scheduledTask(id: taskID)
    }
}

// MARK: - The task

/// A scheduled, recurring task.
public struct ScheduledTask: Sendable, Codable, Equatable, Identifiable {

    /// How many runs are kept.
    ///
    /// Twenty is roughly three weeks of a daily task, which is long enough to
    /// answer "has this been working" and short enough that the file stays a
    /// couple of kilobytes. The store rewrites the whole task on every settle,
    /// so an unbounded history would make each background wake-up a little
    /// slower than the last, forever.
    public static let runHistoryLimit = 20

    public var id: UUID
    /// What the user called it. Their own text.
    public var title: String
    public var body: TaskBody
    public var recurrence: Recurrence
    /// Off means it keeps its schedule and produces nothing — the state a user
    /// wants when they are on holiday, and the one a delete cannot express.
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    /// The latest firing already dealt with.
    ///
    /// Starts at `createdAt`, and that single line is the answer to the whole
    /// "task created in the past" family of bugs. A daily 09:00 task created at
    /// 14:00 has a firing four and a half hours behind it; without this it is
    /// due the instant it is saved, and the user's reward for scheduling a
    /// morning briefing is a morning briefing at teatime.
    ///
    /// It also advances past every missed firing when one is settled, which is
    /// what collapses three days in a drawer into one notification rather than
    /// three.
    public var settledThrough: Date

    /// What happened, newest last.
    public var runs: [TaskRun]

    public init(
        id: UUID = UUID(),
        title: String,
        body: TaskBody,
        recurrence: Recurrence,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        settledThrough: Date? = nil,
        runs: [TaskRun] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.recurrence = recurrence
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.settledThrough = settledThrough ?? createdAt
        self.runs = runs
    }

    // MARK: - The clock

    /// Whether anything is owed right now, and when the next firing lands.
    ///
    /// A disabled task is never due and reports no next firing: the UI must not
    /// show a countdown for something that will not happen, and the app must
    /// not hold a notification request for it.
    public func dueness(now: Date = Date(), calendar: Calendar = .current) -> Dueness {
        guard isEnabled else { return .idle }
        return .of(recurrence, settledThrough: settledThrough, now: now, calendar: calendar)
    }

    /// The run that was promised to the user and has not been collected yet.
    ///
    /// A prompt task that came due in the background was notified, not run, and
    /// its record says `.awaitingForeground`. That promise stays outstanding
    /// until the *next firing replaces it* — a daily task's uncollected 07:00
    /// lapses when tomorrow's 07:00 arrives, a weekly one gets a week. Expressed
    /// against the recurrence rather than as a fixed staleness window because
    /// the right answer genuinely differs per task, and "how long is one of
    /// these worth" is a question the schedule has already answered.
    ///
    /// `.once` has no successor to replace it, so its promise stands until
    /// collected. Dropping it on a timer would discard the only firing the task
    /// will ever have.
    public func pendingRun(now: Date = Date(), calendar: Calendar = .current) -> TaskRun? {
        guard isEnabled, let candidate = runs.last(where: \.isAwaitingForeground) else { return nil }
        if let successor = FireSequence.next(after: candidate.firing, of: recurrence, calendar: calendar),
           successor <= now {
            return nil
        }
        return candidate
    }

    /// The prompt task's work, packaged for a runner that can actually think.
    /// `nil` for a watcher, which has no prompt to hand over.
    public func handoff(firing: Date) -> PromptHandoff? {
        guard case .prompt(let text) = body else { return nil }
        return PromptHandoff(taskID: id, title: title, prompt: text, firing: firing)
    }

    // MARK: - Settling

    /// Records what happened and moves the task past that firing.
    ///
    /// One call rather than three assignments because the three have to happen
    /// together. Appending a run without advancing `settledThrough` means the
    /// next background wake-up finds the same firing still owed and runs it
    /// again — which for a watcher is a duplicate notification every fifteen
    /// minutes until the day turns over.
    public mutating func settle(_ run: TaskRun, at moment: Date = Date()) {
        // The promise for this exact firing has now been kept, so its
        // placeholder goes: a list showing both "awaiting" and "reported" for
        // 07:00 is describing one event twice. The new run's `context` —
        // `.notificationResponse`, or `.deskMode` — is what records that it was
        // deferred.
        runs.removeAll { $0.isAwaitingForeground && $0.firing == run.firing }

        // Older promises are not kept, they are lapsed. Rewritten rather than
        // removed so the history shows the gap; a user whose prompt tasks never
        // get collected should be able to see that, because the remedy is to
        // make it a watcher or to leave the phone in Desk Mode.
        for index in runs.indices where runs[index].isAwaitingForeground && runs[index].firing < run.firing {
            runs[index].outcome = .failed(.lapsed)
        }

        runs.append(run)
        if runs.count > Self.runHistoryLimit {
            runs.removeFirst(runs.count - Self.runHistoryLimit)
        }
        // `max`, not assignment: collecting a pending run settles a firing that
        // `settledThrough` has already passed, and winding it backwards would
        // make every firing since then due again.
        settledThrough = max(settledThrough, run.firing)
        updatedAt = moment
    }

    /// The most recent run that actually produced or refused something —
    /// skipping the promises that have not been collected. What a list row
    /// shows under the title.
    public var lastCompletedRun: TaskRun? {
        runs.last { !$0.isAwaitingForeground }
    }
}

// MARK: - Persistence

extension ScheduledTask {
    private enum CodingKeys: String, CodingKey {
        case id, title, body, recurrence, isEnabled, createdAt, updatedAt, settledThrough, runs
    }

    /// Written by hand for the same two reasons `ChatMessage`'s is.
    ///
    /// Fields added after the first release are read with `decodeIfPresent`, so
    /// a task written by an older build does not vanish from the list the day a
    /// field ships. And `runs` is decoded **lossily**: one run record this build
    /// cannot read — a future `Outcome` case, a future `ExecutionContext` —
    /// would otherwise throw, and `ScheduledTaskStore.all()` skips a file it
    /// cannot decode, so the user's *task* would disappear along with its
    /// schedule. `ChatMessage` learned this with a probe that recovered zero
    /// conversations from a single malformed card.
    ///
    /// `body` and `recurrence` are deliberately **not** lossy. A task whose
    /// rule or schedule this build cannot understand is not a task it can run,
    /// and quietly substituting a default would give the user a row that looks
    /// scheduled and fires at the wrong time or not at all. Failing to decode
    /// leaves the file on disk, intact, for the build that does understand it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(TaskBody.self, forKey: .body)
        recurrence = try container.decode(Recurrence.self, forKey: .recurrence)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let created = try container.decode(Date.self, forKey: .createdAt)
        createdAt = created
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        settledThrough = try container.decodeIfPresent(Date.self, forKey: .settledThrough) ?? created
        runs = (try? container.decodeIfPresent([LossyRun].self, forKey: .runs))?
            .compactMap(\.run) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(recurrence, forKey: .recurrence)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(settledThrough, forKey: .settledThrough)
        // Nearly always a short array, and omitted entirely when empty so a
        // freshly created task is a file somebody can read in one screen.
        if !runs.isEmpty {
            try container.encode(runs, forKey: .runs)
        }
    }
}
