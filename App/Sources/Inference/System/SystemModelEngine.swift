import Foundation
import PocketdKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `InferenceEngine` backed by Apple's on-device model — the brain the app calls
/// "Built into iPhone" and the user knows as Apple Intelligence.
///
/// It answers the phone's own questions only: the conversation, the daily brief
/// and routines. The LAN server keeps serving a downloaded brain through
/// `LlamaEngine`; Apple's model is not ours to lend to other devices, so a
/// request with a network origin is refused here outright.
///
/// Available as a type on every iOS this app supports, so `AppModel` can hold
/// one unconditionally; everything that touches FoundationModels sits behind
/// `#available(iOS 26.0, *)`, and on an older phone the engine simply reports
/// `.notEligible` and never has a model resident.
///
/// Built to be indistinguishable from `LlamaEngine` to whoever reads the
/// stream: tokens as `.token`, a tool announced with `.toolCallStarted` before
/// it runs, its card as `.answerCard` before a word is written about it, and
/// exactly one `.finished`. The tools are the same bodies with the same origin
/// gate, write ledger and Undo; `FoundationTools.swift` has the wrappers.
///
/// Where it has to differ, it differs on purpose:
///
/// - **A session per request.** Apple's sessions keep their own transcript;
///   this app's conversations are reopened, branched and trimmed elsewhere. So
///   each request rebuilds a session from its messages (`SystemModelPlan`),
///   which also means each question can carry only the tools it needs.
/// - **The tool-round rule lives in the tools.** Apple's framework runs its own
///   tool loop and will make a second round — measured, see
///   `SystemToolPolicy` — so the "no change after a lookup" property LlamaEngine
///   gets from its one-round loop is enforced per call instead.
/// - **The window is 4,096 tokens** (read at runtime; Apple says it may grow),
///   for instructions, schemas, history, tool output and answer together. The
///   plan trims history to fit, with Apple's own count on iOS 26.4 and later.
/// - **Apple's model can decline** benign personal text — its filter trips on
///   diary words like "Kill the old server" (measured). After a lookup has
///   drawn its card, the card stands as the answer. Before anything was said
///   or changed, the same request goes to the downloaded brain if one is
///   loaded (`setFallback`), and otherwise ends in one plain sentence.
actor SystemModelEngine: InferenceEngine {
    nonisolated var backendName: String { "Apple Foundation Models" }

    /// Whether the phone chose this brain and it has been "loaded". Apple's
    /// model is the OS's to keep in memory, so this is a promise to answer, not
    /// a residency: it stays true while Apple Intelligence is switched off or
    /// still downloading, and `loadedModel()` reports the model only while it
    /// can actually answer.
    private var resident = false
    /// The abilities the user has switched on. Each request arms the subset its
    /// question needs — see `SystemModelPlan.armedTools`.
    private var enabled: Set<CapabilityGroup> = []
    /// The downloaded brain, for a question Apple's model declines.
    private var fallback: (any InferenceEngine)?
    /// A session created at load time and asked to prewarm, held only so the
    /// framework has a reason to keep what it loaded. `AnyObject` because a
    /// stored property cannot be typed with something that only exists on
    /// iOS 26.
    private var warm: AnyObject?

    /// Who is answering now, and who is queued. One answer at a time, in
    /// order, as `LlamaEngine` does: two sessions can run side by side on
    /// Apple's model (measured), but the brief and a typed question racing
    /// each other is a decision `AppModel` already makes — chat first — and
    /// two engines with different rules would make it twice.
    private var holder: UUID?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waitOrder: [UUID] = []
    /// Every answer handed out and not yet ended, so that unloading stops them.
    private var running: [UUID: Task<Void, Never>] = [:]

    /// - Parameter fallback: The downloaded brain a declined question goes to;
    ///   see `setFallback`.
    init(fallback: (any InferenceEngine)? = nil) {
        self.fallback = fallback
    }

    // MARK: - Availability

    /// Whether Apple's model can answer on this phone right now, in the Kit's
    /// terms. Cheap enough to read from a view.
    ///
    /// `.available` is not enough on its own: Apple's model can be present and
    /// still not support the phone's language, and only `supportsLocale()`
    /// says so — a question in that language fails with an error instead of an
    /// answer. A reason this build has never heard of hides the option rather
    /// than guessing at what to tell the user.
    nonisolated static var availability: BuiltInBrainAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return model.supportsLocale() ? .available : .unsupportedLanguage
            case .unavailable(.appleIntelligenceNotEnabled):
                return .turnedOff
            case .unavailable(.modelNotReady):
                return .gettingReady
            case .unavailable(.deviceNotEligible):
                return .notEligible
            case .unavailable:
                return .notEligible
            }
        }
        #endif
        return .notEligible
    }

    /// The window, read from the OS. 4,096 on iOS 26 and on this Mac's
    /// macOS 27; Apple's own sample code has printed 8,192, so it is never
    /// assumed.
    ///
    /// Guarded, because it is not always true: on the iOS 27 simulator the
    /// first read, made while the model service was still starting, returned
    /// 0, and a window of 0 refuses every question as too long. Anything under
    /// 1,024 is taken as "not known yet" and the documented 4,096 stands in.
    nonisolated static var contextTokens: Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let size = SystemLanguageModel.default.contextSize
            return size >= 1024 ? size : 4096
        }
        #endif
        return 4096
    }

    /// Apple's name for the model build ("AFM 3 Core" on macOS 27.0.1), for
    /// Diagnostics only. Never shown in the app: a model name is machinery.
    nonisolated static var variantName: String? {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) { return SystemLanguageModel.default.variant.displayName }
        #endif
        return nil
    }

    // MARK: - Configuration

    /// The counterpart of `LlamaEngine.updateTools`: which abilities are on.
    ///
    /// Takes switches rather than LocalLLMClient registrations because there
    /// is nothing to register — tools are built per request — and nothing to
    /// rebuild: the next question simply carries the new set.
    func updateAbilities(calendar: Bool, reminders: Bool, health: Bool) {
        var groups: Set<CapabilityGroup> = []
        if calendar { groups.insert(.calendar) }
        if reminders { groups.insert(.reminders) }
        if health { groups.insert(.health) }
        enabled = groups
    }

    /// The downloaded brain a declined question is handed to. Used only while
    /// it reports a loaded model — loading 1–2 GB of weights to answer one
    /// question the user can simply re-ask is not a trade this makes for them.
    func setFallback(_ engine: (any InferenceEngine)?) {
        fallback = engine
    }

    /// Mirrors `LlamaEngine.toolGate`, which `AppModel` reads to decide
    /// whether the brain can read the day: Apple's model always can.
    var toolGate: ToolGate.Decision { resident ? .declaredCapable : .noModelLoaded }

    /// Mirrors `LlamaEngine.capabilityPlan`. Nothing is ever dropped for
    /// space here — the plan trims history instead of capabilities — so there
    /// is no shortfall to report.
    var capabilityPlan: CapabilityBudget.Plan? { nil }

    // MARK: - Residency

    func loadedModel() -> ModelRecord? {
        resident && Self.availability == .available ? .builtIn : nil
    }

    /// Takes the built-in record and nothing else.
    ///
    /// Succeeds while Apple Intelligence is off or still downloading: the
    /// choice is kept and the engine starts answering the moment the model can,
    /// with each request in between failing in a sentence that says why. Only
    /// a phone that can never run it is refused, so a choice restored from a
    /// backup onto an older iPhone does not pretend to stick.
    func load(model: ModelRecord) async throws {
        guard model.isBuiltInBrain else { throw InferenceError.modelNotFound(model.id) }
        let availability = Self.availability
        guard availability != .notEligible else {
            DiagnosticLog.record(.modelLoad(id: model.id, contextTokens: 0, outcome: .failed, milliseconds: 0))
            throw InferenceError.modelNotFound(model.id)
        }
        resident = true
        let started = ContinuousClock.now
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), availability == .available, warm == nil {
            let session = LanguageModelSession(instructions: SystemModelPlan.toolPreamble)
            session.prewarm()
            warm = session
        }
        #endif
        // The variant rides in the id field: `DiagnosticEvent` has a closed
        // set of fields, and this is the one line where the build of Apple's
        // model is worth recording.
        let id = Self.variantName.map { "\(model.id) (\($0))" } ?? model.id
        DiagnosticLog.record(.modelLoad(
            id: id,
            contextTokens: Self.contextTokens,
            outcome: .ok,
            milliseconds: Int(started.duration(to: .now) / .milliseconds(1))
        ))
    }

    /// Stops whatever is being written, then forgets the choice. Nothing to
    /// free: the OS owns the model's memory.
    func unload() async {
        for task in running.values { task.cancel() }
        resident = false
        warm = nil
    }

    // MARK: - The gate

    private func acquire(_ token: UUID) async throws {
        guard holder != nil else {
            holder = token
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checked here as well as by the handler: a task cancelled
                // before its continuation is stored would otherwise queue
                // forever.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[token] = continuation
                waitOrder.append(token)
            }
        } onCancel: {
            Task { await self.abandon(token) }
        }
        holder = token
    }

    /// Idempotent, so both the run's `defer` and the stream's `onTermination`
    /// can call it.
    private func release(_ token: UUID) {
        running[token] = nil
        guard holder == token else { return }
        holder = nil
        while let next = waitOrder.first {
            waitOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: next) {
                continuation.resume()
                return
            }
        }
    }

    private func abandon(_ token: UUID) {
        guard let continuation = waiters.removeValue(forKey: token) else { return }
        waitOrder.removeAll { $0 == token }
        continuation.resume(throwing: CancellationError())
    }

    // MARK: - Generation

    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        try await generate(request, toolsAllowed: true)
    }

    /// - Parameter toolsAllowed: `false` for a prompt that already carries
    ///   every fact it may use — the daily brief. Apple's model handed tools
    ///   there can go and look the day up again, and then write as if the
    ///   reader could see the card that lookup drew; the brief never shows
    ///   one. It also saves the schemas' 400–750 tokens and a tool round.
    func generate(
        _ request: GenerationRequest,
        toolsAllowed: Bool
    ) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, any Error>.makeStream()
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }
            await self.run(request, toolsAllowed: toolsAllowed, token: token, continuation: continuation)
        }
        running[token] = task
        // Stop in the conversation cancels the task reading this stream, which
        // terminates it, which lands here: the session's own stream ends the
        // moment its task is cancelled (measured: no throw, under a
        // millisecond), so Stop frees the engine at once.
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            Task { await self?.release(token) }
        }
        return stream
    }

    private func run(
        _ request: GenerationRequest,
        toolsAllowed: Bool,
        token: UUID,
        continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation
    ) async {
        do {
            try await acquire(token)
        } catch {
            continuation.finish(throwing: InferenceError.cancelled)
            return
        }
        defer { release(token) }

        // Never through the server. `InferenceServer` is built on LlamaEngine
        // and cannot reach this, so this is the second lock on the same door.
        if case .network = request.origin {
            continuation.finish(throwing: InferenceError.modelNotFound(ModelRecord.builtInID))
            return
        }
        guard resident else {
            continuation.finish(throwing: InferenceError.noModelLoaded)
            return
        }
        let availability = Self.availability
        guard availability == .available else {
            continuation.finish(throwing: SystemModelFailure.unavailable(availability))
            return
        }
        guard request.modelID.isEmpty || request.modelID == ModelRecord.builtInID else {
            continuation.finish(throwing: InferenceError.modelMismatch(requested: request.modelID, loaded: ModelRecord.builtInID))
            return
        }
        guard !request.messages.contains(where: { !$0.images.isEmpty }) else {
            continuation.finish(throwing: SystemModelFailure.pictures.error)
            return
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            // A question about the user's own day is answered from reads made
            // here, never left to the model to look up or to remember: a few
            // turns into a conversation it stopped looking and made the day
            // up (QA S1-1). Changes, and everything else, keep the tool path.
            var abilities = enabled
            #if DEBUG
            // Under `-pocketd.demoHealth` Today shows the demo day's Health as
            // connected; the conversation reads the same day (`SystemReads`),
            // so it counts Health as on too, and the two agree in a capture.
            if DemoDay.isRequested { abilities.insert(.health) }
            #endif
            let outcome: SystemModelAnswer.Outcome
            if toolsAllowed, let reads = SystemModelReads.plan(for: request, enabled: abilities) {
                outcome = await SystemModelAnswer.answer(from: reads, for: request, into: continuation)
            } else {
                outcome = await SystemModelAnswer.write(request, enabled: toolsAllowed ? abilities : [], into: continuation)
            }
            guard case let .declined(failure) = outcome else { return }
            if let fallback, await fallback.loadedModel() != nil {
                await relay(request, to: fallback, into: continuation)
            } else {
                continuation.finish(throwing: failure.error)
            }
            return
        }
        #endif
        continuation.finish(throwing: InferenceError.noModelLoaded)
    }

    /// The same request, answered by the downloaded brain, on this stream.
    ///
    /// Only reached when Apple's model declined before writing a word, drawing
    /// a card or changing anything, so nothing the user has seen is
    /// contradicted or repeated.
    private func relay(
        _ request: GenerationRequest,
        to fallback: any InferenceEngine,
        into continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation
    ) async {
        var forwarded = request
        // Empty means "whatever is resident", which is the brain being asked.
        forwarded.modelID = ""
        DiagnosticLog.record(.failure(area: .model, code: "fm.fallbackToDownloaded"))
        do {
            for try await event in try await fallback.generate(forwarded) {
                continuation.yield(event)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

#if canImport(FoundationModels)

// MARK: - One answer, on Apple's model

/// Everything that names a FoundationModels type, kept out of the actor so the
/// actor's stored properties never have to.
@available(iOS 26.0, *)
enum SystemModelAnswer {
    typealias Continuation = AsyncThrowingStream<GenerationEvent, any Error>.Continuation

    enum Outcome {
        /// The stream has been finished, one way or another.
        case done
        /// Apple's model declined before writing, drawing or changing
        /// anything. The stream is still open, for the caller to hand to
        /// another brain or to close with the failure.
        case declined(SystemModelFailure)
    }

    static func write(
        _ request: GenerationRequest,
        enabled: Set<CapabilityGroup>,
        into continuation: Continuation
    ) async -> Outcome {
        #if DEBUG
        // Apple's filter trips unpredictably — the same question passed three
        // runs out of four on the simulator — so the probe proves the decline
        // path by asking for one, once, here.
        if SystemModelProbe.takeForcedDecline() { return .declined(.guardrail) }
        #endif
        let started = ContinuousClock.now
        let model = SystemLanguageModel.default
        let budget = SystemModelBudget(contextTokens: SystemModelEngine.contextTokens)
        // A change runs on its own: no replayed history to imitate, only the
        // tool its verb needs, and its words held back until a write has
        // actually run — see `SystemModelWrites`.
        let isChange = SystemModelWrites.isChange(request)
        let request = isChange ? SystemModelWrites.withoutHistory(request) : request

        let plan: SystemModelPlan
        do {
            plan = try await self.plan(for: request, enabled: enabled, budget: budget, model: model)
        } catch {
            if (error as? InferenceError) == .contextExhausted {
                DiagnosticLog.record(.failure(area: .model, code: SystemModelFailure.contextExceeded.diagnosticCode))
            }
            continuation.finish(throwing: error)
            return .done
        }
        return await stream(plan, for: request, cardsAlreadyShown: false, screensChange: isChange, started: started, into: continuation)
    }

    /// A personal read, answered from reads made here rather than by the model.
    ///
    /// Each read runs through the tool body it stands in for, announced and
    /// drawn exactly as a tool call would be — `.toolCallStarted`, then its
    /// card — so the conversation cannot tell it from one. Then Apple's model
    /// is asked, with tools off and no history, to answer from those facts
    /// alone (`SystemModelReads.plan(answering:)`). See `SystemModelReads` for
    /// the fabrication this replaced.
    static func answer(
        from reads: [SystemModelReads.Read],
        for request: GenerationRequest,
        into continuation: Continuation
    ) async -> Outcome {
        let started = ContinuousClock.now
        var facts: [String] = []
        var drewCard = false
        for read in reads {
            guard let call = SystemReads.call(for: read) else {
                if case let .switchedOff(group) = read { facts.append(SystemModelReads.switchedOffFact(group)) }
                continue
            }
            continuation.yield(.toolCallStarted(name: call.name))
            let json = SystemToolRun.json(call.arguments)
            let origin = request.origin
            let readStarted = Date()
            let body = call.body
            guard let data = await SystemToolRun.withDeadline(SystemToolRun.readDeadline, {
                await ToolContext.$origin.withValue(origin) { await body(origin) }
            }) else {
                DiagnosticLog.record(.toolCall(name: call.name, outcome: .failed, milliseconds: Int(Date().timeIntervalSince(readStarted) * 1000)))
                facts.append("Nothing came back from the \(call.name) read in time, so say you couldn't check it just now.")
                continue
            }
            DiagnosticLog.record(.toolCall(
                name: call.name,
                outcome: SystemToolRun.outcome(of: data),
                milliseconds: Int(Date().timeIntervalSince(readStarted) * 1000)
            ))
            if let card = ToolResult.render(data, from: call.name, arguments: json).card {
                continuation.yield(.answerCard(card))
                drewCard = true
            }
            facts.append(SystemModelReads.fact(for: read, rendered: SystemToolOutput.render(data)))
        }
        if Task.isCancelled {
            continuation.yield(.finished(reason: .cancelled, usage: TokenUsage()))
            continuation.finish()
            return .done
        }
        let budget = SystemModelBudget(contextTokens: SystemModelEngine.contextTokens)
        let plan = SystemModelReads.plan(answering: request, facts: facts, reads: reads, budget: budget)
        return await stream(plan, for: request, cardsAlreadyShown: drewCard, started: started, into: continuation)
    }

    /// One session over one plan, streamed: the tool loop when the plan has
    /// tools, a plain answer when it has none.
    ///
    /// - Parameter cardsAlreadyShown: Whether a card is already on screen for
    ///   this answer, drawn before the session started — the read-first path.
    ///   Apple's filter declining after that leaves the card standing, as it
    ///   does for a card a tool call drew.
    /// - Parameter screensChange: The turn asks for a change. Nothing the
    ///   model writes is shown until the turn is over, and then only if a
    ///   write tool actually ran (`SystemModelWrites.screen`).
    static func stream(
        _ initialPlan: SystemModelPlan,
        for request: GenerationRequest,
        cardsAlreadyShown: Bool,
        screensChange: Bool = false,
        started: ContinuousClock.Instant,
        into continuation: Continuation
    ) async -> Outcome {
        let model = SystemLanguageModel.default
        var plan = initialPlan
        var retried = false
        while true {
            let shown = CardsShown()
            let run = SystemToolRun(origin: request.origin, userText: ToolContext.userText(of: request)) { event in
                if case let .answerCard(card) = event { shown.append(card) }
                continuation.yield(event)
            }
            let tools = SystemToolRun.tools(for: plan.tools, run: run)
            let session = LanguageModelSession(model: model, tools: tools, transcript: transcript(for: plan, tools: tools))
            run.attach(session)
            var text = StreamedText(stops: request.options.stopSequences)

            do {
                let stream = session.streamResponse(to: plan.prompt, options: options(for: request, plan: plan))
                for try await snapshot in stream {
                    if Task.isCancelled { break }
                    if let delta = text.take(snapshot.content), !screensChange { continuation.yield(.token(delta)) }
                    if text.halted { break }
                }
            } catch {
                run.stop()
                if Task.isCancelled || error is CancellationError {
                    finish(.cancelled, text: &text, plan: plan, started: started, into: continuation,
                           screening: screensChange ? (request, run.anyWriteMade) : nil)
                    return .done
                }
                let failure = SystemModelEngine.failure(for: error)
                DiagnosticLog.record(.failure(area: .model, code: failure.diagnosticCode))

                // An overflow before anything happened is retried once with
                // half the history. Not after a tool ran: retrying would run it
                // again, and a lookup's card is already on screen.
                if failure == .contextExceeded, !retried, text.sentNothing, !run.anyCallMade,
                   let smaller = plan.halvingHistory() {
                    retried = true
                    plan = smaller
                    continue
                }
                if failure.asksTheDownloadedBrain {
                    // Apple's filter objects to ordinary diary words — measured
                    // on macOS 27: "What's on today?" over events named "Kill
                    // the old server" and "Shoot the product photos" is a
                    // guardrail violation, and so is "Colonoscopy prep". When
                    // a lookup has already drawn its card, the card is the
                    // answer and the filter only objected to narrating it, so
                    // the card stands on its own, as it does when LlamaEngine's
                    // narration turns out to be nothing but an echo.
                    if cardsAlreadyShown || !shown.all.isEmpty {
                        finish(.stop, text: &text, plan: plan, started: started, into: continuation,
                               screening: screensChange ? (request, run.anyWriteMade) : nil)
                        return .done
                    }
                    if text.sentNothing, !run.anyWriteMade {
                        return .declined(failure)
                    }
                }
                DiagnosticLog.record(.generation(
                    promptTokens: promptTokens(plan), outputTokens: estimateTokens(text.produced),
                    milliseconds: elapsed(since: started),
                    stop: failure == .contextExceeded ? .contextExhausted : .failed
                ))
                continuation.finish(throwing: failure.error)
                return .done
            }

            run.stop()
            let reason: FinishReason
            if Task.isCancelled {
                reason = .cancelled
            } else if text.halted {
                reason = .stop
            } else {
                reason = estimateTokens(text.produced) >= plan.responseTokens ? .length : .stop
            }
            finish(reason, text: &text, plan: plan, started: started, into: continuation,
                   screening: screensChange ? (request, run.anyWriteMade) : nil)
            return .done
        }
    }

    /// - Parameter screening: For a change turn, the request and whether a
    ///   write ran. Its held-back words go out now, or — when no write ran
    ///   and they claim one — the plain sentence that replaces them.
    private static func finish(
        _ reason: FinishReason,
        text: inout StreamedText,
        plan: SystemModelPlan,
        started: ContinuousClock.Instant,
        into continuation: Continuation,
        screening: (request: GenerationRequest, wrote: Bool)? = nil
    ) {
        if let screening {
            _ = text.flush()
            if reason != .cancelled {
                let shown = SystemModelWrites.screen(text.produced, wrote: screening.wrote, for: screening.request)
                if !shown.isEmpty { continuation.yield(.token(shown)) }
                if !screening.wrote, shown != text.produced.trimmingCharacters(in: .whitespacesAndNewlines) {
                    DiagnosticLog.record(.failure(area: .tools, code: "fm.unbackedChangeClaim"))
                }
            }
        } else if let rest = text.flush() {
            continuation.yield(.token(rest))
        }
        DiagnosticLog.record(.generation(
            promptTokens: promptTokens(plan), outputTokens: estimateTokens(text.produced),
            milliseconds: elapsed(since: started),
            stop: reason == .cancelled ? .cancelled : .completed
        ))
        continuation.yield(.finished(
            reason: reason,
            usage: TokenUsage(promptTokens: promptTokens(plan), completionTokens: estimateTokens(text.produced))
        ))
        continuation.finish()
    }

    // MARK: Planning

    /// The plan, trimmed by Apple's own count where the OS has one.
    ///
    /// On iOS 26.4 and later the history is first planned optimistically, at
    /// four bytes a token, and then cut down an exchange at a time until
    /// `tokenCount(for:)` says the transcript, the question and the reserves
    /// fit. Earlier, `ContextGuard`'s three bytes a token stands in — an
    /// over-count for English, which costs a few old turns and never an answer.
    static func plan(
        for request: GenerationRequest,
        enabled: Set<CapabilityGroup>,
        budget: SystemModelBudget,
        model: SystemLanguageModel
    ) async throws -> SystemModelPlan {
        if #available(iOS 26.4, *) {
            let optimistic = try SystemModelPlan.make(
                for: request, enabled: enabled, budget: budget, estimate: optimisticEstimate
            )
            if let fitted = await fitted(optimistic, budget: budget, model: model) { return fitted }
        }
        return try SystemModelPlan.make(for: request, enabled: enabled, budget: budget)
    }

    /// Four bytes a token: Apple's tokenizer measured 3.4 for English, so this
    /// under-counts on purpose — the plan starts generous and the exact count
    /// trims it, rather than starting mean and never growing.
    static func optimisticEstimate(_ text: String) -> Int { (text.utf8.count + 3) / 4 }

    @available(iOS 26.4, *)
    private static func fitted(
        _ plan: SystemModelPlan,
        budget: SystemModelBudget,
        model: SystemLanguageModel
    ) async -> SystemModelPlan? {
        // Never executed: these exist only so their schemas are counted.
        let counting = SystemToolRun(origin: .onDeviceChat, emit: { _ in })
        let tools = SystemToolRun.tools(for: plan.tools, run: counting)
        guard let question = try? await model.tokenCount(for: plan.prompt) else { return nil }
        var candidate = plan
        // Two recounts are normally enough: the first finds the overshoot, the
        // drop frees at least that much, the second confirms.
        for _ in 0..<4 {
            guard let used = try? await model.tokenCount(for: transcript(for: candidate, tools: tools)) else { return nil }
            let reserve = candidate.responseTokens + budget.marginTokens
                + (candidate.tools.isEmpty ? 0 : budget.toolOutputTokens)
            let overshoot = used + question + reserve - budget.contextTokens
            if overshoot <= 0 { return candidate }
            guard let smaller = candidate.droppingExchanges(toFree: overshoot, estimate: optimisticEstimate) else { return nil }
            candidate = smaller
        }
        return nil
    }

    /// The session's starting transcript: instructions with the tools'
    /// definitions, then the history as prompts and responses.
    static func transcript(for plan: SystemModelPlan, tools: [any Tool]) -> Transcript {
        var entries: [Transcript.Entry] = []
        if !plan.instructions.isEmpty || !tools.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: plan.instructions.isEmpty ? [] : [.text(Transcript.TextSegment(content: plan.instructions))],
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            )))
        }
        for turn in plan.history {
            let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: turn.text))]
            switch turn.speaker {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            }
        }
        return Transcript(entries: entries)
    }

    /// Apple's sampler, set only where the caller named something.
    ///
    /// The phone's own requests name nothing but a length, and get Apple's
    /// defaults — the server's llama.cpp sampler settings are tuned for other
    /// weights and are not this model's business. A temperature of zero means
    /// greedy, as it does for llama.cpp; a seed asks for reproducible sampling.
    static func options(for request: GenerationRequest, plan: SystemModelPlan) -> FoundationModels.GenerationOptions {
        let asked = request.options
        var sampling: FoundationModels.GenerationOptions.SamplingMode?
        var temperature: Double?
        if let value = asked.temperature, value.isFinite {
            if value <= 0 { sampling = .greedy } else { temperature = min(value, 2) }
        }
        if sampling == nil, let seed = asked.seed {
            if let k = asked.topK, k > 0 {
                sampling = .random(top: k, seed: seed)
            } else {
                sampling = .random(probabilityThreshold: min(max(asked.topP ?? 0.95, 0.01), 1), seed: seed)
            }
        }
        return FoundationModels.GenerationOptions(
            samplingMode: sampling,
            temperature: temperature,
            maximumResponseTokens: plan.responseTokens
        )
    }

    // MARK: Accounting

    /// Four characters a token, as `LlamaEngine` estimates: the figure exists
    /// so `usage` is populated, not to bill against.
    static func estimateTokens(_ text: String) -> Int { max(0, (text.count + 3) / 4) }

    static func promptTokens(_ plan: SystemModelPlan) -> Int {
        estimateTokens(plan.instructions) + estimateTokens(plan.prompt)
            + plan.history.reduce(0) { $0 + estimateTokens($1.text) }
    }

    static func elapsed(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }
}

