import Testing
import Foundation
@testable import PocketdKit

@Suite("Conversations")
struct ConversationTests {
    private func temporaryStore() throws -> (ConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-conversations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ConversationStore(directory: directory), directory)
    }

    @Test("a saved conversation reads back with its dates intact")
    func roundTrip() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The regression this exists for: save() encodes dates as ISO-8601 and
        // all() decoded with the default strategy, which expects a bare number.
        // Every file round-tripped to nothing — the store wrote transcripts it
        // could never read back, and the failure looked exactly like "history
        // is empty", which is also what a working empty store looks like.
        let original = Conversation(
            title: "Named",
            modelID: "qwen3-1.7b",
            messages: [.user("hello"), .assistant("hi")]
        )
        try await store.save(original)

        let loaded = await store.all()
        #expect(loaded.count == 1)
        let first = try #require(loaded.first)
        #expect(first.id == original.id)
        #expect(first.title == "Named")
        #expect(first.modelID == "qwen3-1.7b")
        #expect(first.messages.count == 2)
        #expect(abs(first.createdAt.timeIntervalSince(original.createdAt)) < 1)
    }

    @Test("an empty conversation is never written")
    func emptyIsNotPersisted() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Otherwise opening the Chat tab and leaving files a "New conversation"
        // row in the history every single time.
        try await store.save(Conversation())
        #expect(await store.all().isEmpty)

        // A draft alone is worth keeping: it is text someone typed.
        try await store.save(Conversation(draft: "half a thought"))
        #expect(await store.all().count == 1)
    }

    @Test("conversations come back newest first")
    func ordering() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = Conversation(
            updatedAt: Date(timeIntervalSinceNow: -3600),
            messages: [.user("older")]
        )
        let recent = Conversation(
            updatedAt: Date(),
            messages: [.user("newer")]
        )
        try await store.save(old)
        try await store.save(recent)

        let loaded = await store.all()
        #expect(loaded.map(\.id) == [recent.id, old.id])
    }

    @Test("one unreadable file does not hide the rest of the history")
    func corruptFileIsSkipped() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.save(Conversation(messages: [.user("readable")]))
        // A process killed mid-write, which on a device holding gigabytes of
        // model weights is an ordinary Tuesday. The remaining transcripts have
        // to survive it.
        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))

        let loaded = await store.all()
        #expect(loaded.count == 1)
        #expect(loaded.first?.messages.first?.content == "readable")

        // And the bad file is left alone rather than quietly destroyed.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.filter { $0.hasSuffix(".json") }.count == 2)
    }

    @Test("deleting removes only the one asked for")
    func deletion() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keep = Conversation(messages: [.user("keep")])
        let drop = Conversation(messages: [.user("drop")])
        try await store.save(keep)
        try await store.save(drop)

        await store.delete(drop.id)
        let loaded = await store.all()
        #expect(loaded.map(\.id) == [keep.id])
    }

    @Test("an untitled conversation is named from what was said")
    func displayTitle() {
        #expect(Conversation().displayTitle == "New conversation")
        #expect(Conversation(messages: [.user("Explain actors")]).displayTitle == "Explain actors")
        #expect(Conversation(title: "Chosen", messages: [.user("ignored")]).displayTitle == "Chosen")

        // Newlines flattened, because a title that wraps is not a title.
        #expect(Conversation(messages: [.user("first line\nsecond line")]).displayTitle
                == "first line second line")

        let long = String(repeating: "a", count: 200)
        let truncated = Conversation(messages: [.user(long)]).displayTitle
        #expect(truncated.count == 49)
        #expect(truncated.hasSuffix("…"))
    }

    @Test("a system-only transcript still gets a usable name")
    func systemPromptDoesNotBecomeTheTitle() {
        // The system prompt is the app's text, not the user's, and using it
        // would title every conversation identically.
        let conversation = Conversation(messages: [
            .system("You are a helpful assistant."),
            .user("What is a GGUF file?")
        ])
        #expect(conversation.displayTitle == "What is a GGUF file?")
    }
}
