import Foundation
import Testing
@testable import PocketdKit

@Suite("A reply that did not finish says so")
struct ReplyMarkerTests {

    @Test("a reply stopped before its first word says Stopped.")
    func emptyReply() {
        #expect(ReplyMarker.markingStopped("") == "Stopped.")
        #expect(ReplyMarker.markingStopped("  \n") == "Stopped.")
    }

    @Test("a reply cut off mid-sentence keeps its words and ends in the marker")
    func partialReply() {
        let cut = ReplyMarker.markingStopped("Today's schedule includes a meeting from 10:0")
        #expect(cut == "Today's schedule includes a meeting from 10:0\n\nStopped.")
        #expect(ReplyMarker.isMarkedStopped(cut))
        // Marking twice is marking once.
        #expect(ReplyMarker.markingStopped(cut) == cut)
    }

    @Test("a sentence that happens to end in the word is not a marker")
    func ordinaryWordsAreNotMarkers() {
        #expect(ReplyMarker.isMarkedStopped("The rain Stopped.") == false)
        #expect(ReplyMarker.strippingStopped("The rain Stopped.") == "The rain Stopped.")
    }

    @Test("the model never sees the marker, nor a turn that was only the marker")
    func modelHistoryDropsMarkers() {
        let history: [ChatMessage] = [
            .user("What's on today?"),
            .assistant("Stopped."),
            .user("And tomorrow?"),
            .assistant("Tomorrow you have\n\nStopped."),
            .user("Thanks"),
        ]
        let seen = ReplyMarker.modelHistory(history)
        #expect(seen.map(\.content) == ["What's on today?", "And tomorrow?", "Tomorrow you have", "Thanks"])
        #expect(seen.allSatisfy { !$0.content.contains("Stopped.") })
    }

    @Test("a stopped turn that drew a card keeps the card for the model's history")
    func cardsSurvive() {
        let card = AnswerCard(title: "Today", sections: [])
        var stopped = ChatMessage.assistant("Stopped.")
        stopped.cards = [card]
        let seen = ReplyMarker.modelHistory([.user("What's on?"), stopped])
        #expect(seen.count == 2)
        #expect(seen.last?.content == "")
        #expect(seen.last?.cards == [card])
    }
}
