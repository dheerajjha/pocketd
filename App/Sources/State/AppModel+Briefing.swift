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

// MARK: - Fabricated Health, for a simulator

/// Health figures for a machine that has no Health.
///
/// A simulator has an empty HealthKit store and no way to fill one that does
/// not involve writing samples — which this app promises it never does, on the
/// Privacy screen, in the App Store listing and in its own permission copy. So
/// the numbers are fabricated here, at the point the snapshot is assembled, and
/// nothing is written anywhere: the store is not read, not asked for
/// permission, and not touched.
///
/// Every member is `nil` unless `-pocketd.demoHealth` was passed, and the whole
/// type is inside `#if DEBUG`, so a Release build has no path through any of
/// it — the same shape `DemoSeed` uses and for the same reason. Kept here
/// rather than in `DemoSeed` because that file stages the *device's* calendar
/// and reminders, which are real stores a real install shares; this stages
/// nothing and only decorates one value on its way to a view.
enum DemoHealth {
    #if DEBUG
    static let isRequested = ProcessInfo.processInfo.arguments.contains("-pocketd.demoHealth")
    #else
    static let isRequested = false
    #endif

    /// 6h 36m, against a usual of 7h 05m — a slightly short night, which is the
    /// state worth photographing because it is the one with a tone on it.
    static var sleepLastNight: TimeInterval? { isRequested ? 23_760 : nil }
    static var sleepUsual: TimeInterval? { isRequested ? 25_500 : nil }
    /// Mid-morning against a whole day's usual, so the tile reads as a day in
    /// progress rather than as a day that went wrong.
    static var stepsToday: Double? { isRequested ? 4_120 : nil }
    static var stepsUsual: Double? { isRequested ? 6_100 : nil }
    static var restingHeartRate: Double? { isRequested ? 58 : nil }
    static var restingHeartRateUsual: Double? { isRequested ? 61 : nil }
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
    /// Every read runs concurrently and none of them runs on the main actor:
    /// EventKit blocks on a daemon and HealthKit blocks on a database, and
    /// doing either from a `body` drops frames on the one screen the app opens
    /// to. The three static helpers below are `nonisolated` for exactly that.
    ///
    /// A source that is not readable is not read at all. That is the same gate
    /// the tools respect, and it is the difference between an app that shows a
    /// clear diary and an app that shows a clear diary to somebody whose
    /// calendar permission it lost three weeks ago — `Availability` carries
    /// which of the two this is, and every consumer branches on it.
    func makeTodaySnapshot(now: Date = Date(), calendar: Calendar = .current) async -> TodaySnapshot {
        let calendarAvailability = availability(for: .calendar)
        let remindersAvailability = availability(for: .reminders)
        let health: TodaySnapshot.Availability = DemoHealth.isRequested ? .connected : briefingHealthAvailability

        async let events = Self.readEvents(readable: calendarAvailability.isReadable, now: now, calendar: calendar)
        async let reminders = Self.readReminders(readable: remindersAvailability.isReadable, now: now, calendar: calendar)
        // Not read at all under `-pocketd.demoHealth`: the fabricated figures
        // below replace the reads rather than being written anywhere, because
        // this app promises it never writes to Health and a screenshot is not a
        // reason to break that.
        async let sleep = Self.readSleep(
            readable: health.isReadable && !DemoHealth.isRequested, now: now, calendar: calendar
        )
        async let steps = Self.readSteps(
            readable: health.isReadable && !DemoHealth.isRequested, now: now, calendar: calendar
        )

        let (dueToday, overdue) = await reminders
        let (sleptLastNight, usualSleep) = await sleep
        let (stepsToday, usualSteps) = await steps

        return TodaySnapshot(
            generatedAt: now,
            calendar: calendarAvailability,
            reminders: remindersAvailability,
            health: health,
            events: await events,
            dueToday: dueToday,
            overdue: overdue,
            sleepLastNight: DemoHealth.sleepLastNight ?? sleptLastNight,
            sleepUsual: DemoHealth.sleepUsual ?? usualSleep,
            stepsToday: DemoHealth.stepsToday ?? stepsToday,
            stepsUsual: DemoHealth.stepsUsual ?? usualSteps,
            restingHeartRate: DemoHealth.restingHeartRate,
            restingHeartRateUsual: DemoHealth.restingHeartRateUsual
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

    /// What is left of today, then tomorrow.
    ///
    /// The window opens at `now` rather than at midnight because the card's
    /// job is the rest of the day: a standup that finished at 09:45 is not
    /// news at eleven, and leaving it in pushes the meeting that has not
    /// happened yet out of a prompt with a 900-character budget. EventKit
    /// returns anything *overlapping* the window, so something in progress
    /// still comes back — which is right, and which `nextEvent(now:)` then
    /// filters out of the tile.
    private nonisolated static func readEvents(
        readable: Bool,
        now: Date,
        calendar: Calendar
    ) async -> [BriefEvent] {
        guard readable else { return [] }
        let startOfToday = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: startOfToday), end > now else { return [] }
        switch await EventAccess.shared.events(in: DateInterval(start: now, end: end)) {
        case let .rows(rows, _):
            return rows.map(BriefEvent.init)
        // Unreachable behind the `readable` gate, and still a value rather than
        // a trap: a permission can be revoked between the check and the read.
        case .unauthorized:
            return []
        }
    }

    /// Open reminders due by the end of today, split at this morning's midnight.
    ///
    /// "Due today" and "overdue" are one EventKit read rather than two, because
    /// two predicates against the same daemon cost twice as much and can
    /// disagree about the boundary if the clock ticks between them. Undated
    /// reminders are excluded by the window — `DateWindow(start: nil, end: nil)`
    /// is the only shape that returns them, and a shopping list is not a thing
    /// that is due.
    private nonisolated static func readReminders(
        readable: Bool,
        now: Date,
        calendar: Calendar
    ) async -> (due: [BriefReminder], overdue: [BriefReminder]) {
        guard readable else { return ([], []) }
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return ([], []) }
        switch await EventAccess.shared.reminders(in: DateWindow(start: nil, end: endOfToday)) {
        case let .rows(rows, _):
            var due: [BriefReminder] = []
            var overdue: [BriefReminder] = []
            for row in rows {
                guard let deadline = row.due else { continue }
                if deadline < startOfToday {
                    overdue.append(BriefReminder(row))
                } else {
                    due.append(BriefReminder(row))
                }
            }
            return (due, overdue)
        case .unauthorized:
            return ([], [])
        }
    }