/// The cards one attempt drew, so a declined answer knows whether a card is
/// already standing in for it.
@available(iOS 26.0, *)
final class CardsShown: @unchecked Sendable {
    private let lock = NSLock()
    private var cards: [AnswerCard] = []

    func append(_ card: AnswerCard) { lock.withLock { cards.append(card) } }
    var all: [AnswerCard] { lock.withLock { cards } }
}

/// Turns Apple's cumulative snapshots into deltas, honouring stop sequences.
///
/// Each snapshot is the whole answer so far — measured: 76 snapshots for one
/// answer, every one a prefix-extension of the last — so what is sent is the
/// part not sent yet. Stop sequences are held back by their length, as
/// `LlamaEngine` holds them, so a stop is never half-shown before it matches.
struct StreamedText {
    let stops: [String]
    let holdBack: Int
    private(set) var produced = ""
    private(set) var sent = 0
    private(set) var halted = false

    init(stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }
        self.holdBack = self.stops.map(\.count).max() ?? 0
    }

    var sentNothing: Bool { sent == 0 }

    /// The new text to send for this snapshot, if any.
    mutating func take(_ snapshot: String) -> String? {
        guard !halted else { return nil }
        produced = snapshot
        // A snapshot that does not extend what was sent cannot take it back.
        // Never seen; kept from turning into an index past the end.
        sent = min(sent, produced.count)
        if let hit = stops.compactMap({ produced.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            produced = String(produced[..<hit.lowerBound])
            sent = min(sent, produced.count)
            halted = true
            return nil
        }
        let safe = max(sent, produced.count - holdBack)
        guard safe > sent else { return nil }
        let delta = String(produced.dropFirst(sent).prefix(safe - sent))
        sent = safe
        return delta
    }

    /// Whatever was held back, once the answer has ended.
    mutating func flush() -> String? {
        guard sent < produced.count else { return nil }
        let rest = String(produced.dropFirst(sent))
        sent = produced.count
        return rest
    }
}

