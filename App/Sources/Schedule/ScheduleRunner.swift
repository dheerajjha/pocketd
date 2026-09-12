import Foundation
import PocketdKit

/// Runs the scheduled tasks that are due, in whichever execution context the
/// app has reached.
///
/// Nothing here decides *whether* a task may run: `ScheduleDispatch.plan` does
/// that, it is a pure function, and it is tested exhaustively precisely so that
/// this file cannot quietly disagree with it. What this type owns is the other
/// half — actually doing the thing, and writing down what happened — which is
/// where the constraint the feature is built around stops being a type and
/// starts costing something:
///
/// - A **watcher** is evaluated against EventKit and rendered from a template.
///   No model, no GPU, a few milliseconds. It produces a real answer wherever it
///   is asked, including a background refresh.
/// - A **prompt** is handed to the engine, and only ever in a context where
///   `ExecutionContext.mayRunModel` is true. On every iPhone this ships to, a
///   backgrounded app's Metal command buffers come back `notPermitted` rather
///   than slower, so there is no version of this that "just takes longer in the
///   background" — see `ExecutionContext` for the citations.
///
/// EventKit arrives as two closures rather than as an import, exactly as it does
/// for `PersonalDataTools` and `WatcherEvaluation`. That keeps the interesting
/// part of a sweep — which store was read, what was written back, and what was
/// *not* touched — true without a device, and it is what let the permission
/// pre-check below be written in `AppModel` where the app's own policy lives
/// rather than buried in here.
@MainActor
final class ScheduleRunner {

    // MARK: - What a sweep reports

    /// What one task did, for whoever has to announce it.
    ///
    /// Returned as well as persisted, because a notification is a decision about
    /// a run that *just* happened. The run records go to the store for the
    /// schedule screen, and re-deriving "what changed in this sweep" from twenty
    /// stored runs per task is both slower and wrong the first time two sweeps
    /// land close together — the second one would re-announce the first one's
    /// answer.
    struct Completion: Sendable, Equatable {
        /// The task as it stood when the plan was made, which is what an
        /// announcement needs: its title is the only text on a banner that
        /// belongs to the person holding the phone, and its id is what a tap
        /// comes back as.
        var task: ScheduledTask
        var kind: ScheduledKind
        var run: TaskRun
        /// The watcher's own answer to "is nothing worth a buzz". Always false
        /// for a prompt task, which has no such setting and could not mean one
        /// — see `TaskBody.watcher`.
        var notifyWhenEmpty: Bool
        /// What the rule found, for a watcher, and `nil` for everything else.
        ///
        /// Carried alongside the `TaskRun` rather than re-derived from it,
        /// because the two say different things and only one of them can be
        /// announced. A run record keeps the rendered block of text; an
        /// announcement wants the headline for a result, the range's own
        /// empty-day sentence for a blank one, and the Settings path for a
        /// permission that is off — and `.nothingToReport` has thrown the
        /// sentence away by the time it is a run.
        var watched: WatcherResult?
    }

    // MARK: - The app's side of the seam

    /// The handful of answers only `AppModel` has, as closures rather than as a
    /// reference back to it.
    ///
    /// Same shape as the closures `LlamaEngine` and `InferenceServer` are built
    /// with, and for the same reason: this type is then a thing that can be
    /// reasoned about on its own, instead of a second view onto the app's whole
    /// state. Every one of them is `@MainActor` because every one of them reads
    /// `AppModel`.
    @MainActor
    struct Host {
        /// Whether a reply the user is watching is streaming right now.
        var isUserGenerating: @MainActor () -> Bool
        /// The same instruction the Chat tab sends. A scheduled briefing
        /// answered by a differently-instructed assistant than the one the user
        /// has been talking to all week is a surprise nobody asked for.
        var systemPrompt: @MainActor () -> String
        /// The served context limit, or `nil` to let the engine use whatever it
        /// is configured with. Optional because `GenerationOptions.maxTokens`
        /// already is: there is no number this could invent that would be
        /// better than the engine's own, and inventing one to satisfy a
        /// non-optional would be a guess written down as a setting.
        var maxTokens: @MainActor () -> Int?
        /// `AppModel.record(_:)`, so the taxonomy keeps its single door.
        var record: @MainActor (AnalyticsEvent) -> Void
    }

    private let store: ScheduledTaskStore
    private let engine: any InferenceEngine
    private let readEvents: @Sendable (DateInterval) async -> PersonalDataLookup<CalendarEventRow>
    private let readReminders: @Sendable (DateWindow) async -> PersonalDataLookup<ReminderRow>
    private let host: Host
    private let now: @Sendable () -> Date
    /// Read per sweep rather than captured once. `Calendar.current` carries the
    /// device's time zone, and the whole reason `TimeOfDay` stores two numbers
    /// off a clock face is that the user can be somewhere else tomorrow.
    private let calendar: @Sendable () -> Calendar

