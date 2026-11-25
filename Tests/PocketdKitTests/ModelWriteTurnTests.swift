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
    }

    @Test("One explicit request cannot file twice, even in a parallel tool round")
    func singleUse() async throws {
        let req = submission("Remind me to buy milk at 6pm"), store = Store()
        let j = #"{"name":"reminders","arguments":{"action":"create","title":"buy milk","when":"6pm"}}"#
        async let a = dispatch(j,req,store); async let b = dispatch(j,req,store)
        let results = try await [a,b]; #expect(results.filter(ModelWriteTurn.didWrite).count == 1); #expect(await store.reads == 1); #expect(await store.reminders.count == 1)
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
}
