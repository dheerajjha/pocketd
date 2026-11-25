import Foundation
import Testing
@testable import PocketdKit

/// Reading first: a personal question is answered from reads the engine makes
/// itself, never from whatever Apple's model remembers or invents.
///
/// The questions are QA's repro (walkthrough-after S1-1) and its neighbours:
/// each must read the right thing, a change must keep the tool path, and a
/// question about anything else must read nothing.
@Suite("Built-in brain reads first")
struct SystemModelReadsTests {

    private let everything: Set<CapabilityGroup> = [.calendar, .reminders, .health]

    /// Wednesday 21 October 2026, 13:45, Gregorian, weeks from Sunday.
    private let now: Date = {
        var components = DateComponents(year: 2026, month: 10, day: 21, hour: 13, minute: 45)
        components.timeZone = TimeZone(identifier: "Europe/London")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func reads(
        _ question: String,
        enabled: Set<CapabilityGroup>? = nil,
        origin: RequestOrigin = .onDeviceChat,
        history: [ChatMessage] = []
    ) -> [SystemModelReads.Read]? {
        SystemModelReads.plan(
            for: GenerationRequest(modelID: "", messages: history + [.user(question + "\n/no_think")], origin: origin),
            enabled: enabled ?? everything,
            now: now,
            calendar: calendar
        )
    }

    @Test("QA's repro questions each read the right thing")
    func qaRepro() {
        #expect(reads("What's on tomorrow?") == [.calendar(.tomorrow)])
        #expect(reads("How did I sleep?") == [.health(.sleep)])
        #expect(reads("Anything overdue?") == [.reminders(.overdue)])
    }

    @Test("a change keeps the tool path")
    func changesAreNotReads() {
        #expect(reads("Remind me to call mom at 6pm") == nil)
        #expect(reads("Add lunch with Sam on Friday at 1") == nil)
        #expect(reads("Please put the dentist in for Tuesday") == nil)
        #expect(reads("Tick off buy oat milk") == nil)
    }

    @Test("a question about anything else reads nothing")
    func unrelatedReadsNothing() {
        #expect(reads("What is the capital of France?") == nil)
        #expect(reads("Write a story about a lighthouse keeper.") == nil)
        #expect(reads("Thanks!") == nil)
    }

    @Test("a question naming two domains reads both")
    func twoDomains() {
        #expect(reads("What meetings and reminders do I have tomorrow?") == [.calendar(.tomorrow), .reminders(.tomorrow)])
    }

    @Test("ranges follow the words")
    func ranges() {
        #expect(reads("What's on my calendar today?") == [.calendar(.today)])
        #expect(reads("What does my week look like?") == [.calendar(.this_week)])
        #expect(reads("Any meetings next week?") == [.calendar(.next_week)])
        // From a Wednesday: Thursday is tomorrow, Friday later this week,
        // Monday next week, Wednesday today.
        #expect(reads("What about Thursday?") == [.calendar(.tomorrow)])
        #expect(reads("What about Friday?") == [.calendar(.this_week)])
        #expect(reads("What about Monday?") == [.calendar(.next_week)])
        #expect(reads("Anything on Wednesday?") == [.calendar(.today)])
    }

    @Test("reminder filters follow the words")
    func filters() {
        #expect(reads("What's due today?") == [.reminders(.today)])
        #expect(reads("What's due tomorrow?") == [.reminders(.tomorrow)])
        #expect(reads("Show me my reminders") == [.reminders(.all_open)])
        #expect(reads("Any tasks this week?") == [.reminders(.this_week)])
    }

    @Test("health focuses follow the words")
    func focuses() {
        #expect(reads("How many steps did I take?") == [.health(.activity)])
        #expect(reads("What's my resting heart rate?") == [.health(.heart)])
        #expect(reads("How was my workout?") == [.health(.workouts)])
    }

    @Test("each fact says what was read, as the card's heading does")
    func factHeadings() {
        // "3 reminders:" alone was answered "nothing is overdue" on the simulator.
        let overdue = SystemModelReads.fact(for: .reminders(.overdue), rendered: "3 reminders:\n- Submit expenses · due Tue 20 Oct, 18:00")
        #expect(overdue.hasPrefix("The user's overdue reminders"))
        #expect(overdue.contains("past its due time"))
        #expect(overdue.hasSuffix("- Submit expenses · due Tue 20 Oct, 18:00"))
        #expect(SystemModelReads.fact(for: .calendar(.tomorrow), rendered: "No events tomorrow.").hasPrefix("The user's calendar events tomorrow:"))
        #expect(SystemModelReads.fact(for: .health(.sleep), rendered: "- Sleep: 6h 36m").contains("(sleep)"))
        #expect(SystemModelReads.fact(for: .switchedOff(.health), rendered: "x") == "x")
    }

    @Test("a switched-off domain is said, not read and not invented")
    func switchedOff() {
        #expect(reads("What's on tomorrow?", enabled: [.reminders]) == [.switchedOff(.calendar)])
        #expect(SystemModelReads.switchedOffFact(.calendar).contains("calendar"))
    }

    @Test("a network caller is never read for")
    func networkNeverReads() {
        #expect(reads("What's on tomorrow?", origin: .network(host: "10.0.0.2", port: 1)) == nil)
    }

    @Test("the answer is planned from the facts alone, with no history and no tools")
    func answeringPlan() {
        let request = GenerationRequest(
            modelID: "",
            messages: [
                .system("Current date and time: Wednesday."),
                .user("Remind me to call mom at 6pm"),
                .assistant("Reminder set."),
                .user("How did I sleep?\n/no_think")
            ],
            options: GenerationOptions(maxTokens: 4096),
            origin: .onDeviceChat
        )
        let plan = SystemModelReads.plan(
            answering: request,
            facts: ["- Sleep: 6h 36m on Tue 20 Oct — 29 min under your usual"],
            reads: [.health(.sleep)]
        )
        #expect(plan.tools.isEmpty)
        #expect(plan.history.isEmpty)
        #expect(plan.droppedTurns == 2)
        #expect(plan.instructions.hasPrefix(SystemModelReads.factsPreamble))
        #expect(plan.instructions.contains(SystemModelPlan.healthRule))
        #expect(plan.instructions.hasSuffix("Current date and time: Wednesday."))
        #expect(plan.prompt.hasPrefix("Facts read from my iPhone just now:\n- Sleep: 6h 36m"))
        #expect(plan.prompt.hasSuffix("My question: How did I sleep?"))
        #expect(plan.responseTokens == SystemModelBudget.standard.responseTokens)
    }
}

@Suite("Downloaded brain: phone reads without a model tool call")
struct DownloadedDayReadTests {
    private typealias Read = SystemModelReads.Read
    private typealias Fetch = @Sendable (Read, RequestOrigin) async -> Read.Payload