    /// Last night, and what a night usually is for this person.
    ///
    /// The baseline deliberately excludes the night it is about. A night
    /// included in its own median drags the median towards itself, and the
    /// comparison the Sleep tile prints is then partly a comparison with
    /// itself — the same argument `HealthSummary.baseline(endingBefore:)`
    /// makes at greater length.
    private nonisolated static func readSleep(
        readable: Bool,
        now: Date,
        calendar: Calendar
    ) async -> (lastNight: TimeInterval?, usual: TimeInterval?) {
        guard readable else { return (nil, nil) }
        let startOfToday = calendar.startOfDay(for: now)
        // One night more than the baseline wants, because last night is read
        // from this window too and is then dropped out of the baseline.
        guard let from = calendar.date(byAdding: .day, value: -(Usual.baselineNights + 1), to: startOfToday) else {
            return (nil, nil)
        }
        let readout = await HealthAccess.shared.readout(for: .sleep, in: DateInterval(start: from, end: now))
        guard readout.availability == .available else { return (nil, nil) }
        let nights = HealthArithmetic.nightlyTotals(readout.sleep, calendar: calendar)
        let lastNight = nights.last { calendar.isDate($0.day, inSameDayAs: now) }?.value
        let earlier = nights.filter { $0.day < startOfToday }.map(\.value)
        return (lastNight, Usual.typicalSleep(earlier))
    }

