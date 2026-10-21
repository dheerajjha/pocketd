import EventKit
import Foundation
import Observation
import PocketdKit

// MARK: - The state the Today tab reads

/// Everything the brief is, while it is being made and after it is made.
///
/// Its own `@Observable` object hanging off one stored property on `AppModel`
/// rather than six properties added to it, and that is not only because a Swift
/// extension cannot add stored properties. The Today tab reads all six of these
/// together and nothing else reads any of them, so a view that observes this
/// object does not redraw when a download reports a byte count — the same
/// argument `Profile` makes for being its own object.
@MainActor
@Observable
final class BriefingState {

    /// Where the brief is in its life.
    ///
    /// `.building` and `.streaming` are separate because they say different
    /// things to the person looking at the card: one is "we are reading your
    /// day", which is over in under a second and needs no announcement, and the
    /// other is "a model is writing", which takes twenty seconds and has a
    /// caret. Collapsing them into `isLoading` is how a card ends up shimmering
    /// for a fifth of a second on every foreground.
    enum Phase: Equatable {
        case idle
        case building
        case streaming
        case ready
        case failed(String)
    }

    /// The day, read without a model. Always current; never nil.
    var snapshot: TodaySnapshot = .empty

    /// The paragraph that is on screen, template or model-written.
    ///
    /// Optional only until the first `refreshBrief` lands. After that there is
    /// always one, because `BriefPrompt.fallback` never returns an empty string
    /// — an empty card on the home tab is the worst possible first impression
    /// for an app whose pitch is "reads your day".
    var brief: DailyBrief?

    /// What the model has emitted so far, already cleaned. Empty unless
    /// `phase == .streaming`.
    var streamingText: String = ""

    var phase: Phase = .idle

    /// When the snapshot was last rebuilt, which is what the mono time in the
    /// card's corner shows. Not `brief.generatedAt`: the tiles move through the
    /// day while the paragraph stays, and the time beside "TODAY'S BRIEF" is
    /// about the card as a whole.
    var lastRefresh: Date?

    var isReadingAloud = false

    /// The model generation, so that the chat can take the engine off it.
    ///
    /// `@ObservationIgnored` because nothing renders a `Task`, and observing it
    /// would redraw the whole tab twice per brief for no pixels.
    @ObservationIgnored var generation: Task<Void, Never>?

    /// Re-entrancy guard for `refreshBrief`. Scene-active and the view's own
    /// `.task` can both fire within the same frame on a cold launch, and two
    /// concurrent reads of EventKit produce one wasted read and one duplicate
    /// write of the same file.
    @ObservationIgnored var isRefreshing = false

    /// Something the day is read from has changed since the last reading — a
    /// switch, an iOS permission, the calendar database, the app coming back
    /// to the front — so the next refresh reads again however recent the last
    /// one was. Starts true: nothing has been read this launch.
    @ObservationIgnored var isStale = true

    /// A forced refresh asked for while another was running. It runs when that
    /// one finishes rather than being dropped.
    ///
    /// Dropping it was the stale first paint. On a launch the Today tab's own
    /// refresh started first, under switches the launch had not finished
    /// restoring; the launch's refresh then arrived, hit the guard above, and
    /// went nowhere — so the tiles said "Off" for a calendar that was
    /// connected until somebody pulled to refresh.
    @ObservationIgnored var wantsForcedPass = false

    /// Sleeps until the brief on screen next stops being true — a meeting
    /// starting or ending, a timed reminder falling due, the greeting's part
    /// of the day changing — and then reads the day again. See
    /// `scheduleNextRewrite`.
    @ObservationIgnored var nextRewrite: Task<Void, Never>?

    init() {}

    /// What the card actually prints: the model's words while they are
    /// arriving, the stored brief otherwise.
    var displayText: String {
        if phase == .streaming, !streamingText.isEmpty { return streamingText }
        return brief?.text ?? ""
    }

    /// Whether a brain wrote this, which is what the status dot means.
    var isModelWritten: Bool { brief?.source.modelID != nil }

    var isBusy: Bool { phase == .building || phase == .streaming }
}

// MARK: - A clock for screenshots

