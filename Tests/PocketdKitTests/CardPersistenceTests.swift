import Testing
import Foundation
@testable import PocketdKit

/// What a card is allowed to cost when it cannot be read.
///
/// Cards are decoration over a tool result and can always be recomputed. The
/// messages around them cannot. So the decoder is strict inside a card — a
/// section of a known kind with a body it cannot read throws, so a bug shows up
/// in a test — and deliberately lossy at the point where that throw would reach
/// a file on disk.
@Suite("Cards never cost a conversation")
struct CardPersistenceTests {
    private func store() throws -> (ConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ConversationStore(directory: directory), directory)
    }

    private func write(_ cardsJSON: String, to directory: URL) throws -> UUID {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","title":"","draft":"",
         "createdAt":"2026-09-11T00:00:00Z","updatedAt":"2026-09-11T00:00:00Z",
         "modelID":"qwen3-1.7b","messages":[
           {"role":"user","content":"what is on today","images":[]},
           {"role":"assistant","content":"Nothing today.","images":[],"cards":\(cardsJSON)}
         ]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        return id
    }

    @Test("a card that cannot be decoded does not take the transcript with it")
    func malformedCardKeepsTheConversation() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A section whose kind this build knows and whose body it cannot read.
        // Before this was made lossy, `AnswerCard.init(from:)` threw, the throw
        // propagated through ChatMessage and Conversation, `all()` caught it
        // with `try?` — and the user's conversation was simply gone from the
        // history list, with no error and nothing to recover it from.
        _ = try write(#"[{"sections":[{"kind":"note","body":{}}]}]"#, to: directory)

        let loaded = await store.all()
        #expect(loaded.count == 1, "the conversation must survive an unreadable card")
        #expect(loaded.first?.messages.count == 2)
        #expect(loaded.first?.messages.last?.content == "Nothing today.")
        #expect(loaded.first?.messages.last?.cards.isEmpty == true)
    }

    @Test("one bad card does not discard the good ones beside it")
    func lossIsPerCardNotPerMessage() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try write(
            #"[{"sections":[{"kind":"note","body":{}}]},{"title":"Today","sections":[]}]"#,
            to: directory
        )

        let loaded = await store.all()
        let cards = try #require(loaded.first?.messages.last?.cards)
        #expect(cards.count == 1)
        #expect(cards.first?.title == "Today")
    }

    @Test("a readable card still round-trips")
    func goodCardsAreUnaffected() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The lossy path must not be a silent hole that swallows working cards.
        _ = try write(#"[{"title":"Today","lede":"One meeting.","sections":[]}]"#, to: directory)

        let card = try #require(await store.all().first?.messages.last?.cards.first)
        #expect(card.title == "Today")
        #expect(card.lede == "One meeting.")
    }

    @Test("a section of an unknown kind is still dropped, not fatal")
    func unknownKindsRemainForwardCompatible() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Written by a future build. This one keeps the card and drops the
        // section it does not understand.
        _ = try write(
            #"[{"title":"Today","sections":[{"kind":"hologram","body":{"x":1}}]}]"#,
            to: directory
        )

        let card = try #require(await store.all().first?.messages.last?.cards.first)
        #expect(card.title == "Today")
        #expect(card.sections.isEmpty)
    }
}
