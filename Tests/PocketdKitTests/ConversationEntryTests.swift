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

    @Test("A real failed write cannot leave an unsaved draft/photo; a later explicit retry can")
    @MainActor func readOnlyDeparture() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        let store = ConversationStore(directory: dir)
        let other = Conversation(messages: [.user("History B")])
        try await store.save(other)
        #expect(await store.all().map(\.id) == [other.id])

        let original = Conversation(draft: "Unsent A", draftImages: [Data([1, 2, 3])])
        var visible = original, stops = 0, opens = 0
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        // Only a privileged runner that can bypass the mode bits needs an
        // additional directory-at-file obstruction for a genuine write error.
        let blocked = dir.appendingPathComponent(original.id.uuidString + ".json")
        let privileged = fm.isWritableFile(atPath: dir.path)
        if privileged { try fm.createDirectory(at: blocked, withIntermediateDirectories: false) }
        for destination in [Conversation(), other] {
            let change = await ConversationChange.afterSaving(original, to: store, while: { true }) { _ in
                stops += 1; opens += 1; visible = destination; return destination.id
            }
            #expect(change == .saveFailed && visible == original && stops == 0 && opens == 0)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        if privileged { try fm.removeItem(at: blocked) }
        #expect(await store.all().map(\.id) == [other.id]) // Recovery itself did not send or switch.
        let retried = await ConversationChange.afterSaving(original, to: store, while: { true }) { history in
            guard let target = history.first(where: { $0.id == other.id }) else { return nil }
            opens += 1; visible = target; return target.id
        }
        #expect(retried == .opened(other.id) && opens == 1 && visible.id == other.id)
        let recovered = try #require(await store.all().first { $0.id == original.id })
        #expect(recovered.draft == original.draft && recovered.draftImages == original.draftImages)
    }

    @Test("A successful save never commits a navigation that was superseded during I/O")
    @MainActor func staleDeparture() async throws {
        let fm = FileManager.default, dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let store = ConversationStore(directory: dir), original = Conversation(draft: "Before editing")
        let file = dir.appendingPathComponent(original.id.uuidString + ".json")
        var opens = 0
        // Revoke ownership at the actual disk commit: deterministic, without
        // a sleep or an assumption about which actor wins a scheduling race.
        let result = await ConversationChange.afterSaving(original, to: store, while: { !fm.fileExists(atPath: file.path) }) { _ in
            opens += 1; return UUID()
        }
        #expect(result == .superseded && opens == 0)
        #expect(await store.all().first?.draft == original.draft)
    }

    @Test("A direct follow-up sends only its own words in the displayed thread, never typed text or staged photos")
    func directSuggestions() {
        let id = UUID(), photo = Data([0xA1])
        var transcript = [ChatMessage.user("Previous question"), .assistant("Previous answer")]
        let clean = ConversationDraft(thread: id, text: "", photos: [])
        for occupied in [ConversationDraft(thread: id, text: "Unsent", photos: []),
                         ConversationDraft(thread: id, text: "", photos: [photo]),
                         ConversationDraft(thread: id, text: "Unsent", photos: [photo])] {
            let accepted = occupied.acceptSuggestion(in: id, busy: false) { transcript.append(.user("Unexpected")) }
            #expect(!accepted && transcript.count == 2)
        }
        let stale = clean.acceptSuggestion(in: UUID(), busy: false) { transcript.append(.user("Wrong thread")) }
        let busy = clean.acceptSuggestion(in: id, busy: true) { transcript.append(.user("Interrupt")) }
        #expect(!stale && !busy)
        let accepted = clean.acceptSuggestion(in: id, busy: false) { transcript.append(.user("What's on tomorrow?")) }
        #expect(accepted && transcript.map(\.content) == ["Previous question", "Previous answer", "What's on tomorrow?"])
        #expect(transcript.last?.images == [])
    }
}