/// A clock for screenshots, and nothing else.
///
/// A store capture is taken whenever the capture session happens to run, and
/// the brief greets by the hour: shot at midnight it opens "Good evening" under
/// a status bar that says 9:41, which is the one contradiction a reader spots
/// in under a second. `-pocketd.demoTime 09:41` moves Today's idea of now to
/// that time today; the seeded calendar is relative to the real day, so the
/// tiles stay true. Absent in Release, like every other `-pocketd.` argument.
enum DemoClock {
    static var now: Date {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-pocketd.demoTime"),
              index + 1 < arguments.count else { return Date() }
        let parts = arguments[index + 1].split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let shifted = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
        else { return Date() }
        return shifted
        #else
        return Date()
        #endif
    }
}

// MARK: - The engine

extension AppModel {

    /// The brief's store, or nothing if Application Support cannot be reached.
    ///
    /// A function rather than a stored property because `AppModel` may only
    /// gain one stored property for this whole feature — see `briefing` — and
    /// because building one is two syscalls that the two callers (this file and
    /// the Data screen) make a handful of times a day between them.
    ///
    /// `nonisolated` so `StoredDataAudit` can measure the file without hopping
    /// to the main actor to do it.
    nonisolated static func dailyBriefStore() -> DailyBriefStore? {
        guard let directory = try? DailyBriefStore.defaultDirectory() else { return nil }
        return DailyBriefStore(directory: directory)
    }

    // MARK: Reading the day

    /// Everything today is, read from the real sources and without a model.
    ///
    /// One call to `DayReader`, which reads concurrently, off the main actor,
    /// and never prompts. A source that is not readable is not read at all —
    /// the same gate the tools respect — and `Availability` carries which of
    /// "nothing on today" and "not allowed to look" this is.
    ///
    /// Under `-pocketd.demoHealth` Health is fabricated by `DemoDay` inside the
    /// reader and nothing is written anywhere: this app promises it never
    /// writes to Health, and a screenshot is not a reason to break that.
    func makeTodaySnapshot(now: Date = DemoClock.now, calendar: Calendar = .current) async -> TodaySnapshot {
        await DayReader.snapshot(
            now: now,
            calendar: calendar,
            access: DayReader.Access(
                calendar: availability(for: .calendar),
                reminders: availability(for: .reminders),
                health: DemoDay.isRequested ? .connected : briefingHealthAvailability
            )
        )
    }

    /// The brief's reading of one EventKit ability.
    ///
    /// Deliberately passes `.notApplicable` for the tool registration, unlike
    /// the Abilities rows. A model that is too small to be handed the calendar
    /// tool — or no model at all — has nothing to do with whether this app may
    /// read a calendar the user connected and iOS granted. Passing the
    /// registration here would switch the Today tiles off on the day somebody
    /// downloaded a smaller brain.
    private func availability(for entity: PersonalDataEntity) -> TodaySnapshot.Availability {
        let authorization = personalDataAuthorization[entity] ?? EventAccess.authorization(for: entity)
        let ability: Ability = entity == .calendar ? .calendar : .reminders
        return .of(AbilityState.of(ability, enabled: isEnabled(entity), grant: AbilityGrant(authorization)))
    }

    /// The same, for Health, whose grant iOS will never confirm.
    ///
    /// `.neverReported` rather than `.granted`, which `AbilityState.of` turns
    /// into `onButUnconfirmed` and `Availability.of` then reads as connected.
    /// That chain is documented at both ends; the alternative is a Sleep tile
    /// permanently reading "Off" on every iPhone ever sold.
    private var briefingHealthAvailability: TodaySnapshot.Availability {
        guard HealthAccess.isAvailable else { return .unavailable }
        let grant: AbilityGrant = switch healthAvailability {
        case .available: .neverReported
        case .noHealthData: .unavailable
        case let .requestFailed(reason): .failed(reason)
        }
        return .of(AbilityState.of(.health, enabled: healthToolsEnabled, grant: grant))
    }

    // MARK: Writing the brief

    /// How long a reading of the day is trusted before Today reads it again.
    ///
    /// The Today tab asks for a refresh every time it appears, and a refresh
    /// used to read EventKit and fifteen nights of HealthKit every time — on
    /// every tab switch. Five minutes is long enough that switching tabs is
    /// free and short enough that "in 2h 10m" never drifts far; the events
    /// that matter sooner than that (a permission, the calendar database,
    /// the app coming back to the front) mark the reading stale on their own.
    static let dayReadingShelfLife: TimeInterval = 5 * 60