    /// Same request shape as Ask and the same descriptor/body binding as
    /// SystemReads. Replace the OS lookup; collect the actual chat events.
    private func run(
        _ question: String, origin: RequestOrigin = .onDeviceChat, gate: ToolGate.Decision = .declaredCapable,
        history: [ChatMessage] = [], images: [Data] = [], admitted: @Sendable (String) async -> Bool = { _ in true },
        observe: @Sendable (GenerationEvent) -> Void = { _ in }, fetch: @escaping Fetch
    ) async throws -> (handled: Bool, events: [GenerationEvent]) {
        let request = GenerationRequest(modelID: "qwen3-1.7b", messages: DateContext.inject(into:
            history + [ChatMessage(role: .user, content: question, images: images)]), origin: origin)
        let (stream, sink) = AsyncStream<GenerationEvent>.makeStream()
        defer { sink.finish() }
        let handled = try await DownloadedDayRead.answer(request, gate: gate, callFor: { read in
            read.call(calendar: { await fetch(.calendar($0), $1) }, reminders: { await fetch(.reminders($0), $1) },
                      health: { await fetch(.health($0), $1) })
        }, isAdmitted: admitted, emit: { sink.yield($0); observe($0) })
        sink.finish()
        var events: [GenerationEvent] = []
        for await event in stream { events.append(event) }
        return (handled, events)
    }

