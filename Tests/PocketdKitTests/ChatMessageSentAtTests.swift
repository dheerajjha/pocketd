import Foundation
import Testing
@testable import PocketdKit

/// `ChatMessage.sentAt` — when a turn was said, for the conversation's day
/// separators. Additive: every conversation already on disk was written
/// without it and must open exactly as before.
@Suite("Chat messages: when they were sent")
struct ChatMessageSentAtTests {

    private func store() throws -> (ConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sent-at-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ConversationStore(directory: directory), directory)
    }

    @Test("a message with no date writes no date key")
    func noDateIsNotWritten() throws {
        let data = try JSONEncoder().encode(ChatMessage.user("what's on today"))
        #expect(!String(decoding: data, as: UTF8.self).contains("sentAt"))
    }

    @Test("a message written before the field existed opens with no date")
    func oldMessagesStillDecode() throws {
        let json = Data(#"{"role":"user","content":"what's on today","images":[]}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: json)
        #expect(message.content == "what's on today")
        #expect(message.sentAt == nil)
    }

    @Test("a date the decoder cannot read costs the date, not the message")
    func unreadableDateIsDropped() throws {
        let json = Data(#"{"role":"user","content":"hi","images":[],"sentAt":"not a date"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ChatMessage.self, from: json)
        #expect(message.content == "hi")
        #expect(message.sentAt == nil)
    }

    @Test("the date survives the round trip through the store")
    func roundTrip() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Whole seconds: the store writes ISO 8601, which carries no fraction.
        let asked = Date(timeIntervalSince1970: 1_792_000_000)
        let answered = asked.addingTimeInterval(4)
        var question = ChatMessage.user("Remind me to call Mom at 6 PM")
        question.sentAt = asked
        let reply = ChatMessage(role: .assistant, content: "Done.", sentAt: answered)
        let undated = ChatMessage.assistant("An answer from before the field existed.")

        try await store.save(Conversation(messages: [question, reply, undated]))

        let loaded = try #require(await store.all().first)
        #expect(loaded.messages.map(\.sentAt) == [asked, answered, nil])
        #expect(loaded.messages.map(\.content) == [question.content, reply.content, undated.content])
    }
}
