import Foundation
import Testing
@testable import PocketdKit

/// The decisions the built-in brain's engine makes before and around Apple's
/// model: what survives the 4,096-token window, which tools a question carries,
/// which tool calls may run, what the model reads back, and what a failure says.
@Suite("Built-in brain plan")
struct SystemModelPlanTests {

    private func request(
        _ messages: [ChatMessage],
        maxTokens: Int? = nil,
        origin: RequestOrigin = .onDeviceChat
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: ModelRecord.builtInID,
            messages: messages,
            options: GenerationOptions(maxTokens: maxTokens),
            origin: origin
        )
    }

    private let everything: Set<CapabilityGroup> = [.calendar, .reminders, .health]

    // MARK: Shape

    @Test("system messages become the instructions, the last user turn the prompt")
    func shape() throws {
        let plan = try SystemModelPlan.make(
            for: request([
                .system("Current date and time: Tuesday."),
                .user("Hi"),
                .assistant("Hello!"),
                .user("Thanks /no_think")
            ]),
            enabled: []
        )
        #expect(plan.instructions == "Current date and time: Tuesday.")
        #expect(plan.prompt == "Thanks")
        #expect(plan.history == [.init(.user, "Hi"), .init(.assistant, "Hello!")])
        #expect(plan.tools.isEmpty)
        #expect(plan.droppedTurns == 0)
    }

    @Test("the tool preamble is added only when a tool is armed")
    func preambleOnlyWithTools() throws {
        let armed = try SystemModelPlan.make(for: request([.user("What's on today?")]), enabled: everything)
        #expect(armed.instructions.hasPrefix(SystemModelPlan.toolPreamble))
        let bare = try SystemModelPlan.make(for: request([.user("What's on today?")]), enabled: [])
        #expect(!bare.instructions.contains("Pocketd"))
    }

    @Test("the health rule rides along only with the health tool")
    func healthRule() throws {
        let sleep = try SystemModelPlan.make(for: request([.user("How did I sleep?")]), enabled: everything)
        #expect(sleep.instructions.contains(SystemModelPlan.healthRule))
        let calendar = try SystemModelPlan.make(for: request([.user("What's on my calendar?")]), enabled: everything)
        #expect(calendar.instructions.hasPrefix(SystemModelPlan.toolPreamble))
        #expect(!calendar.instructions.contains(SystemModelPlan.healthRule))
    }

    @Test("the instructions stay short and carry a version")
    func instructionsAreShortAndVersioned() {
        #expect(SystemModelPlan.instructionsVersion >= 1)
        let longest = SystemModelPlan.preamble(for: SystemModelPlan.toolOrder) ?? ""
        // About 240 tokens by ContextGuard's count: under a tenth of the window.
        #expect(ContextGuard.estimateTokens(longest) < 260)
        #expect(SystemModelPlan.preamble(for: []) == nil)
    }

    @Test("Qwen's reasoning switch never reaches Apple's model")
    func reasoningSwitchStripped() {
        #expect(SystemModelPlan.withoutReasoningSwitch("What's on?\n/no_think") == "What's on?")
        #expect(SystemModelPlan.withoutReasoningSwitch("Think harder /think") == "Think harder")
        #expect(SystemModelPlan.withoutReasoningSwitch("/no_think is a phrase I like") == "/no_think is a phrase I like")
    }

    @Test("empty assistant turns, tool payloads and extra system turns stay out of the history")
    func historyFilters() throws {
        let plan = try SystemModelPlan.make(
            for: request([
                .system("A"),
                .user("Q1"),
                .assistant(""),
                ChatMessage(role: .tool, content: "{\"events\":[]}"),
                .system("B"),
                .user("Q2")
            ]),
            enabled: []
        )
        #expect(plan.history == [.init(.user, "Q1")])
        #expect(plan.instructions == "A\n\nB")
    }

    @Test("a request with no question is refused with a sentence, not a crash")
    func noQuestion() {
        #expect(throws: InferenceError.backend(SystemModelFailure.nothingToAnswer.sentence)) {
            try SystemModelPlan.make(for: request([.system("A")]), enabled: [])
        }
    }

    // MARK: The window

    @Test("history is trimmed oldest first and never opens on an answer")
    func trimming() throws {
        var messages: [ChatMessage] = []
        for index in 0..<40 {
            messages.append(.user("Question \(index) " + String(repeating: "word ", count: 40)))
            messages.append(.assistant("Answer \(index) " + String(repeating: "word ", count: 40)))
        }
        messages.append(.user("And now?"))
        let plan = try SystemModelPlan.make(for: request(messages), enabled: everything)

        #expect(plan.droppedTurns > 0)
        #expect(plan.history.first?.speaker == .user)
        #expect(plan.history.last?.text.hasPrefix("Answer 39") == true)
        #expect(plan.history.count + plan.droppedTurns == 80)

        let budget = SystemModelBudget.standard
        let used = ContextGuard.estimateTokens(plan.instructions)
            + ContextGuard.estimateTokens(plan.prompt)
            + plan.history.reduce(0) { $0 + ContextGuard.estimateTokens($1.text) + 4 }
            + budget.schemaTokens(for: plan.tools) + budget.toolOutputTokens
            + plan.responseTokens + budget.marginTokens
        #expect(used <= budget.contextTokens)
        let history = plan.history.reduce(0) { $0 + ContextGuard.estimateTokens($1.text) + 4 }
        #expect(history <= budget.historyTokens)
    }

    @Test("a short conversation keeps every turn")
    func shortConversationKeepsEverything() throws {
        let plan = try SystemModelPlan.make(
            for: request([.user("Hi"), .assistant("Hello!"), .user("What's on today?"), .assistant("Standup at 9:30."), .user("And tomorrow?")]),
            enabled: everything
        )
        #expect(plan.history.count == 4)
        #expect(plan.droppedTurns == 0)
    }

    @Test("a question too big for the window on its own is contextExhausted")
    func oversizedQuestion() {
        let huge = String(repeating: "lorem ipsum ", count: 2_000)
        #expect(throws: InferenceError.contextExhausted) {
            try SystemModelPlan.make(for: request([.user(huge)]), enabled: [])
        }
    }

    @Test("the answer's cap follows the caller's, within the engine's ceiling")
    func responseCap() throws {
        let brief = try SystemModelPlan.make(for: request([.user("Hi")], maxTokens: 160), enabled: [])
        #expect(brief.responseTokens == 160)
        let chat = try SystemModelPlan.make(for: request([.user("Hi")], maxTokens: 4096), enabled: [])
        #expect(chat.responseTokens == SystemModelBudget.standard.responseTokens)
        let tiny = try SystemModelPlan.make(for: request([.user("Hi")], maxTokens: 1), enabled: [])
        #expect(tiny.responseTokens == 64)
    }

    @Test("dropping by an overshoot frees at least that much, in whole exchanges")
    func droppingByOvershoot() {
        let plan = SystemModelPlan(
            instructions: "",
            history: [
                .init(.user, String(repeating: "a", count: 40)), .init(.assistant, String(repeating: "b", count: 40)),
                .init(.user, String(repeating: "c", count: 40)), .init(.assistant, String(repeating: "d", count: 40))
            ],
            prompt: "q", tools: [], responseTokens: 64, droppedTurns: 0
        )
        let estimate: (String) -> Int = { $0.count / 4 }
        // 14 tokens per turn with markers: freeing 20 takes the whole first exchange.
        let trimmed = plan.droppingExchanges(toFree: 20, estimate: estimate)
        #expect(trimmed?.history.count == 2)
        #expect(trimmed?.history.first?.speaker == .user)
        #expect(trimmed?.droppedTurns == 2)
        #expect(plan.droppingExchanges(toFree: 1_000, estimate: estimate) == nil)
    }

    @Test("dropping and halving history keep it starting on a question")
    func shrinking() {
        let plan = SystemModelPlan(
            instructions: "",
            history: [.init(.user, "1"), .init(.assistant, "a"), .init(.user, "2"), .init(.assistant, "b")],
            prompt: "3", tools: [], responseTokens: 100, droppedTurns: 0
        )
        let dropped = plan.droppingOldestExchange()
        #expect(dropped?.history == [.init(.user, "2"), .init(.assistant, "b")])
        #expect(dropped?.droppedTurns == 2)
        let halved = plan.halvingHistory()
        #expect(halved?.history == [.init(.user, "2"), .init(.assistant, "b")])
        #expect(SystemModelPlan(instructions: "", history: [], prompt: "x", tools: [], responseTokens: 64, droppedTurns: 0).halvingHistory() == nil)
    }

    // MARK: Which tools

    @Test("a network caller is handed no tools at all")
    func networkGetsNothing() {
        let tools = SystemModelPlan.armedTools(
            for: request([.user("What's on my calendar today?")], origin: .network(host: "10.0.0.2", port: 1)),
            enabled: everything
        )
        #expect(tools.isEmpty)
    }

    @Test("only switched-on tools, narrowed to what the question is about")
    func arming() {
        #expect(SystemModelPlan.armedTools(for: request([.user("Remind me to call mum at 9")]), enabled: everything) == [.reminders])
        #expect(SystemModelPlan.armedTools(for: request([.user("How did I sleep?")]), enabled: everything) == [.health])
        // The calendar is off: nothing else is handed over in its place.
        #expect(SystemModelPlan.armedTools(for: request([.user("What's on my calendar?")]), enabled: [.reminders]).isEmpty)
        #expect(SystemModelPlan.armedTools(for: request([.user("What's on today?")]), enabled: everything) == [.calendar, .reminders, .health])
    }

    @Test("a question that is not about the day gets no tools at all")
    func unrelatedArmsNothing() {
        // Armed with the calendar, Apple's model answered both of these by
        // reading it — measured on the Mac.
        #expect(SystemModelPlan.armedTools(for: request([.user("Write a 600-word story about a lighthouse keeper.")]), enabled: everything).isEmpty)
        #expect(SystemModelPlan.armedTools(for: request([.user("What is the capital of France?")]), enabled: everything).isEmpty)
        #expect(SystemModelPlan.armedTools(for: request([.user("Thanks!")]), enabled: everything).isEmpty)
    }

    @Test("adding something, or naming a day, still gets the diary")
    func changesAndDays() {
        // Neither names anything the router knows.
        // With both armed, "add lunch…" came back "added" and no card (B2).
        #expect(SystemModelPlan.armedTools(for: request([.user("Add lunch with Sam on Friday at 1")]), enabled: everything) == [.calendar])
        #expect(SystemModelPlan.armedTools(for: request([.user("Please put the dentist in for Tuesday at 3pm")]), enabled: everything) == [.calendar])
        #expect(SystemModelPlan.armedTools(for: request([.user("Add milk to my shopping list")]), enabled: everything) == [.reminders])
        #expect(SystemModelPlan.armedTools(for: request([.user("What about Friday?")]), enabled: everything) == [.calendar, .reminders, .health])
        // A verb that can only mean one of them arms that one: with both armed,
        // "tick off" was answered by listing the reminders instead.
        #expect(SystemModelPlan.armedTools(for: request([.user("Tick off call mom")]), enabled: everything) == [.reminders])
        #expect(SystemModelPlan.armedTools(for: request([.user("Book a table at Luca for Friday at 8")]), enabled: everything) == [.calendar])
        #expect(SystemModelPlan.armedTools(for: request([.user("Anything on the 3rd of November?")]), enabled: [.calendar]) == [.calendar])
    }

    @Test("asking to add something reaches the tools that add, even when a health word named health")
    func changesReachTheWriters() {
        // "workout" names health, which only reads. Armed with health alone —
        // or, with Health off, with nothing — Apple's model answered "I can't
        // make changes to your schedule" (simulator).
        let workout = request([.user("Add a 90 minute workout at 6pm")])
        // The writer its verb names: "add" is the diary.
        #expect(SystemModelPlan.armedTools(for: workout, enabled: [.calendar, .reminders]) == [.calendar])
        #expect(SystemModelPlan.armedTools(for: workout, enabled: everything) == [.calendar, .health])
        // A change that names what makes it keeps exactly that, which is what
        // stops a reminder being filed as an event as well.
        #expect(SystemModelPlan.armedTools(for: request([.user("Remind me to call mum at 9")]), enabled: everything) == [.reminders])
        #expect(SystemModelPlan.armedTools(for: request([.user("Add a workout to my calendar at 6pm")]), enabled: everything) == [.calendar, .health])
    }

    @Test("a question about health still arms health alone")
    func healthQuestionsStayHealth() {
        for question in ["How was my workout yesterday?", "How did I sleep?", "Did I exercise enough this week?"] {
            #expect(SystemModelPlan.armedTools(for: request([.user(question)]), enabled: everything) == [.health], "\(question)")
        }
    }

    @Test("a scheduled routine may read the day")
    func scheduledReads() {
        let routine = request([.user("What's on today?")], origin: .scheduledTask(id: UUID()))
        #expect(!SystemModelPlan.armedTools(for: routine, enabled: everything).isEmpty)
    }

    // MARK: Tool rounds

    @Test("a change runs only in the first round")
    func writesFirstRoundOnly() {
        #expect(SystemToolPolicy.decide(change: .addReminder, round: 1, callNumber: 1, readsReturned: false, stopped: false) == .run)
        // In the same round as a lookup that has already finished: the model
        // asked for both before it read anything.
        #expect(SystemToolPolicy.decide(change: .addEvent, round: 1, callNumber: 2, readsReturned: true, stopped: false) == .run)
        for change in SystemToolPolicy.Change.allCases {
            #expect(SystemToolPolicy.decide(change: change, round: 2, callNumber: 2, readsReturned: false, stopped: false)
                == .refuse(SystemToolPolicy.lateChangeRefusal(change)))
        }
    }

    @Test("without a transcript, a change after any finished lookup is refused")
    func writesWithoutRound() {
        #expect(SystemToolPolicy.decide(change: .tickOff, round: nil, callNumber: 1, readsReturned: false, stopped: false) == .run)
        #expect(SystemToolPolicy.decide(change: .tickOff, round: nil, callNumber: 2, readsReturned: true, stopped: false)
            == .refuse(SystemToolPolicy.lateChangeRefusal(.tickOff)))
    }

    @Test("a refused change hands the model the exact sentence to say")
    func lateChangeWording() {
        // Anything vaguer was answered with "I've added a reminder" on the Mac.
        #expect(SystemToolPolicy.lateChangeRefusal(.addReminder).contains("\"I didn't add that reminder. Ask me for it on its own and I'll add it.\""))
        #expect(SystemToolPolicy.lateChangeRefusal(.addEvent).contains("I didn't add that event."))
        #expect(SystemToolPolicy.lateChangeRefusal(.tickOff).contains("I didn't tick that off."))
    }

    @Test("lookups get a second round, not a third, and the total is capped")
    func readRounds() {
        #expect(SystemToolPolicy.decide(change: nil, round: 2, callNumber: 2, readsReturned: true, stopped: false) == .run)
        #expect(SystemToolPolicy.decide(change: nil, round: 3, callNumber: 3, readsReturned: true, stopped: false) == .refuse(SystemToolPolicy.enoughRefusal))
        #expect(SystemToolPolicy.decide(change: nil, round: 1, callNumber: SystemToolPolicy.maximumCalls + 1, readsReturned: false, stopped: false) == .refuse(SystemToolPolicy.enoughRefusal))
    }

    @Test("nothing runs after Stop")
    func stopped() {
        #expect(SystemToolPolicy.decide(change: .addReminder, round: 1, callNumber: 1, readsReturned: false, stopped: true) == .refuse(SystemToolPolicy.stoppedRefusal))
        #expect(SystemToolPolicy.decide(change: nil, round: 1, callNumber: 1, readsReturned: false, stopped: true) == .refuse(SystemToolPolicy.stoppedRefusal))
    }

    // MARK: What the model reads back

    @Test("events become one line each, with the span and the place")
    func eventLines() {
        let data: [String: any Sendable] = ["events": [
            ["title": "Standup", "start": "Tue 21 Oct, 09:30", "end": "Tue 21 Oct, 09:45", "all_day": false],
            ["title": "Lunch at The Arches", "start": "Tue 21 Oct, 13:00", "end": "Tue 21 Oct, 14:00",
             "location": "The Arches", "all_day": false],
            ["title": "Holiday", "start": "Tue 21 Oct", "end": "Tue 21 Oct", "all_day": true]
        ] as [[String: any Sendable]]]
        let text = SystemToolOutput.render(data)
        #expect(text == """
        3 events:
        - Standup · Tue 21 Oct, 09:30 – 09:45
        - Lunch at The Arches · Tue 21 Oct, 13:00 – 14:00 · The Arches
        - Holiday · Tue 21 Oct (all day)
        """)
        #expect(text.count < ToolResult.encode(data).count)
    }

    @Test("reminders carry due dates, priorities and the scale")
    func reminderLines() {
        let data: [String: any Sendable] = [
            "reminders": [
                ["title": "Submit expenses", "due": "Mon 20 Oct, 18:00", "priority": 1],
                ["title": "Buy oat milk", "due": "no due date"]
            ] as [[String: any Sendable]],
            "priority_scale": "1 is highest, 9 is lowest"
        ]
        #expect(SystemToolOutput.render(data) == """
        2 reminders:
        - Submit expenses · due Mon 20 Oct, 18:00 · priority 1
        - Buy oat milk · no due date
        Priority: 1 is highest, 9 is lowest.
        """)
    }

    @Test("a sentence payload is the sentence")
    func sentences() {
        #expect(SystemToolOutput.render(["text": "No events today."]) == "No events today.")
        #expect(SystemToolOutput.render(["text": "Reminder set: \"Call mum\" for 9:00 AM.", "created": true]) == "Reminder set: \"Call mum\" for 9:00 AM.")
    }

    @Test("health readings, notes and gaps all reach the model")
    func health() {
        let text = SystemToolOutput.render([
            "readings": ["Steps: 4,120 on Tue 21 Oct — 1,980 under your usual"],
            "notable": ["Longest walk this month"],
            "no_data": "heart rate",
            "note": "iOS does not say whether that is a refusal or no data."
        ])
        #expect(text.contains("- Steps: 4,120"))
        #expect(text.contains("Worth noting: Longest walk this month"))
        #expect(text.contains("Nothing came back for heart rate."))
        #expect(text.hasSuffix("iOS does not say whether that is a refusal or no data."))
    }

    @Test("a long list is cut at whole rows and says how many were left out")
    func capped() {
        let rows = (0..<200).map { index -> [String: any Sendable] in
            ["title": "Event number \(index) with a fairly long title", "start": "Tue 21 Oct, 09:30",
             "end": "Tue 21 Oct, 10:30", "all_day": false]
        }
        let text = SystemToolOutput.render(["events": rows])
        #expect(text.count <= SystemToolOutput.characterLimit + 40)
        #expect(text.contains("more not shown."))
        #expect(text.hasPrefix("200 events:"))
    }

    @Test("an unknown payload shape falls back to the JSON every other engine reads")
    func unknownShape() {
        let data: [String: any Sendable] = ["status": "pocketd_selftest_ok", "asked_by": "on-device"]
        #expect(SystemToolOutput.render(data) == ToolResult.encode(data))
    }

    // MARK: Failures

    @Test("context overflow is contextExhausted; everything else is one plain sentence")
    func failures() {
        #expect(SystemModelFailure.contextExceeded.error == .contextExhausted)
        #expect(SystemModelFailure.guardrail.error == .backend("Pocketd can't help with that one."))
        for failure in SystemModelFailure.allCases where failure != .contextExceeded {
            guard case let .backend(sentence) = failure.error else {
                Issue.record("\(failure) is not a sentence")
                continue
            }
            #expect(sentence.hasSuffix("."))
            #expect(sentence.split(separator: " ").count <= 25)
            for word in ["error", "token", "context", "model", "session", "guardrail", "gpt", "openai"] {
                #expect(!sentence.lowercased().contains(word), "\(failure): \(sentence)")
            }
        }
    }

    @Test("an unavailable built-in brain says why, or says nothing it cannot fix")
    func unavailable() {
        #expect(SystemModelFailure.unavailable(.turnedOff) == .backend("Turn on Apple Intelligence in Settings to ask Pocketd."))
        #expect(SystemModelFailure.unavailable(.gettingReady) == .backend("Pocketd is getting ready. Try again in a few minutes."))
        #expect(SystemModelFailure.unavailable(.unsupportedLanguage) == .backend("Pocketd can't answer in this language yet."))
        #expect(SystemModelFailure.unavailable(.notEligible) == .noModelLoaded)
    }

    @Test("a screen shows the built-in brain's own sentences, and no other engine's detail")
    func screenSentences() {
        #expect(SystemModelFailure.screenSentence(for: SystemModelFailure.turnedOff.error) == "Turn on Apple Intelligence in Settings to ask Pocketd.")
        #expect(SystemModelFailure.screenSentence(for: SystemModelFailure.guardrail.error) == "Pocketd can't help with that one.")
        // LlamaEngine's details are for the diagnostics log.
        #expect(SystemModelFailure.screenSentence(for: InferenceError.backend("qwen3 needs its projector file")) == nil)
        #expect(SystemModelFailure.screenSentence(for: InferenceError.contextExhausted) == nil)
        #expect(SystemModelFailure.screenSentence(for: CancellationError()) == nil)
    }

    @Test("only Apple's model declining sends the question to the downloaded brain")
    func fallbackCases() {
        #expect(SystemModelFailure.allCases.filter(\.asksTheDownloadedBrain) == [.guardrail, .refusal])
    }
}