    /// Today so far, and the median of the fortnight behind it.
    ///
    /// Today is excluded from its own baseline for the reason above and one
    /// more that is specific to steps: today is a partial day and every other
    /// day in the window is a whole one, so including it would pull "usual"
    /// down every single morning.
    private nonisolated static func readSteps(
        readable: Bool,
        now: Date,
        calendar: Calendar
    ) async -> (today: Double?, usual: Double?) {
        guard readable else { return (nil, nil) }
        let startOfToday = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -Usual.baselineNights, to: startOfToday) else {
            return (nil, nil)
        }
        let readout = await HealthAccess.shared.readout(for: .activity, in: DateInterval(start: from, end: now))
        guard readout.availability == .available else { return (nil, nil) }
        let days = HealthArithmetic.daily(readout.samples[.steps] ?? [], metric: .steps, calendar: calendar)
        let today = days.last { calendar.isDate($0.day, inSameDayAs: now) }?.value
        let earlier = days.filter { $0.day < startOfToday }.map(\.value)
        return (today, Usual.median(earlier))
    }

    // MARK: Writing the brief

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
    /// - Parameter force: Rewrite even if a model already wrote today's. What
    ///   the Refresh pill and pull-to-refresh pass.
    func refreshBrief(force: Bool = false) async {
        guard !briefing.isRefreshing else { return }
        briefing.isRefreshing = true
        defer { briefing.isRefreshing = false }

        let now = Date()
        let calendar = Calendar.current
        let store = Self.dailyBriefStore()

        // Yesterday's file is read before the calendar is, so a cold launch
        // shows a card rather than an empty one for the second EventKit takes
        // to answer. Only today's: a brief written at 23:50 is about yesterday
        // ten minutes later, which is what `isForToday` is for.
        if briefing.brief == nil, let stored = store?.read(), stored.isForToday(now: now, calendar: calendar) {
            briefing.brief = stored
            briefing.snapshot = stored.snapshot
            briefing.phase = .ready
        }
        if briefing.phase == .idle { briefing.phase = .building }

        let snapshot = await makeTodaySnapshot(now: now, calendar: calendar)
        briefing.snapshot = snapshot
        briefing.lastRefresh = now

        // A model wrote today's and nobody asked again. Left alone — including
        // its text, which describes the morning it was written in and would be
        // a different paragraph if regenerated at teatime for no reason.
        let today = briefing.brief.flatMap { $0.isForToday(now: now, calendar: calendar) ? $0 : nil }
        if !force, let today, today.source != .template {
            briefing.phase = .ready
            return
        }

        // Whether a brain is free to take a turn at this, decided before
        // anything is published — because it decides what is published.
        let willGenerate = loadedModelID != nil && !isGenerating && briefing.generation == nil

        // The template, unless a model already wrote today's and no model is
        // free to write it again. That case is a Refresh tapped while the chat
        // is answering, and replacing a good paragraph with the template there
        // would be losing the better text to produce the worse one. The words
        // stay; the snapshot travelling with them moves on, which is what the
        // widget in the other process reads.
        let republished: DailyBrief
        if !willGenerate, let today, today.source != .template {
            republished = DailyBrief(
                text: today.text, generatedAt: today.generatedAt, source: today.source, snapshot: snapshot
            )
        } else {
            republished = DailyBrief(
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
                for try await event in try await self.engine.generate(request) {
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

        let text = Self.trimmedToSentences(BriefPrompt.clean(raw))
        // A model that emitted nothing usable leaves the template standing.
        // Replacing two true sentences with an empty card is the one outcome
        // worse than not having a brain at all.
        guard text.count >= 20 else { return }

        publish(
            DailyBrief(text: text, generatedAt: now, source: .model(id: modelID), snapshot: snapshot),
            store: Self.dailyBriefStore(),
            now: now,
            calendar: calendar
        )
        record(.briefGenerated(source: source, durationMilliseconds: milliseconds))
    }

    /// At most four sentences, and never half of one.
    ///
    /// Two separate faults, both seen on a 360M model on a simulator, and both
    /// of them land on the home tab.
    ///
    /// The token cap cuts wherever the budget runs out — "…we'll have a few
    /// minutes before they arrive at 10:00 PM, and I'd like" — and a paragraph
    /// that stops mid-clause reads as a crash rather than as a brief. And a
    /// small model told to write three sentences sometimes writes nine, which
    /// on this screen pushes all four tiles off the bottom of the phone.
    ///
    /// Cut at a terminator rather than at a character count, so what survives
    /// is whole sentences; text with no terminator at all comes back untouched,
    /// because losing the paragraph entirely is worse than showing an odd one.
    /// An abbreviation costs a sentence of the budget — "Mr." counts — which is
    /// the price of not shipping a sentence tokeniser for a card that wants
    /// three lines.
    static func trimmedToSentences(_ text: String, limit: Int = 4) -> String {
        var ends: [String.Index] = []
        for index in text.indices where ".!?".contains(text[index]) {
            ends.append(index)
            if ends.count == limit { break }
        }
        guard let last = ends.last else { return text }
        return String(text[...last])
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
        guard let brief = briefing.brief, brief.source == .template else { return }
        await refreshBrief(force: true)
    }
}
