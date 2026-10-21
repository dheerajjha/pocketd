import Foundation
import Testing
@testable import PocketdKit

/// A change on the built-in brain never claims what no tool did (B2's
/// write-side S1-1: "added" with no card, mid-conversation).
@Suite("Built-in brain changes")
struct SystemModelWritesTests {

    private func request(_ messages: [ChatMessage], origin: RequestOrigin = .onDeviceChat) -> GenerationRequest {
        GenerationRequest(modelID: "", messages: messages, origin: origin)
    }

    @Test("add, remind and tick off are changes; questions are not")
    func detection() {
        #expect(SystemModelWrites.isChange(request([.user("Remind me to call mom at 6pm\n/no_think")])))
        #expect(SystemModelWrites.isChange(request([.user("Add lunch with Sam on Friday at 1pm")])))
        #expect(SystemModelWrites.isChange(request([.user("Tick off buy milk")])))
        #expect(!SystemModelWrites.isChange(request([.user("What's on tomorrow?")])))
    }

    @Test("only the chat makes changes")
    func onlyTheChat() {
        #expect(!SystemModelWrites.isChange(request([.user("Remind me to call mom")], origin: .scheduledTask(id: UUID()))))
        #expect(!SystemModelWrites.isChange(request([.user("Remind me to call mom")], origin: .network(host: "x", port: 1))))
    }

    @Test("a change runs without the conversation before it")
    func noHistory() {
        let trimmed = SystemModelWrites.withoutHistory(request([
            .system("Current date and time: Wednesday."),
            .user("Remind me to call mom at 6pm"),
            .assistant("Done."),
            .user("Add lunch with Sam on Friday at 1pm")
        ]))
        #expect(trimmed.messages == [.system("Current date and time: Wednesday."), .user("Add lunch with Sam on Friday at 1pm")])
        // The event-length seam reads the same last turn.
        #expect(ToolContext.userText(of: trimmed) == "Add lunch with Sam on Friday at 1pm")
    }

    @Test("a claim with no write behind it is replaced by a plain sentence")
    func claimsAreScreened() {
        let add = request([.user("Add lunch with Sam on Friday at 1pm")])
        #expect(SystemModelWrites.screen("Lunch with Sam has been added for Friday.", wrote: false, for: add)
            == "Pocketd didn't add that. Try asking again.")
        #expect(SystemModelWrites.screen("Done!", wrote: false, for: add) == "Pocketd didn't add that. Try asking again.")
        let remind = request([.user("Remind me to buy milk tomorrow")])
        #expect(SystemModelWrites.screen("I'll remind you tomorrow.", wrote: false, for: remind)
            == "Pocketd didn't set that reminder. Try asking again.")
        let tick = request([.user("Tick off buy milk")])
        #expect(SystemModelWrites.screen("Ticked it off.", wrote: false, for: tick) == "Pocketd didn't tick that off. Try asking again.")
    }

    @Test("a question back is allowed, a write's own words are kept")
    func questionsAndRealWrites() {
        let add = request([.user("Add lunch with Sam")])
        #expect(SystemModelWrites.screen("What time on Friday?", wrote: false, for: add) == "What time on Friday?")
        #expect(SystemModelWrites.screen("Shall I set it for 1pm?", wrote: false, for: add) == "Pocketd didn't add that. Try asking again.")
        #expect(SystemModelWrites.screen(" Lunch with Sam is in your calendar. ", wrote: true, for: add) == "Lunch with Sam is in your calendar.")
        #expect(SystemModelWrites.screen("", wrote: true, for: add).isEmpty)
    }
}