    init(
        store: ScheduledTaskStore,
        engine: any InferenceEngine,
        readEvents: @escaping @Sendable (DateInterval) async -> PersonalDataLookup<CalendarEventRow>,
        readReminders: @escaping @Sendable (DateWindow) async -> PersonalDataLookup<ReminderRow>,
        host: Host,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { .current }
    ) {
        self.store = store
        self.engine = engine
        self.readEvents = readEvents
        self.readReminders = readReminders
        self.host = host
        self.now = now
        self.calendar = calendar
    }

    // MARK: - The sweep

    /// Whether a sweep is already in flight.
    ///
    /// Desk Mode sweeps on a repeating timer and one prompt run takes longer
    /// than the interval, so without this the next tick starts the same firing
    /// again: two generations queued on the engine's gate for one due moment,
    /// and two run records for it once both settle.
    private var isSweeping = false

    /// Looks at every task and does whatever this context allows.
    ///
    /// The return value is the sweep's own news. An empty array means nothing
    /// was owed — which is the normal answer, most of the time, and is why the
    /// caller must not treat it as a failure.
    @discardableResult
    func sweep(in context: ExecutionContext) async -> [Completion] {
        guard !isSweeping else { return [] }
        isSweeping = true
        defer { isSweeping = false }

        var completions: [Completion] = []
        for task in await store.all() {
            // Cancellation is cooperative, so without this a sweep cancelled
            // mid-generation — the app backgrounding, a model being loaded
            // under it — would walk on to the next task and ask an engine
            // that is being torn down for another answer.
            if Task.isCancelled { break }

            // The clock is read per task rather than once for the sweep: a
            // prompt run takes tens of seconds, and a task that comes due
            // during one should not have to wait for the next sweep to be
            // noticed.
            //
            // No `isEnabled` test here, deliberately. `plan` answers that
            // itself and returns `.idle(next: nil)`; two places deciding what
            // "switched off" means is how they come to disagree, and the one
            // that would be wrong is this one.
            switch ScheduleDispatch.plan(for: task, in: context, now: now(), calendar: calendar()) {
            case .idle:
                continue

            case let .notify(firing, _):
                // Only a prompt task in a context that cannot run a model
                // reaches here, so in practice only `.backgroundRefresh`. The
                // promise is settled rather than merely appended because the
                // firing has to be marked dealt with: leaving `settledThrough`
                // behind means the next background wake-up finds the same
                // firing still owed and notifies again, every refresh, until
                // the day turns over.
                let promised = TaskRun.awaitingForeground(firing: firing, ranAt: now(), context: context)
                if let completion = await settle(promised, of: task, context: context) {
                    completions.append(completion)
                }

            case let .run(work, firing, _):
                let completion: Completion?
                switch work {
                case let .watcher(rule, notifyWhenEmpty):
                    completion = await runWatcher(
                        rule,
                        notifyWhenEmpty: notifyWhenEmpty,
                        of: task,
                        firing: firing,
                        context: context
                    )
                case let .prompt(handoff):
                    completion = await runPrompt(handoff, of: task, context: context)
                }
                if let completion { completions.append(completion) }
            }
        }
        return completions
    }

    // MARK: - Watchers

    /// Evaluates the rule and files what it found.
    ///
    /// Three outcomes and not two, which is the distinction this whole codebase
    /// keeps: "nothing on today" and "I could not look at your calendar" are
    /// different facts, and collapsing them is how an app cheerfully reports a
    /// clear diary to somebody whose permission it lost three weeks ago.
    private func runWatcher(
        _ rule: WatcherRule,
        notifyWhenEmpty: Bool,
        of task: ScheduledTask,
        firing: Date,
        context: ExecutionContext
    ) async -> Completion? {
        let result = await WatcherEvaluation.run(
            rule,
            now: now(),
            calendar: calendar(),
            readEvents: readEvents,
            readReminders: readReminders
        )
        let ranAt = now()
        let run: TaskRun = switch result {
        case let .found(report):
            // `Untrusted` at the boundary because the factory takes nothing
            // else, and that is the point of the factory. Every line in that
            // report is an event title or a reminder name — written by whoever
            // sent the invite or shares the list — and a stored run record is
            // read back into later prompts.
            .reported(firing: firing, ranAt: ranAt, context: context, output: Untrusted(report.text))
        case .nothing:
            .nothingToReport(firing: firing, ranAt: ranAt, context: context)
        case let .unreadable(authorization, _):
            .unauthorized(authorization, firing: firing, ranAt: ranAt, context: context)
        }
        return await settle(
            run,
            of: task,
            context: context,
            notifyWhenEmpty: notifyWhenEmpty,
            watched: result
        )
    }

