import Foundation
import Testing
@testable import PocketdKit

@Suite("Where an Ask entry may put a question")
struct ConversationEntryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A calendar chip after an unrelated recent chat creates a separate discussion, and each door finds its own again")
    func calendarAfterAmberKite() {
        let amber = Conversation(updatedAt: now, messages: [.user("Amber Kite"), .user("What is 7+5?")], draft: "still editing")
        var day = ConversationEntry.page(.day).destination(current: amber, history: [amber], main: amber.id, needsEmptyDraft: true, now: now)
        #expect(day.id != amber.id && day.topic == .day && day.isEmpty)
        day.messages = [.user("What's on tomorrow?")]
        let main = ConversationEntry.main.destination(current: day, history: [day, amber], main: amber.id, needsEmptyDraft: false, now: now)
        #expect(main == amber)
        #expect(ConversationEntry.page(.day).destination(current: main, history: [day, amber], main: amber.id, needsEmptyDraft: true, now: now) == day)
        // Choosing the calendar row in History explicitly makes it main Ask's destination.
        #expect(ConversationEntry.main.destination(current: amber, history: [day], main: day.id, needsEmptyDraft: false, now: now) == day)
    }

    @Test("Freshness applies only inside the same subject, and a supplied question cannot consume somebody's draft or photos")
    func sameSubject() {
        var original = Conversation(updatedAt: now, messages: [.user("Sleep marker")], topic: .sleep)
        let entry = ConversationEntry.page(.sleep)
        func select(_ chat: Conversation, _ seconds: TimeInterval, replacing: Bool = true) -> Conversation {
            entry.destination(current: chat, history: [original], main: nil, needsEmptyDraft: replacing, now: now.addingTimeInterval(seconds))
        }
        #expect(select(original, 1_800).id == original.id)
        #expect(select(original, 1_801).id != original.id)
        original.draftImages = [Data([0x41])]
        #expect(select(original, 0).isEmpty)
        #expect(select(original, 0, replacing: false) == original)
        original.draftImages = nil; original.draft = "UNSENT ALPHA"
        #expect(select(original, 0).id != original.id)
        #expect(select(original, 0, replacing: false).draft == "UNSENT ALPHA")
        let control = ConversationEntry.current.destination(current: original, history: [], main: nil, needsEmptyDraft: true, now: now)
        #expect(control.id != original.id && control.topic == .sleep && control.isEmpty)
    }

    @Test("Two routines or two Shortcut invocations do not share a thread, even for identical words")
    func externalIdentity() {
        let a = UUID(), b = UUID()
        let result = Conversation(updatedAt: now, messages: [.user("Same question")], topic: .routine(a))
        #expect(ConversationEntry.page(.routine(b)).destination(current: result, history: [result], main: nil, needsEmptyDraft: true, now: now).id != result.id)
        let old = ConversationEntry.shortcut(a).destination(current: result, history: [], main: nil, needsEmptyDraft: true, now: now)
        let new = ConversationEntry.shortcut(b).destination(current: old, history: [old], main: nil, needsEmptyDraft: true, now: now)
        #expect(old.id == a && new.id == b && new.isEmpty && new.topic == .shortcut)
    }

    @Test("A live answer can be viewed, never replaced by a queued page question or Shortcut")
    func inFlight() {
        let id = UUID()
        #expect(ConversationEntry.main.canOpenDuringReply(keyboardOnly: true, current: id, topic: nil, main: id))
        #expect(ConversationEntry.page(.day).canOpenDuringReply(keyboardOnly: true, current: id, topic: .day, main: nil))
        #expect(!ConversationEntry.page(.day).canOpenDuringReply(keyboardOnly: true, current: id, topic: .sleep, main: nil))
        #expect(!ConversationEntry.page(.day).canOpenDuringReply(keyboardOnly: false, current: id, topic: .day, main: nil))
        #expect(!ConversationEntry.shortcut(UUID()).canOpenDuringReply(keyboardOnly: false, current: id, topic: nil, main: id))
    }

    @Test("An older on-disk conversation survives unchanged; a draft-only page and its pending photo can be restored and cleared")
    func diskUpgrade() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory)
        let id = UUID()
        let old = #"{"id":"ID","title":"Old chat","createdAt":"2026-11-23T12:00:00Z","updatedAt":"2026-11-23T12:00:00Z","messages":[{"role":"user","content":"original"}],"draft":"keep"}"#.replacingOccurrences(of: "ID", with: id.uuidString)
        try Data(old.utf8).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        var draft = Conversation(draft: "Copper Fox", topic: .routine(UUID()), draftImages: [Data([1, 2])])
        try await store.save(draft)
        let restored = await ConversationStore(directory: directory).all()
        let legacy = try #require(restored.first { $0.id == id })
        #expect(legacy.topic == nil && legacy.messages == [.user("original")] && legacy.draft == "keep")
        let page = try #require(restored.first { $0.id == draft.id })
        #expect(page.topic == draft.topic && page.draftImages == draft.draftImages && page.displayTitle == "Copper Fox")
        try await store.preserveUnopenedDraft(Conversation(id: id, draft: "delayed setup words", topic: .shortcut))
        #expect(await store.all().first { $0.id == id }?.messages == [.user("original")])
        draft.draft = ""; draft.draftImages = nil; try await store.save(draft)
        #expect(await store.all().map(\.id) == [id])
    }
}
