import Foundation
import Testing
@testable import PocketdKit

@Suite("Model writes are bound to one submitted Ask command")
struct ModelWriteTurnTests {
    private actor Store {
        var reads = 0
        var events: [NewEvent] = []
        var reminders: [NewReminder] = []
        var completed: [String] = []
        func list() -> PersonalDataLookup<ReminderRow> {
            reads += 1
            return .rows([ReminderRow(title: "Return cobalt key", identifier: "synthetic-key")], truncated: false)
        }
        func save(_ event: NewEvent) -> WriteResult { events.append(event); return .written }
        func save(_ reminder: NewReminder) -> WriteResult { reminders.append(reminder); return .written }
        func complete(_ row: ReminderRow) -> WriteResult { completed.append(row.identifier ?? "missing"); return .written }
        var untouched: Bool { reads == 0 && events.isEmpty && reminders.isEmpty && completed.isEmpty }
    }

    private struct Call: Decodable {
        var name: String
        struct Args: Decodable { var action: String; var title: String?; var when: String?; var start: String?; var duration_minutes: Int? }
        var arguments: Args
    }
    private func submission(_ text: String, origin: RequestOrigin = .onDeviceChat) -> GenerationRequest {
        GenerationRequest(modelID: "test", messages: [.user(text)], origin: origin, submittedQuestion: text)
    }

    /// Dispatch the actual multi-action tool arguments to the same model-only
    /// adapter as @Tool and FoundationModels. Storage and input alone are fake.
    private func dispatch(_ json: String, _ request: GenerationRequest, _ store: Store) async throws -> ModelWriteTurn.Payload {
        let call = try JSONDecoder().decode(Call.self, from: Data(json.utf8)); let a = call.arguments
        return await ModelWriteTurn.$current.withValue(request.modelWriteTurn) {
            switch (call.name, a.action) {
            case ("calendar", "create"):
                await ModelPersonalDataWrites.createEvent(title: a.title, start: a.start, durationMinutes: a.duration_minutes, origin: request.origin, write: { await store.save($0) })
            case ("reminders", "create"):
                await ModelPersonalDataWrites.createReminder(title: a.title, when: a.when, origin: request.origin, existing: { await store.list() }, write: { await store.save($0) })
            case ("reminders", "complete"):
                await ModelPersonalDataWrites.completeReminder(title: a.title, when: a.when, origin: request.origin, existing: { await store.list() }, complete: { await store.complete($0) })
            default: ["text": "not a write"]
            }
        }
    }