    // MARK: - Prompts

    /// Asks the model, in a context that can actually answer.
    private func runPrompt(
        _ handoff: PromptHandoff,
        of task: ScheduledTask,
        context: ExecutionContext
    ) async -> Completion? {
        // The physical precondition, restated where the model is actually
        // reached. `plan` will not produce prompt work for a context that
        // cannot run one, so this guard is unreachable today — and it is the
        // one worth duplicating anyway, because what is on the other side of it
        // is a Metal command buffer coming back `notPermitted` rather than a
        // slower answer.
        guard context.mayRunModel else { return nil }

        // A reply the user is watching outranks a task thinking on its own.
        //
        // This reuses the Chat tab's existing flag rather than adding a second
        // lock, and it is deliberately a refusal rather than a wait. The
        // engine's own gate would serialise the two perfectly well — a
        // scheduled generation simply queues — but queueing is the wrong
        // behaviour in both directions here: the unattended run would go on to
        // hold that gate for the next thing the user types, and the reply
        // somebody is reading would be the thing waiting behind a briefing.
        //
        // Nothing is settled and nothing is recorded, so the firing stays owed
        // and the next sweep collects it. In Desk Mode that costs a minute.
        guard !host.isUserGenerating() else { return nil }

        // The engine, not the app's mirror of it. A request from a paired
        // device can swap or drop the resident model without this app hearing
        // about it — `AppModel.syncLoadedModel` exists because that really
        // happens — and "is there a model to think with" has one honest source.
        guard let resident = await engine.loadedModel() else {
            return await settle(
                .failed(.noModelLoaded, firing: handoff.firing, ranAt: now(), context: context),
                of: task,
                context: context
            )
        }

        var messages: [ChatMessage] = []
        let instruction = host.systemPrompt()
        if !instruction.isEmpty { messages.append(.system(instruction)) }
        // `handoff.prompt` is the user's own words — the one piece of text in
        // this feature that arrived from the keyboard of the person who owns the
        // phone, and therefore the one that is not `Untrusted`. See `TaskBody`.
        messages.append(.user(handoff.prompt))
        // The same injection the Chat tab makes, and it matters more here: a
        // prompt task is nearly always about a moment, and a run collected hours
        // after its firing has to be told what time it is *now* or it answers
        // "what's on today" from whenever its training data stopped.
        messages = DateContext.inject(into: messages, now: now())

        let request = GenerationRequest(
            modelID: resident.id,
            messages: messages,
            options: GenerationOptions(maxTokens: host.maxTokens()),
            origin: handoff.origin
        )

        // The task local is bound around the whole generation, and this is the
        // line the feature does not work without.
        //
        // `ToolContext.origin` fails closed to `.network`, so a scheduled run
        // that binds nothing has every personal-data tool refuse it: the 7am
        // briefing comes back saying "Personal data is not available to network
        // clients", which is useless and untrue. `handoff.origin` is
        // `.scheduledTask(id:)` and emphatically NOT `.onDeviceChat` — forging
        // the chat tab's case would turn `mayReachPersonalData` from a fact
        // derived from the accepted socket into a claim the caller makes about
        // itself, which is the exact forgeable property `RequestOrigin` was
        // written to avoid.
        //
        // "a scheduled run never impersonates the chat tab" pins the value
        // `PromptHandoff` hands over. It does NOT pin this line: writing
        // `.onDeviceChat` here instead compiles, passes the whole suite, and
        // would be caught by nothing, because the app target has no test bundle
        // to catch it with. That gap is the reason this comment is this long.
        //
        // `LlamaEngine.generate` binds `request.origin` again inside its own
        // task, and that inner binding is the one a tool body actually reads.
        // This outer one is not redundant: it covers anything else this closure
        // reaches, and it is what makes a request built with the wrong origin a
        // visible disagreement on one screen rather than a silent refusal
        // sixty seconds later.
        let produced = await ToolContext.$origin.withValue(handoff.origin) {
            await self.collect(request)
        }

        let ranAt = now()
        if let failure = produced.failure {
            // An interruption is the one failure this app causes on purpose —
            // the app backgrounding, a model being loaded underneath the run,
            // the user starting to type — and it is deliberately NOT settled.
            // Settling advances `settledThrough` past the firing, so recording
            // it would mean a briefing the app itself abandoned is simply gone
            // for that day. Left owed, the next sweep runs it again, and the
            // retry is bounded by the recurrence: tomorrow's firing supersedes
            // today's whether or not it was ever collected.
            guard failure != .interrupted else { return nil }
            return await settle(
                .failed(failure, firing: handoff.firing, ranAt: ranAt, context: context),
                of: task,
                context: context
            )
        }

        let answer = produced.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A generation that stopped cleanly having said nothing is a failure,
        // not "nothing to report". That outcome means the rule ran and the day
        // was genuinely empty, and a prompt task has no such reading — the
        // distinction this codebase keeps everywhere is that an empty answer and
        // no answer must never look the same in a list.
        let run: TaskRun = answer.isEmpty
            ? .failed(.other, firing: handoff.firing, ranAt: ranAt, context: context)
            // `Untrusted`, even though a model wrote it. The model's answer is a
            // restatement of rows its tools read out of the calendar and the
            // reminder list, so the text carries whatever a stranger put in an
            // invite title, laundered through a sentence. Storing it as a plain
            // `String` would be one autocomplete away from interpolating it into
            // the next prompt.
            : .reported(firing: handoff.firing, ranAt: ranAt, context: context, output: Untrusted(answer))
        return await settle(run, of: task, context: context)
    }