// MARK: - Apple's errors, in the Kit's terms

extension SystemModelEngine {
    /// One mapping for both generations of Apple's error types.
    ///
    /// iOS 27 deprecates `LanguageModelSession.GenerationError` in favour of
    /// `LanguageModelError`, `LanguageModelSession.Error` and
    /// `SystemLanguageModel.Error`, and the new ones are what a build against
    /// the iOS 27 SDK receives there — measured on macOS 27, where an
    /// overflow arrives as `LanguageModelError.contextSizeExceeded`. A phone
    /// still on iOS 26 sends the old type, so both are read, newest first.
    @available(iOS 26.0, *)
    nonisolated static func failure(for error: any Error) -> SystemModelFailure {
        if #available(iOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .contextExceeded
                case .guardrailViolation: return .guardrail
                case .refusal: return .refusal
                case .rateLimited: return .rateLimited
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                case .timeout: return .timedOut
                case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide: return .other
                @unknown default: return .other
                }
            }
            if let error = error as? LanguageModelSession.Error {
                switch error {
                case .concurrentRequests, .transcriptMutationWhileResponding: return .busy
                @unknown default: return .other
                }
            }
            if error is SystemLanguageModel.Error { return .assetsUnavailable }
            if error is GeneratedContent.ParsingError { return .unreadableOutput }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextExceeded
            case .assetsUnavailable: return .assetsUnavailable
            case .guardrailViolation: return .guardrail
            case .unsupportedGuide, .decodingFailure: return .unreadableOutput
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited: return .rateLimited
            case .concurrentRequests: return .busy
            case .refusal: return .refusal
            @unknown default: return .other
            }
        }
        return .other
    }
}
#endif