    @Test("Captured first-pass calls and routine model mistakes never even open EventKit", arguments: [
        ("I really should call Jun after lunch.", #"{"name":"reminders","arguments":{"action":"create","title":"Jun","when":"lunchtime","filter":"today"}}"#),
        ("If I added a reminder called 'Pick up tiles' without a due date, would it still appear in my open reminders?", #"{"name":"reminders","arguments":{"filter":"all_open","action":"create","title":"Pick up tiles"}}"#),
        ("Which reminder is due tomorrow, and at what time?", #"{"name":"reminders","arguments":{"filter":"tomorrow","action":"create","when":"tomorrow at 9"}}"#),
        ("A box holds 6 pencils. How many pencils are in 7 full boxes?", #"{"name":"calendar","arguments":{"action":"create","title":"7 Full Boxes of Pencils","start":"9am"}}"#),
        ("Can you tell me how to add a reminder to return the key?", #"{"name":"reminders","arguments":{"action":"create","title":"Return the key"}}"#),
        ("Please do not schedule lunch at 3pm.", #"{"name":"calendar","arguments":{"action":"create","title":"lunch","start":"3pm"}}"#),
        ("Add lunch at 3pm only if I tell you to.", #"{"name":"calendar","arguments":{"action":"create","title":"lunch","start":"3pm"}}"#),
        ("Add lunch at 3pm, not tomorrow.", #"{"name":"calendar","arguments":{"action":"create","title":"lunch","start":"tomorrow at 3pm"}}"#),
        ("Please explain how to mark Return cobalt key done.", #"{"name":"reminders","arguments":{"action":"complete","title":"Return cobalt key"}}"#),
        ("Create a reminder app in Python.", #"{"name":"reminders","arguments":{"action":"create","title":"app in Python"}}"#),
        ("Create a reminder for example, not a real one.", #"{"name":"reminders","arguments":{"action":"create","title":"example"}}"#),
        ("¿Debería llamar a Jun después de comer?", #"{"name":"reminders","arguments":{"action":"create","title":"llamar a Jun"}}"#),
        ("Remind me to return cobalt key.", #"{"name":"reminders","arguments":{"action":"complete","title":"Return cobalt key"}}"#),
        ("Tick off Return cobalt key.", #"{"name":"reminders","arguments":{"action":"create","title":"Return cobalt key"}}"#),
        ("Remind me to call Jun at 2pm.", #"{"name":"calendar","arguments":{"action":"create","title":"call Jun","start":"2pm"}}"#),
        ("Schedule lunch at 3pm.", #"{"name":"reminders","arguments":{"action":"create","title":"lunch","when":"3pm"}}"#),
        ("Remind me to pick up tiles.", #"{"name":"reminders","arguments":{"action":"create","title":"pick up tiles","when":"in 20 minutes"}}"#),
        ("Remind me to buy milk tomorrow at 9pm.", #"{"name":"reminders","arguments":{"action":"create","title":"buy milk","when":"9pm"}}"#),
        ("Remind me to buy milk tomorrow.", #"{"name":"reminders","arguments":{"action":"create","title":"buy milk tomorrow"}}"#),
        ("Remind me not to call Jun.", #"{"name":"reminders","arguments":{"action":"create","title":"call Jun"}}"#),
        ("Please mark Return cobalt key as done.", #"{"name":"reminders","arguments":{"action":"complete","title":"Return blue key"}}"#),
        ("Add lunch at 3pm for 30 minutes.", #"{"name":"calendar","arguments":{"action":"create","title":"lunch","start":"3pm","duration_minutes":480}}"#)
    ])
    func refusesBeforeReadOrWrite(_ text: String, _ call: String) async throws {
        let store = Store(); let request = submission(text)
        let payload = try await dispatch(call, request, store)
        #expect(!ModelWriteTurn.didWrite(payload)); #expect(await store.untouched)
        #expect(request.modelWriteTurn?.receipt == payload["text"] as? String)
    }

    @Test("Recall is chat, even when a model proposes the entire question as a reminder title", arguments: [
        ("Remind me who wrote Hamlet?", "who wrote Hamlet"),
        ("Could you remind me where Hamlet was written?", "where Hamlet was written"),
        ("Remind me which play features Ophelia?", "which play features Ophelia"),
        ("Remind me when Hamlet was written?", "when Hamlet was written"),
        ("Please remind me again who wrote it.", "again who wrote it"),
        ("Remind me of the author’s name.", "of the author’s name"),
        ("Remind me about Hamlet.", "Hamlet"),
        ("Remind me to whom Hamlet is speaking.", "whom Hamlet is speaking")
    ])
    func recall(_ text: String, _ title: String) async throws {
        let request = submission(text), turn = try #require(request.modelWriteTurn), store = Store()
        #expect(!SystemModelWrites.isChange(request))
        #expect(SystemModelPlan.armedTools(for: request, enabled: [.calendar, .reminders, .health]).isEmpty)
        #expect(SystemModelReads.plan(for: request, enabled: [.calendar, .reminders, .health]) == nil)
        #expect(try await visible(["William Shakespeare wrote Hamlet."], turn: turn) == "William Shakespeare wrote Hamlet.")
        // Use a fresh generation: terminating the narration also revokes its turn.
        let attempted = submission(text)
        let result = await ModelWriteTurn.$current.withValue(attempted.modelWriteTurn) {
            await ModelPersonalDataWrites.createReminder(title: title, when: nil, origin: .onDeviceChat,
                existing: { await store.list() }, write: { await store.save($0) })
        }
        #expect(!ModelWriteTurn.didWrite(result)); #expect(await store.untouched)
        let declined = try #require(attempted.modelWriteTurn)
        #expect(declined.receipt == result["text"] as? String); #expect(declined.narrationReceipt == nil)
        let card = try #require(AnswerCardCatalogue.standard.card(for: "reminders", arguments: #"{"action":"create"}"#, data: result))
        let continued = AsyncThrowingStream<GenerationEvent, any Error> { output in
            output.yield(.answerCard(card)); output.yield(.token("William Shakespeare wrote Hamlet."))
            output.yield(.finished(reason: .stop, usage: .init())); output.finish()
        }
        var words = ""
        for try await event in declined.reporting(continued) {
            if case .token(let chunk) = event { words += chunk }
            if case .answerCard = event { Issue.record("Write refusal rendered in place of the recall answer") }
        }
        #expect(words == "William Shakespeare wrote Hamlet.")
    }

    @Test("Explicit, polite calendar/create, reminder/create, and reminder/complete reach storage")
    func realPositiveControls() async throws {
        let store = Store()
        let a = try await dispatch(#"{"name":"calendar","arguments":{"action":"create","range":"today","title":"lunch with Sam","start":"3pm","duration_minutes":480}}"#, submission("Could you please add lunch with Sam to my calendar at 3 PM?"), store)
        let b = try await dispatch(#"{"name":"reminders","arguments":{"action":"create","filter":"all_open","title":"買牛奶"}}"#, submission("Please remind me to 買牛奶."), store)
        let c = try await dispatch(#"{"name":"reminders","arguments":{"action":"complete","filter":"all_open","title":"Return cobalt key"}}"#, submission("Please mark the reminder ‘Return cobalt key’ as done."), store)
        #expect([a,b,c].allSatisfy(ModelWriteTurn.didWrite)); #expect(await store.completed == ["synthetic-key"])
        #expect(await store.reminders.first?.title == "買牛奶"); #expect(await store.reminders.first?.due == nil)
        let event = try #require(await store.events.first); #expect(event.end.timeIntervalSince(event.start) == 3600)
        let d = try await dispatch(#"{"name":"calendar","arguments":{"action":"create","title":"workout","start":"6pm","duration_minutes":90}}"#, submission("Add a 90-minute workout at 6pm"), store)
        #expect(ModelWriteTurn.didWrite(d)); let workout = try #require(await store.events.last); #expect(workout.end.timeIntervalSince(workout.start) == 90 * 60)
        let e = try await dispatch(#"{"name":"reminders","arguments":{"action":"create","title":"Buy milk","when":"6pm"}}"#, submission("Would you please set a reminder for 6 PM to buy milk?"), store)
        #expect(ModelWriteTurn.didWrite(e)); #expect(await store.reminders.last?.due != nil)
        let f = try await dispatch(#"{"name":"reminders","arguments":{"action":"create","title":"not to call Jun"}}"#, submission("Remind me not to call Jun."), store)
        #expect(ModelWriteTurn.didWrite(f))
        let g = try await dispatch(#"{"name":"reminders","arguments":{"action":"create","title":"buy milk","when":"tomorrow at 9"}}"#, submission("Remind me tomorrow at 9 to buy milk"), store)
        #expect(ModelWriteTurn.didWrite(g)); #expect(await store.reminders.last?.due != nil)
        let h = try await dispatch(#"{"name":"reminders","arguments":{"action":"create","title":"water the plants"}}"#, submission("Please remind me again to water the plants."), store)
        #expect(ModelWriteTurn.didWrite(h))
    }

    @Test("No earlier chat, generated fact, schedule, or network caller is a submission")
    func provenance() async throws {
        let t = "Remind me to buy milk"; let j = #"{"name":"reminders","arguments":{"action":"create","title":"buy milk"}}"#
        let store = Store()
        for req in [GenerationRequest(modelID: "", messages: [.user(t)], origin: .onDeviceChat),
                    GenerationRequest(modelID: "", messages: [.user(t),.assistant("OK")], origin: .onDeviceChat, submittedQuestion:t),
                    GenerationRequest(modelID: "", messages: [.user(t),.init(role:.tool,content:t)], origin: .onDeviceChat, submittedQuestion:t),
                    GenerationRequest(modelID: "", messages: [.user(t),.assistant("OK"),.user("What's due?")], origin:.onDeviceChat, submittedQuestion:"What's due?"),
                    submission(t,origin:.scheduledTask(id:UUID())), submission(t,origin:.network(host:"local",port:1))] {
            let data = try await dispatch(j, req.trackingPhoneWriteResults(), store)
            #expect(!ModelWriteTurn.didWrite(data)); #expect(await store.untouched)
        }
    }

    @Test("Polite submitted changes are not diverted into the ordinary read plan")
    func explicitRouting() {
        let enabled: Set<CapabilityGroup> = [.calendar, .reminders, .health]
        let event = submission("Could you please add a workout to my calendar at 6pm?")
        #expect(SystemModelReads.plan(for:event,enabled:enabled) == nil)
        #expect(SystemModelPlan.armedTools(for:event,enabled:enabled) == [.calendar])
        let reminder = submission("Please remind me to add lunch to my calendar at 3pm")
        #expect(SystemModelPlan.armedTools(for:reminder,enabled:enabled) == [.reminders])
        #expect(!SystemModelWrites.isChange(submission("Add the numbers 6 and 7")))
        let lookup = submission("Remind me when my next meeting starts?")
        #expect(!SystemModelWrites.isChange(lookup))
        #expect(SystemModelPlan.armedTools(for: lookup, enabled: enabled) == [.calendar])
        #expect(SystemModelReads.plan(for: lookup, enabled: enabled) == [.calendar(.today)])
    }

    @Test("One explicit request cannot file twice, even in a parallel tool round")
    func singleUse() async throws {
        let req = submission("Remind me to buy milk at 6pm"), store = Store()
        let j = #"{"name":"reminders","arguments":{"action":"create","title":"buy milk","when":"6pm"}}"#
        async let a = dispatch(j,req,store); async let b = dispatch(j,req,store)
        let results = try await [a,b]; #expect(results.filter(ModelWriteTurn.didWrite).count == 1); #expect(await store.reads == 1); #expect(await store.reminders.count == 1)
    }

    @Test("Stop during lookup prevents the save, including on an uncancelled framework task",
          arguments: [false, true], [false, true])
    func stopDuringLookup(complete: Bool, cancelTask: Bool) async throws {
        let request = submission(complete ? "Tick off Return cobalt key" : "Remind me to buy milk")
        let turn = try #require(request.modelWriteTurn), store = Store()
        let (waiting, signal) = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        let work = Task {
            defer { signal.finish() }
            let lookup: @Sendable () async -> PersonalDataLookup<ReminderRow> = {
                let rows = await store.list()
                await withCheckedContinuation { signal.yield($0) }
                return rows
            }
            return await ModelWriteTurn.$current.withValue(turn) {
                if complete {
                    return await ModelPersonalDataWrites.completeReminder(title: "Return cobalt key", when: nil, origin: .onDeviceChat,
                        existing: lookup, complete: { await store.complete($0) })
                }
                return await ModelPersonalDataWrites.createReminder(title: "buy milk", when: nil, origin: .onDeviceChat,
                    existing: lookup, write: { await store.save($0) })
            }
        }
        var iterator = waiting.makeAsyncIterator(); let release = try #require(await iterator.next())
        if cancelTask { work.cancel() } else { turn.revoke() }
        release.resume()
        let result = await work.value
        #expect(!ModelWriteTurn.didWrite(result)); #expect(result["text"] as? String == SystemToolPolicy.stoppedRefusal)
        #expect(await store.reads == 1); #expect(await store.completed.isEmpty); #expect(await store.reminders.isEmpty)
        #expect(!turn.preventsReplay)
    }

    @Test("A save queued on the store actor still checks the turn before mutating")
    func stopAtStoreHop() async throws {
        let turn = try #require(submission("Remind me to buy milk").modelWriteTurn), store = Store()
        let (waiting, signal) = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        let work = Task {
            defer { signal.finish() }
            return await ModelWriteTurn.$current.withValue(turn) {
                await ModelPersonalDataWrites.createReminder(title: "buy milk", when: nil, origin: .onDeviceChat, existing: { await store.list() }) { item in
                    await withCheckedContinuation { signal.yield($0) }
                    guard ModelWriteTurn.mayMutateStore else { return .failed }
                    return await store.save(item)
                }
            }
        }
        var iterator = waiting.makeAsyncIterator(); let release = try #require(await iterator.next())
        #expect(turn.preventsReplay); turn.revoke(); release.resume()
        #expect(!ModelWriteTurn.didWrite(await work.value)); #expect(await store.reminders.isEmpty); #expect(!turn.preventsReplay)
    }

    @Test("A narration error or Stop cannot erase a write which is already in storage", arguments: [false, true])
    func commitOutlivesNarration(backendError: Bool) async throws {
        let turn = try #require(submission("Add lunch to my calendar at 3pm").modelWriteTurn), store = Store()
        let (waiting, signal) = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        let work = Task {
            defer { signal.finish() }
            return await ModelWriteTurn.$current.withValue(turn) {
                await ModelPersonalDataWrites.createEvent(title: "lunch", start: "3pm", durationMinutes: nil, origin: .onDeviceChat) {
                    #expect(ModelWriteTurn.mayMutateStore)
                    let saved = await store.save($0)
                    await withCheckedContinuation { signal.yield($0) } // commit landed; return from EventKit is still outstanding
                    return saved
                }
            }
        }
        var iterator = waiting.makeAsyncIterator(); let release = try #require(await iterator.next())
        #expect(turn.preventsReplay); #expect(turn.receipt == nil)
        let source = AsyncThrowingStream<GenerationEvent, any Error> { stream in
            if backendError { stream.finish(throwing: InferenceError.backend("fixture")) }
            else { stream.yield(.finished(reason: .cancelled, usage: .init())); stream.finish() }
        }
        let reader = Task { () -> String in
            var words = ""
            do { for try await event in turn.reporting(source) { if case .token(let text) = event { words += text } } }
            catch { #expect(backendError) }
            return words
        }
        let settlement = Task { await turn.settledReceipt() }
        turn.revoke(); work.cancel(); release.resume()
        let saved = await work.value; let receipt = try #require(saved["text"] as? String)
        #expect(ModelWriteTurn.didWrite(saved)); #expect(turn.preventsReplay)
        #expect(await settlement.value == receipt); #expect(await reader.value == receipt); #expect(await store.events.count == 1)
    }

    @Test("A stopped write that settles offscreen updates only its original stored reply")
    func stoppedReceiptAfterSwitch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir), stamp = Date(timeIntervalSince1970: 1_800_000_000.75)
        let old = Conversation(messages: [.user("Add lunch to my calendar at 3pm"), .init(role: .assistant, content: ReplyMarker.stopped, sentAt: stamp)], draft: "Newer unsent words")
        let other = Conversation(messages: [.user("Another topic"), .assistant("Another answer")])
        try await store.save(old); try await store.save(other)
        let target = GenerationTarget(conversation: old.id, slot: 1), actual = "Added lunch at 3pm."
        try await store.updateStoppedReceipt(actual, at: target, sentAt: stamp.addingTimeInterval(2))
        #expect(await store.all().first { $0.id == old.id }?.messages[1].content == ReplyMarker.stopped)
        try await store.updateStoppedReceipt(actual, at: target, sentAt: stamp)
        let saved = await store.all()
        #expect(saved.first { $0.id == old.id }?.messages[1].content == ReplyMarker.markingStopped(actual))
        #expect(saved.first { $0.id == old.id }?.draft == old.draft)
        #expect(saved.first { $0.id == other.id }?.messages == other.messages)
        await store.delete(old.id)
        try await store.updateStoppedReceipt(actual, at: target, sentAt: stamp)
        #expect(await store.all().map(\.id) == [other.id])
    }

    private func visible(_ chunks: [String], turn: ModelWriteTurn) async throws -> String {
        let source = AsyncThrowingStream<GenerationEvent, any Error> { c in
            for chunk in chunks { c.yield(.token(chunk)) }; c.yield(.finished(reason:.stop,usage:.init())); c.finish()
        }; var result = ""; for try await event in turn.reporting(source) { if case .token(let t) = event { result += t } }; return result
    }

    @Test("Only real receipts confirm changes; ordinary language stays visible")
    func presentation() async throws {
        let req = submission("Remind me to call Jun at 6pm"); let turn = try #require(req.modelWriteTurn)
        let failed = await ModelWriteTurn.$current.withValue(turn) {
            await ModelPersonalDataWrites.createReminder(title:"call Jun",when:"6pm",origin:.onDeviceChat,existing:{.rows([],truncated:false)},write:{_ in .failed})
        }
        #expect(!ModelWriteTurn.didWrite(failed)); #expect(try await visible(["Done! I've set a reminder."],turn:turn) == failed["text"] as? String)
        let casual = try #require(submission("I really should call Jun after lunch.").modelWriteTurn)
        let native = #"<|tool_call_start|>[reminders(action="create", filter="today")]<|tool_call_end|>I’m creating a reminder for you to call Jun after lunch today."#
        #expect(try await visible(native.map(String.init),turn:casual) == ModelWriteReply.noChange)
        let phantomRead = #"<|tool_call_start|>[reminders(action="list", filter="all_open", title="Pick up tiles")]<|tool_call_end|>I am retrieving all reminders."#
        #expect(try await visible(phantomRead.map(String.init),turn:casual) == ModelWriteReply.noLookup)
        #expect(try await visible(["I’","ve created a reminder for you."],turn:casual) == ModelWriteReply.noChange)
        #expect(try await visible("Sure, I'll create a reminder for you.".map(String.init),turn:casual) == ModelWriteReply.noChange)
        #expect(try await visible("I’ve scheduled a meeting with Jun for tomorrow.".map(String.init),turn:casual) == ModelWriteReply.noChange)
        #expect(try await visible(["It is Tuesday. I've scheduled a meeting with Jun for tomorrow. The library is open."], turn: casual)
                == "It is Tuesday. \(ModelWriteReply.noChange) The library is open.")
        for plain in ["Set theory is a branch of mathematics.","I've added the flour to the example recipe.","The quote ‘I have created a reminder’ uses the past tense.","I think a reminder might help.","I'll remind you that two and two are four.","Your reminder is set for Friday.","I've created a reminder app in this tutorial.","Create a reminder by tapping the plus button."] {
            #expect(try await visible(plain.map(String.init),turn:casual) == plain)
        }
        #expect(try await visible(["What hour should I use?"],turn:try #require(submission("Remind me to call Jun").modelWriteTurn)) == "What hour should I use?")
        let duplicate = try #require(submission("Remind me to Return cobalt key").modelWriteTurn); let spy = Store()
        let already = await ModelWriteTurn.$current.withValue(duplicate) {
            await ModelPersonalDataWrites.createReminder(title:"Return cobalt key",when:nil,origin:.onDeviceChat,existing:{await spy.list()},write:{await spy.save($0)})
        }
        #expect(already["already_existed"] as? Bool == true); #expect(!ModelWriteTurn.didWrite(already)); #expect(await spy.reminders.isEmpty)
        #expect(try await visible(["I've created a new reminder."],turn:duplicate) == already["text"] as? String)
    }

    @Test("Ordinary first-person writing survives a broken stream, including a last sentence with no punctuation")
    func ordinaryTextBeforeError() async throws {
        for words in ["I put the kettle on. Then I opened the book.", "I put the kettle on", "I've scheduled a meeting agenda for publication.", "I've scheduled a meeting in the example."] {
            let turn = try #require(submission("Tell me a story.").modelWriteTurn)
            let source = AsyncThrowingStream<GenerationEvent, any Error> { stream in
                for c in words { stream.yield(.token(String(c))) }
                stream.finish(throwing: InferenceError.backend("fixture"))
            }
            var visible = ""
            do { for try await e in turn.reporting(source) { if case .token(let text) = e { visible += text } }; Issue.record("Lost the transport error") }
            catch { #expect(error as? InferenceError == .backend("fixture")) }
            #expect(visible == words)
        }
    }
}