    /// Rebuilds the day and, when there is a brain, has it write about it.
    ///
    /// The order is the whole design. The template brief is written and
    /// published *first*, always, and only then does a model get a turn — so
    /// the card on the home tab is never empty, never a spinner, and still says
    /// something true on a phone with nothing downloaded. A model that is
    /// absent, busy, or that fails halfway costs the user the difference
    /// between two good sentences and three better ones rather than the
    /// difference between a brief and a blank.
    ///
    /// A call that is not forced returns at once while the last reading is
    /// fresh (`dayReadingShelfLife`) and nothing has marked it stale. A call
    /// that arrives while a refresh is running is folded into it: a forced one
    /// runs straight after, and anything that marked the day stale meanwhile
    /// makes the running refresh read once more before it finishes.
    ///
    /// - Parameter force: Rewrite even if a model already wrote today's. What
    ///   the Refresh pill and pull-to-refresh pass.
    func refreshBrief(force: Bool = false) async {
        if briefing.isRefreshing {
            if force { briefing.wantsForcedPass = true }
            return
        }
        guard force || briefNeedsReading(now: DemoClock.now) else { return }
        briefing.isRefreshing = true
        var forced = force
        while true {
            briefing.isStale = false
            await rebuildBrief(force: forced)
            if briefing.wantsForcedPass {
                briefing.wantsForcedPass = false
                forced = true
            } else if briefing.isStale {
                forced = false
            } else {
                break
            }
        }
        briefing.isRefreshing = false
    }

    /// Something the day is read from has changed: mark the reading stale and
    /// read it again.
    ///
    /// Called by the connect door, by a permission that changed while the app
    /// was away, by the calendar database announcing a change, and by the app
    /// coming back to the front. Folded into a refresh that is already running.
    func dayMayHaveChanged() {
        briefing.isStale = true
        Task { await refreshBrief() }
    }

    private func briefNeedsReading(now: Date) -> Bool {
        guard !briefing.isStale, let last = briefing.lastRefresh else { return true }
        return now.timeIntervalSince(last) >= Self.dayReadingShelfLife
            || !Calendar.current.isDate(last, inSameDayAs: now)
    }

    /// One pass of `refreshBrief`: read the day, publish the template, and let
    /// a brain that can read the day rewrite it.
    private func rebuildBrief(force: Bool) async {
        let now = DemoClock.now
        let calendar = Calendar.current
        let store = Self.dailyBriefStore()

        // Yesterday's file is read before the calendar is, so a cold launch
        // shows a card rather than an empty one for the second EventKit takes
        // to answer. Only today's: a brief written at 23:50 is about yesterday
        // ten minutes later, which is what `isForToday` is for.
        if briefing.brief == nil, let stored = store?.read(), stored.isForToday(now: now, calendar: calendar) {
            briefing.snapshot = stored.snapshot
            if keepsStoredBrief(stored) {
                briefing.brief = stillTrue(stored, current: stored.snapshot, now: now, calendar: calendar)
                briefing.phase = .ready
            }
        }
        if briefing.phase == .idle { briefing.phase = .building }

        let snapshot = await makeTodaySnapshot(now: now, calendar: calendar)
        briefing.snapshot = snapshot
        briefing.lastRefresh = now

        // A model wrote today's and nobody asked again. Left alone — including
        // its text, which describes the morning it was written in and would be
        // a different paragraph if regenerated at teatime for no reason.
        //
        // Unless a brief routine has fired since it was written: the Evening
        // wrap-up at 21:00 is somebody asking again, and returning here kept
        // this morning's paragraph under an evening notification.
        //
        // Or unless the day has moved on under it. A paragraph written at noon
        // says lunch is next; at a quarter to two that lunch is being eaten,
        // and keeping the paragraph "for the rest of the day" kept saying so.
        let today = briefing.brief.flatMap { $0.isForToday(now: now, calendar: calendar) ? $0 : nil }
        let askedAgain = today.map { briefRoutineFired(since: $0.generatedAt, now: now, calendar: calendar) } ?? false
        let movedOn = today.map { !isStillTrue($0, current: snapshot, now: now, calendar: calendar) } ?? false
        defer { scheduleNextRewrite(after: now, snapshot: snapshot, calendar: calendar) }
        if !force, !askedAgain, !movedOn, let today, today.source != .template {
            briefing.phase = .ready
            return
        }

        // Whether a brain is free to take a turn at this, decided before
        // anything is published — because it decides what is published.
        //
        // Not when nothing is connected: a brain handed only the date writes
        // "It is Wednesday, 21 October, at 9:41 AM." in place of the one
        // sentence worth saying, which the template says — what connecting
        // would show.
        let brainIsBusy = isGenerating || briefing.generation != nil
        let willGenerate = mayWriteBrief && snapshot.hasAnythingConnected && !brainIsBusy

        // The template, unless a model already wrote today's and the model that
        // could write it again is merely busy. That case is a Refresh tapped
        // while the chat is answering, and replacing a good paragraph with the
        // template there would be losing the better text to produce the worse
        // one. The words stay; the snapshot travelling with them moves on,
        // which is what the widget in the other process reads.
        //
        // `mayWriteBrief` is the whole of the difference, and without it
        // Refresh was a button that did nothing: with no brain that can write
        // resident there is no better paragraph coming, ever, and the card went
        // on showing what a brain that has since been removed wrote hours ago.
        let republished: DailyBrief
        if mayWriteBrief, brainIsBusy, !movedOn, let today, today.source != .template {
            republished = DailyBrief(
                text: today.text, generatedAt: today.generatedAt, source: today.source, snapshot: snapshot
            )
        } else {
            republished = templateBrief(for: snapshot, now: now, calendar: calendar)
        }
        publish(republished, store: store, now: now, calendar: calendar)
        briefing.phase = .ready

        guard willGenerate else { return }
        startBriefGeneration(
            snapshot: snapshot,
            now: now,
            calendar: calendar,
            source: force ? .manual : .auto
        )
    }

