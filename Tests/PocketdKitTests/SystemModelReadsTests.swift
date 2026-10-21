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