    @Test("The Calendar detail chip reads tomorrow's local day and returns its card, not an old answer")
    func tomorrowChip() async throws {
        let calendar = Calendar.current
        // In America/Los_Angeles tomorrow is a 23-hour day. Use the real
        // calendarPayload defaults: neither midnight UTC nor a fixed 24 hours.
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 55))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        let rows = [("Old day", now), ("Blue folder", start), ("Amber kite", end.addingTimeInterval(-120)), ("Next day", end)].map {
            CalendarEventRow(title: $0.0, start: $0.1, end: $0.1.addingTimeInterval(60))
        }
        let result = try await run("What's on tomorrow?", history: [.user("Anything overdue?"), .assistant("Old, unrelated answer.")]) { read, origin in
            guard case let .calendar(range) = read else { Issue.record("Wrong source: \(read)"); return [:] }
            #expect(range == .tomorrow && origin == .onDeviceChat)
            return await PersonalDataTools.calendarPayload(range: range, now: now, origin: origin) { interval in
                #expect(interval.start == start && interval.end == end)
                return .rows(rows.filter { $0.start < interval.end && $0.end > interval.start }, truncated: false)
            }
        }
        #expect(result.handled)
        let cards = result.events.compactMap { event -> AnswerCard? in if case let .answerCard(card) = event { card } else { nil } }
        let card = try #require(cards.first)
        #expect(card.title == "Tomorrow" && card.source == PersonalDataToolNames.calendar)
        guard case let .list(list) = card.sections.first else { Issue.record("No agenda rows"); return }
        #expect(list.items.map(\.text) == ["Blue folder", "Amber kite"])
        #expect(list.items.last?.detail?.contains(PersonalDataFormat.moment(end.addingTimeInterval(-120))) == true)
        #expect(result.events == [.toolCallStarted(name: "calendar"), .answerCard(card), .token("You have 2 events tomorrow."),
                                  .finished(reason: .stop, usage: TokenUsage())])
    }

    @Test("Empty, denied and truncated reads never turn into an invented empty day or total")
    func calendarOutcomes() async throws {
        let row = CalendarEventRow(title: "Fixture", start: .now, end: .now)
        let cases: [(PersonalDataLookup<CalendarEventRow>, String)] = [
            (.rows([], truncated: false), CalendarRange.tomorrow.emptyText),
            (.unauthorized(.denied), PersonalDataAuthorization.denied.explanation(for: .calendar)),
            (.rows(Array(repeating: row, count: 20), truncated: true), "Showing the first 20 events tomorrow.")
        ]
        for (lookup, text) in cases {
            let result = try await run("What’s on my calendar tomorrow?") { read, origin in
                guard case .calendar(let range) = read else { Issue.record("Wrong source"); return [:] }
                return await PersonalDataTools.calendarPayload(range: range, origin: origin) { _ in lookup }
            }
            #expect(result.handled && result.events.contains(.token(text)))
            #expect(result.events.contains { if case let .answerCard(c) = $0 { c.title == "Tomorrow" } else { false } })
        }
        let failed = try await run("What's on tomorrow?") { _, _ in [:] }
        #expect(failed.handled && failed.events.contains(.token("Pocketd couldn't check your calendar this time.")))
        #expect(!failed.events.contains(.token(CalendarRange.tomorrow.emptyText)))
    }

    @Test("Other self-contained chips select the right store and report its outcome")
    func adjacentChips() async throws {
        let inputs: [(String, Read)] = [("What's on today?", .calendar(.today)), ("What is on next week?", .calendar(.next_week)),
                                       ("Anything overdue?", .reminders(.overdue)), ("What's due tomorrow?", .reminders(.tomorrow)),
                                       ("How did I sleep?", .health(.sleep))]
        for (question, expected) in inputs {
            let result = try await run(question) { read, origin in
                #expect(read == expected && origin == .onDeviceChat)
                switch read {
                case .reminders(let filter): return await PersonalDataTools.reminderPayload(filter: filter, origin: origin) { _ in .rows([], truncated: false) }
                case .calendar(let range): return ["text": range.emptyText]
                case .health(let focus): return await HealthSummary.payload(focus: focus, origin: origin) { _, _ in HealthReadout() }
                case .switchedOff: Issue.record("Unexpected lookup"); return [:]
                }
            }
            #expect(result.handled && result.events.count == 4)
            if case .health(.sleep) = expected { #expect(result.events.contains(.token(HealthSummary.ambiguity(for: .sleep)))) }
        }
    }

    @Test("The downloaded reminder lookup keeps distinct native row actions off the text path")
    func actionableReminders() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 750_000_000)
        let result = try await run("Anything overdue?") { read, origin in
            guard case .reminders(let filter) = read else { Issue.record("Wrong source"); return [:] }
            return await PersonalDataTools.reminderPayload(filter: filter, now: now, origin: origin) { _ in
                .rows([ReminderRow(title: "Send invoice", due: now.addingTimeInterval(-7200), identifier: "fixture-alpha"),
                       ReminderRow(title: "Send invoice", due: now.addingTimeInterval(-3600), identifier: "fixture-beta")], truncated: false)
            }
        }
        let cards = result.events.compactMap { event -> AnswerCard? in if case let .answerCard(card) = event { card } else { nil } }
        let card = try #require(cards.first)
        guard case .list(let list) = card.sections.first else { Issue.record("No reminder rows"); return }
        #expect(list.items.map { $0.reminder?.id } == ["fixture-alpha", "fixture-beta"])
        #expect(result.events.contains(.token("You have 2 overdue reminders.")))
        #expect(!card.transcript.contains("fixture-"))
    }

    @Test("Writes, combined asks, unsupported scopes, other origins and chat-only brains stay on the normal path")
    func leavesOrdinaryGenerationAlone() async throws {
        let inputs: [(String, RequestOrigin, ToolGate.Decision, [Data])] = [
            ("Add a meeting tomorrow", .onDeviceChat, .declaredCapable, []),
            ("What's on tomorrow? Then add a reminder", .onDeviceChat, .declaredCapable, []),
            ("What's on tomorrow on TV?", .onDeviceChat, .declaredCapable, []),
            ("Am I free tomorrow afternoon?", .onDeviceChat, .declaredCapable, []),
            ("Anything due before the review?", .onDeviceChat, .declaredCapable, []),
            ("And tomorrow?", .onDeviceChat, .declaredCapable, []),
            ("What else is on tomorrow?", .onDeviceChat, .declaredCapable, []),
            ("What is 17 plus 8?", .onDeviceChat, .declaredCapable, []),
            ("What's on tomorrow?", .onDeviceChat, .declaredCapable, [Data([1])]),
            ("What's on tomorrow?", .network(host: "127.0.0.1", port: 1), .declaredCapable, []),
            ("What's on tomorrow?", .scheduledTask(id: UUID()), .declaredCapable, []),
            ("What's on tomorrow?", .onDeviceChat, .declaredIncapable, []),
            ("What's on tomorrow?", .onDeviceChat, .tooSmall(billions: 0.6), [])
        ]
        for (question, origin, gate, images) in inputs {
            let result = try await run(question, origin: origin, gate: gate, images: images) { _, _ in Issue.record("Unexpected read"); return [:] }
            #expect(!result.handled && result.events.isEmpty)
        }
        let off = try await run("What's on tomorrow?", admitted: { _ in false }) { _, _ in Issue.record("Read while withheld"); return [:] }
        #expect(off.handled && off.events.count == 2)
        #expect(!off.events.contains(.toolCallStarted(name: "calendar")) && !off.events.contains(.token(CalendarRange.tomorrow.emptyText)))
    }

    @Test("Switching a source off during its lookup withholds the returned card and facts")
    func sourceDisconnected() async throws {
        actor Switch {
            var on = true
            func turnOff() { on = false }
        }
        let permission = Switch()
        let result = try await run("What's due today?", admitted: { _ in await permission.on }) { _, _ in
            await permission.turnOff()
            return ["reminders": [["title": "Private fixture"]]]
        }
        #expect(result.handled && result.events.first == .toolCallStarted(name: "reminders"))
        #expect(!result.events.contains { if case .answerCard = $0 { true } else { false } })
        #expect(result.events.contains(.token("Pocketd can't check your reminders in this chat right now.")))
    }

    @Test("Stop returns while the OS still holds the lookup, without publishing its result")
    func cancelDuringRead() async throws {
        let (waiting, signal) = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        let task = Task {
            defer { signal.finish() } // a missing read must fail the fixture instead of hanging it
            return try await run("What's on tomorrow?", observe: { event in
                #expect(event == .toolCallStarted(name: "calendar"))
            }) { _, _ in
                await withCheckedContinuation { signal.yield($0) }
                return ["text": "A late result"]
            }
        }
        var iterator = waiting.makeAsyncIterator()
        let release = try #require(await iterator.next())
        defer { release.resume() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