    /// Whether a brain may write the brief, as opposed to the template.
    ///
    /// Three conditions, each one a failure seen on screen:
    /// - the brain is resident and not mid-load;
    /// - it can read the day. A brain that cannot use tools is a brain this
    ///   app has watched print its own instructions as the brief, and turn a
    ///   lunch into a letter asking for an appointment. The template is always
    ///   true; that brain's paragraph is not.
    /// - the intro is over. A brief written before anyone has given a name or
    ///   connected a calendar greets nobody about nothing, and it used to stay
    ///   on Today until a manual refresh.
    var mayWriteBrief: Bool {
        brainStatus.canWriteBrief && hasCompletedOnboarding
    }

    /// The deterministic brief, from the snapshot and the name.
    private func templateBrief(for snapshot: TodaySnapshot, now: Date, calendar: Calendar) -> DailyBrief {
        DailyBrief(
            text: BriefPrompt.fallback(
                snapshot: snapshot,
                name: profile.greetingName,
                now: now,
                calendar: calendar
            ),
            generatedAt: now,
            source: .template,
            snapshot: snapshot
        )
    }

    /// A brief read back from disk, or — when the day has moved on since it
    /// was written — the template for that same reading at `now`.
    ///
    /// For the first frame of a launch, before anything has been read: a
    /// paragraph from this morning saying lunch is next must not greet
    /// somebody opening the app mid-afternoon, even for the second it takes
    /// EventKit to answer. Not written to disk; the real reading does that.
    private func stillTrue(_ stored: DailyBrief, current: TodaySnapshot, now: Date, calendar: Calendar) -> DailyBrief {
        guard !isStillTrue(stored, current: current, now: now, calendar: calendar) else { return stored }
        return templateBrief(for: current, now: now, calendar: calendar)
    }

    /// Whether a brief still describes the day as it is now read.
    ///
    /// False once the day has moved on under it (`BriefPrompt.isOutdated`),
    /// and false when what the day is read from has changed since it was
    /// written: a paragraph written with the calendar off says nothing about
    /// the calendar somebody has just connected, and one written with it on
    /// goes on quoting it after it was switched off.
    private func isStillTrue(_ brief: DailyBrief, current: TodaySnapshot, now: Date, calendar: Calendar) -> Bool {
        let written = brief.snapshot
        guard written.calendar == current.calendar,
              written.reminders == current.reminders,
              written.health == current.health
        else { return false }
        return !BriefPrompt.isOutdated(writtenAt: brief.generatedAt, snapshot: current, now: now, calendar: calendar)
    }