    /// Drains a generation into the text it produced, or the reason it stopped.
    ///
    /// A closed set of failures rather than the error's own text, for the reason
    /// `RunFailure` is written down: a run record is shown in a list, kept for
    /// weeks and sits next to the user's calendar, and this app has already once
    /// put a `URLError`'s description — carrying a signed CDN URL and a whole
    /// resume blob — straight onto the screen.
    private func collect(_ request: GenerationRequest) async -> (text: String, failure: RunFailure?) {
        var text = ""
        do {
            for try await event in try await engine.generate(request) {
                switch event {
                case let .token(chunk):
                    text += chunk
                // A card is a rendering for a view and there is no view here;
                // the run record keeps the text. `InferenceEngine.complete`
                // drops them for exactly the same reason.
                case .answerCard, .toolCallStarted, .finished:
                    break
                }
            }
            return (text, nil)
        } catch {
            switch error as? InferenceError {
            case .noModelLoaded:
                // The model went between the residency check above and the
                // gate being acquired — the engine reads residency *after*
                // acquiring precisely because a load can happen while a request
                // is queued.
                return (text, .noModelLoaded)
            case .cancelled:
                return (text, .interrupted)
            default:
                return (text, error is CancellationError ? .interrupted : .other)
            }
        }
    }

    // MARK: - Writing it down

    /// Files one run through the store and reports what that cost.
    ///
    /// Through `update` rather than `all()` + `save()`, because two schedulers
    /// can be alive at the same moment — a background refresh settling this
    /// morning's watcher while the user renames the task in front of it — and a
    /// read-modify-write split across two calls loses one of them to
    /// last-writer-wins. `ScheduledTaskStore.update` exists for this.
    @discardableResult
    private func settle(
        _ run: TaskRun,
        of task: ScheduledTask,
        context: ExecutionContext,
        notifyWhenEmpty: Bool = false,
        watched: WatcherResult? = nil
    ) async -> Completion? {
        // Counted from the plan's own snapshot, because the rewrite happens
        // inside `ScheduledTask.settle` and the store hands back only the
        // result — there is no before-and-after to diff from out here. These are
        // the promises this firing supersedes: told to the user, never
        // collected, and about to be rewritten as `.failed(.lapsed)`.
        let lapsing = task.runs.filter { $0.isAwaitingForeground && $0.firing < run.firing }

        let saved: ScheduledTask?
        do {
            saved = try await store.update(task.id) { $0.settle(run, at: run.ranAt) }
        } catch {
            saved = nil
        }
        // `nil` means the file is gone: a task deleted between the plan being
        // made and its result being written, which is a normal race and not an
        // error. Either way nothing is on disk, so nothing is announced and
        // nothing is counted — an event about work that was not persisted is a
        // number nobody can reconcile against the schedule screen.
        guard saved != nil else { return nil }

        let kind: ScheduledKind = task.body.needsModel ? .prompt : .watcher
        for _ in lapsing { host.record(.scheduledTaskLapsed(kind: kind)) }

        // `.scheduledTaskRan` is the event the whole design is being measured
        // by — see its note in `AnalyticsEvent` — so it has to mean "something
        // was executed here", not "a row was written". The two states below
        // wrote a run record and executed nothing: a promise waiting for a
        // foreground, and a prompt that reached a context able to think with
        // nothing resident to think with. Counting either would make the bet on
        // Desk Mode look like it was paying off while no model had been asked
        // anything at all.
        switch run.outcome {
        case .awaitingForeground, .failed(.noModelLoaded):
            break
        default:
            host.record(.scheduledTaskRan(kind: kind, context: context.rawValue))
        }

        return Completion(
            task: task,
            kind: kind,
            run: run,
            notifyWhenEmpty: notifyWhenEmpty,
            watched: watched
        )
    }
}