    /// Reads the day again at the moment the brief stops being true.
    ///
    /// A screen left open on Today gets no appearance and no scene change to
    /// hang a refresh on, so without this the paragraph above a tile reading
    /// "In 3m" went on saying the meeting was next well after it began. One
    /// task, replaced on every reading: it sleeps until `BriefPrompt.nextRewrite`
    /// — the next start, end or timed reminder, or the next change of
    /// greeting — and marks the reading stale, which rewrites the template at
    /// once and lets a brain that can write it take its turn.
    ///
    /// A process that is suspended is asleep too, and catches up when it comes
    /// back, where the scene becoming active marks the reading stale anyway.
    private func scheduleNextRewrite(after now: Date, snapshot: TodaySnapshot, calendar: Calendar) {
        briefing.nextRewrite?.cancel()
        briefing.nextRewrite = nil
        guard let moment = BriefPrompt.nextRewrite(after: now, snapshot: snapshot, calendar: calendar) else { return }
        // A second past the moment, so the reading lands on the far side of
        // it; and never more than a few hours ahead, so one long sleep cannot
        // outlive a clock change.
        let delay = min(max(moment.timeIntervalSince(now) + 1, 1), 6 * 60 * 60)
        briefing.nextRewrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.dayMayHaveChanged()
        }
    }

    /// Whether a brief read back from disk may go back on screen.
    ///
    /// The template always may. A brain's paragraph may not when that brain
    /// is one that cannot read the day — those were the briefs that read the
    /// prompt back, and `brief.json` kept one on Today across relaunches — or
    /// when the text is mostly its own instructions, whoever wrote it.
    func keepsStoredBrief(_ brief: DailyBrief) -> Bool {
        guard case let .model(id) = brief.source else { return true }
        // Apple's model is in no catalogue, and reads the day.
        guard let writer = (catalog + [ModelRecord.builtIn]).first(where: { $0.id == id }),
              writer.dayAccess(resident: loadedModelID == id ? personalDataToolGate : nil).readsYourDay
        else { return false }
        return Self.screenedBrief(
            brief.text,
            instructions: Self.briefInstructions(name: profile.greetingName, now: brief.generatedAt),
            facts: BriefFacts(snapshot: brief.snapshot, now: brief.generatedAt)
        ) == brief.text
    }

    /// The brief's prompt as a brain would be handed it for a moment, for the
    /// echo check. Only its system turn counts as instructions; the day in
    /// the user turn is material a brief is supposed to repeat.
    private static func briefInstructions(name: String?, now: Date) -> [ChatMessage] {
        let calendar = Calendar.current
        return BriefPrompt.messages(
            snapshot: .empty,
            name: name,
            now: now,
            calendar: calendar,
            timeOfDay: TimeOfDayKind.from(now: now, calendar: calendar)
        )
    }

    /// What may be published of a brain's paragraph, or `nil` for the
    /// template.
    ///
    /// Two screens, in order. `PromptEcho` takes out instruction sentences the
    /// brain read back — SmolLM2 once wrote the whole system prompt as the
    /// brief, and the cache kept it on Today across relaunches — and refuses a
    /// paragraph that was mostly echo. `BriefPrompt.screened` then refuses a
    /// data dump or a time spelled out in words ("at eleven fifty seven AM"),
    /// puts plain counts into digits and keeps it to whole sentences — and
    /// checks every time, length and number against the day it was written
    /// from (`BriefFacts`): a brief that puts tomorrow's meeting this
    /// afternoon, or gets the sleep gap wrong, keeps the template instead.
    static func screenedBrief(_ text: String, instructions: [ChatMessage], facts: BriefFacts) -> String? {
        let cleaned = PromptEcho.clean(BriefPrompt.clean(text), against: instructions)
        guard !cleaned.isMostlyEcho else { return nil }
        return BriefPrompt.screened(cleaned.text, facts: facts)
    }

    /// Stores the brief, mirrors it for the widget, and puts it on screen.
    ///
    /// One function so that the three can never drift apart. They did in v1's
    /// schedule publication, and the symptom is a home screen showing a brief
    /// the app itself does not have.
    private func publish(_ brief: DailyBrief, store: DailyBriefStore?, now: Date, calendar: Calendar) {
        briefing.brief = brief
        store?.write(brief, name: profile.greetingName, now: now, calendar: calendar)
    }

    /// Hands the snapshot to whatever brain is resident.
    ///
    /// No tools are needed and none are asked for — every fact the prompt is
    /// allowed to use is already inside it, which is what makes this work on a
    /// model too small to be trusted with a tool call. The origin is still
    /// `.onDeviceChat`, because this is a person's own phone writing about
    /// their own day and the network origins must never reach either.
    private func startBriefGeneration(
        snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar,
        source: BriefSource
    ) {
        // A generation already in flight is the same generation: a second
        // foreground while the first is streaming must not start a race for the
        // engine's gate against it.
        guard briefing.generation == nil else { return }
        // Chat wins, here and in `send()`. A brief nobody asked for must not
        // queue in front of a question somebody typed.
        guard let modelID = loadedModelID, !isGenerating else { return }

        let request = GenerationRequest(
            modelID: modelID,
            messages: BriefPrompt.messages(
                snapshot: snapshot,
                name: profile.greetingName,
                now: now,
                calendar: calendar,
                timeOfDay: TimeOfDayKind.from(now: now, calendar: calendar)
            ),
            // Three sentences. The cap is what stops a small model that has
            // started listing the user's week from filling the home tab with it.
            options: GenerationOptions(maxTokens: 160),
            origin: .onDeviceChat
        )

        briefing.streamingText = ""
        briefing.phase = .streaming
        // Monotonic rather than `Date`, for the reason `loadModel` gives: a
        // clock correction mid-generation would put a negative duration in a
        // column that cannot mean anything by it.
        let started = ContinuousClock.now

        briefing.generation = Task { [weak self] in
            guard let self else { return }
            var raw = ""
            do {
                // Without tools: every fact the brief may use is in its
                // prompt, and Apple's model handed tools would look the day up
                // again and write about a card the brief never shows. A
                // download answers exactly as before.
                for try await event in try await self.phoneBrain.generateWithoutTools(request) {
                    guard case let .token(chunk) = event else { continue }
                    raw += chunk
                    // Cleaned on every token rather than at the end, because
                    // what the caret is trailing is what the reader sees: a
                    // model that opens with `<think>` would otherwise print its
                    // working out on the home tab for twenty seconds and then
                    // replace it.
                    self.briefing.streamingText = BriefPrompt.clean(raw)
                }
            } catch {
                self.failBriefGeneration(error)
                return
            }
            self.finishBriefGeneration(
                raw: raw,
                instructions: request.messages,
                modelID: modelID,
                snapshot: snapshot,
                source: source,
                milliseconds: Int(started.duration(to: .now) / .milliseconds(1)),
                now: now,
                calendar: calendar
            )
        }
    }

    private func finishBriefGeneration(
        raw: String,
        instructions: [ChatMessage],
        modelID: String,
        snapshot: TodaySnapshot,
        source: BriefSource,
        milliseconds: Int,
        now: Date,
        calendar: Calendar
    ) {
        briefing.generation = nil
        briefing.streamingText = ""
        briefing.phase = .ready
        guard !Task.isCancelled else { return }

        // A model that emitted nothing usable leaves the template standing.
        // Replacing two true sentences with an empty card is the one outcome
        // worse than not having a brain at all. The same goes for a paragraph
        // that is mostly its own instructions read back, or that spells the
        // time out in words; see `screenedBrief`.
        guard let text = Self.screenedBrief(
            raw,
            instructions: instructions,
            facts: BriefFacts(snapshot: snapshot, now: now, calendar: calendar)
        ) else {
            // Refused: the template already on screen stays, and that is the
            // right outcome — it is true, and a paragraph with one wrong figure
            // is not. Counted, so how often the brain is overruled is known.
            DiagnosticLog.record(.failure(area: .model, code: "brief_screened_out"))
            return
        }

        publish(
            DailyBrief(text: text, generatedAt: now, source: .model(id: modelID), snapshot: snapshot),
            store: Self.dailyBriefStore(),
            now: now,
            calendar: calendar
        )
        record(.briefGenerated(source: source, durationMilliseconds: milliseconds))
    }

    /// A generation that threw.
    ///
    /// Cancellation is not a failure and is not reported as one: it is what
    /// `send()` and the scene going to the background both do on purpose, and
    /// the template brief is still on screen and still true.
    private func failBriefGeneration(_ error: any Error) {
        briefing.generation = nil
        briefing.streamingText = ""
        guard !Task.isCancelled, !(error is CancellationError) else {
            briefing.phase = .ready
            return
        }
        briefing.phase = .failed(
            (error as? LocalizedError)?.errorDescription ?? "The brief could not be written."
        )
    }

    /// Stops a brief being written, keeping whatever is already published.
    ///
    /// Called by `send()` — a person typing outranks a paragraph nobody asked
    /// for — and on the way to the background, where Metal refuses a
    /// backgrounded app's command buffers and the generation would fail rather
    /// than merely be slow.
    func cancelBriefGeneration() {
        guard let generation = briefing.generation else { return }
        briefing.generation = nil
        generation.cancel()
        briefing.streamingText = ""
        if briefing.phase == .streaming { briefing.phase = .ready }
    }

    /// The speaker button was used. Analytics only; `ReadAloud` does the work.
    func markReadAloud() {
        record(.briefReadAloud)
    }

    // MARK: First paint, names, and the calendar database

    /// What Today shows in its very first frame, before anything is read.
    ///
    /// Called from `init`, synchronously, because the first frame is drawn
    /// before `bootstrap` gets a turn. It used to be `TodaySnapshot.empty`,
    /// which is every source switched off: a phone with Calendar connected
    /// opened on four "Off" tiles and an invitation to connect what was
    /// already connected. Now it is today's last reading from disk, with each
    /// source's availability taken from the switches and iOS as they stand
    /// this moment — a cheap, synchronous lookup — and the real reading
    /// replaces it a second later.
    func primeTodayFromDisk(now: Date = DemoClock.now, calendar: Calendar = .current) {
        var snapshot = TodaySnapshot.empty
        let stored = Self.dailyBriefStore()?.read().flatMap { $0.isForToday(now: now, calendar: calendar) ? $0 : nil }
        if let stored { snapshot = stored.snapshot }
        snapshot.calendar = availability(for: .calendar)
        snapshot.reminders = availability(for: .reminders)
        snapshot.health = DemoDay.isRequested ? .connected : briefingHealthAvailability
        // Judged against the sources as they stand now, not as they stood
        // when it was written: see `isStillTrue`.
        if let stored, keepsStoredBrief(stored) {
            briefing.brief = stillTrue(stored, current: snapshot, now: now, calendar: calendar)
            briefing.phase = .ready
        }
        briefing.snapshot = snapshot
    }

    /// The name changed, so the greeting is wrong.
    ///
    /// The template is re-rendered at once from the reading already on
    /// screen — a name is not a reason to read the calendar again. A brain's
    /// paragraph greets by the old name, so it is replaced by the template and
    /// written again by a brain that can.
    func nameDidChange() {
        cancelBriefGeneration()
        guard briefing.lastRefresh != nil else {
            // Nothing read yet: the first reading uses the new name anyway.
            dayMayHaveChanged()
            return
        }
        let now = DemoClock.now
        let calendar = Calendar.current
        publish(
            templateBrief(for: briefing.snapshot, now: now, calendar: calendar),
            store: Self.dailyBriefStore(),
            now: now,
            calendar: calendar
        )
        briefing.phase = .ready
        guard mayWriteBrief else { return }
        Task { await refreshBrief(force: true) }
    }

    /// Reads the day again whenever the calendar database changes — another
    /// app, a sync, or one of Pocketd's own writes.
    ///
    /// Without it a reading stays trusted for `dayReadingShelfLife`, which is
    /// right for tab switches and wrong for the meeting somebody just moved.
    /// EventKit posts in bursts; a burst during a reading costs one more
    /// reading, because `refreshBrief` folds the rest into it.
    func watchCalendarDatabase() {
        guard calendarDatabaseObserver == nil else { return }
        calendarDatabaseObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayMayHaveChanged() }
        }
    }

    /// A refresh that only runs if today's brief is still the template.
    ///
    /// What `loadModel` calls on the way out. A brain that has just arrived is
    /// exactly the moment the morning's placeholder paragraph should be
    /// rewritten in its own words, and nothing else in the app would notice.
    ///
    /// No brief at all means the app has not built one yet, which happens
    /// during launch — `bootstrap` has its own call at the end and this one
    /// stepping in front of it would read EventKit twice for one paragraph.
    func refreshBriefIfStillTemplate() async {
        // Only for a brain that may write it: a brain that cannot read the day
        // leaves the template standing, and forcing a pass for it would read
        // EventKit and HealthKit again to publish the same paragraph.
        guard mayWriteBrief, let brief = briefing.brief, brief.source == .template else { return }
        await refreshBrief(force: true)
    }
}
