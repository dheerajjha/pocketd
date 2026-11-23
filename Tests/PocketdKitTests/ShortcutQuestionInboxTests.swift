import Foundation
import Testing
@testable import PocketdKit

@MainActor
@Suite("A Shortcut is one Send for the processing choice at arrival")
struct ShortcutQuestionInboxTests {
    private let chat = UUID()

    @Test("A warm delivery, a delayed root appearance and a second readiness callback submit once")
    func warmAndDelayedRoot() throws {
        let inbox = ShortcutQuestionInbox()
        inbox.didReadHistory(current: chat, latest: nil)
        inbox.receive(.init("Add lunch tomorrow", chosen: .builtIn))
        let question = try #require(inbox.takeForPresentation(in: chat))
        let draft = try #require(inbox.stage(question.id, in: chat))
        func claim(_ ready: Bool) -> Bool {
            inbox.claimSend(in: chat, draft: draft, chosen: .builtIn, usingCloud: false, cloudIsBlocked: false, ready: ready)
        }
        #expect(!claim(false)) // A previous reply is still running.
        #expect(inbox.takeForPresentation(in: chat) == nil)
        #expect(claim(true))
        #expect(inbox.takeForPresentation(in: chat) == nil)
        #expect(!claim(true))
    }

    @Test("A question delivered under a local choice or none cannot inherit a later cloud selection",
          arguments: [nil, .builtIn, .downloaded(id: "small")] as [BrainChoice?])
    func optInIsNotAnotherSend(_ choice: BrainChoice?) throws {
        let inbox = ShortcutQuestionInbox()
        inbox.receive(.init("Keep these words", chosen: choice))
        inbox.didReadHistory(current: chat, latest: nil)
        let question = try #require(inbox.takeForPresentation(in: chat))
        let draft = try #require(inbox.stage(question.id, in: chat))
        #expect(!inbox.claimSend(in: chat, draft: draft, chosen: choice, usingCloud: false, cloudIsBlocked: false, ready: false))
        #expect(!inbox.claimSend(in: chat, draft: draft, chosen: .privateCloudCompute, usingCloud: true, cloudIsBlocked: false, ready: true))
        #expect(draft == "Keep these words" && !inbox.isWaiting)
        #expect(inbox.takeForPresentation(in: chat) == nil)
    }

    @Test("History restore never submits a saved draft; a fresh cold-launch invocation can use an already chosen cloud")
    func coldRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A Shortcut arrived before a previous launch's onboarding finished.
        // The intro can save its words, but has no submission claim to save.
        let firstLaunch = ShortcutQuestionInbox()
        firstLaunch.didReadHistory(current: chat, latest: nil)
        firstLaunch.receive(.init("Previously unsent", chosen: nil))
        let editable = try #require(firstLaunch.awaitingPresentation(in: chat))
        let old = Conversation(draft: editable.text)
        try await ConversationStore(directory: directory).save(old)
        let restored = try #require(await ConversationStore(directory: directory).all().first)
        let suite = UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        BrainChoice.privateCloudCompute.save(to: prefs)
        let chosen = BrainChoice.load(from: prefs)

        let inbox = ShortcutQuestionInbox()
        #expect(!inbox.claimSend(in: restored.id, draft: restored.draft, chosen: chosen, usingCloud: true, cloudIsBlocked: false, ready: true))
        // Repeating the exact words is a fresh invocation, independent of the saved draft.
        inbox.receive(.init(restored.draft, chosen: chosen))
        #expect(inbox.takeForPresentation(in: chat) == nil)
        inbox.didReadHistory(current: chat, latest: restored.id)
        #expect(inbox.takeForPresentation(in: chat) == nil)
        let fresh = try #require(inbox.takeForPresentation(in: restored.id))
        let draft = try #require(inbox.stage(fresh.id, in: restored.id))
        #expect(inbox.claimSend(in: restored.id, draft: draft, chosen: chosen, usingCloud: true, cloudIsBlocked: false, ready: true))
        #expect(!inbox.claimSend(in: restored.id, draft: draft, chosen: chosen, usingCloud: true, cloudIsBlocked: false, ready: true))
    }

    @Test("A superseded callback cannot consume a fresh invocation with identical words")
    func superseded() throws {
        let inbox = ShortcutQuestionInbox()
        inbox.didReadHistory(current: chat, latest: nil)
        inbox.receive(.init("Same words", chosen: nil))
        let older = try #require(inbox.takeForPresentation(in: chat))
        inbox.receive(.init("Same words", chosen: .privateCloudCompute))
        let newer = try #require(inbox.takeForPresentation(in: chat))
        #expect(older.id != newer.id)
        #expect(inbox.stage(older.id, in: chat) == nil)
        let draft = try #require(inbox.stage(newer.id, in: chat))
        #expect(inbox.claimSend(in: chat, draft: draft, chosen: .privateCloudCompute, usingCloud: true, cloudIsBlocked: false, ready: true))
    }

    @Test("Editing, clearing, or explicitly sending the staged words retires only that queued Send")
    func draftOwnership() throws {
        for replacement in ["edited", "", "same"] {
            let inbox = ShortcutQuestionInbox()
            inbox.didReadHistory(current: chat, latest: nil)
            inbox.receive(.init("same", chosen: .privateCloudCompute))
            let q = try #require(inbox.takeForPresentation(in: chat))
            let staged = try #require(inbox.stage(q.id, in: chat))
            if replacement == staged { inbox.sentFromComposer(in: chat, text: staged) }
            #expect(!inbox.claimSend(in: chat, draft: replacement, chosen: .privateCloudCompute, usingCloud: true, cloudIsBlocked: false, ready: true))
            #expect(!inbox.isWaiting)
        }
    }

    @Test("Neither an active local fallback nor a blocked quota authorizes a later cloud send")
    func fallbackAndQuota() throws {
        for resident in [ModelRecord.builtInID, ModelRecord.privateCloudComputeID] {
            let inbox = ShortcutQuestionInbox()
            inbox.didReadHistory(current: chat, latest: nil)
            inbox.receive(.init("Check later", chosen: .privateCloudCompute, residentID: resident))
            let q = try #require(inbox.takeForPresentation(in: chat))
            let draft = try #require(inbox.stage(q.id, in: chat))
            let blocked = resident == ModelRecord.privateCloudComputeID
            #expect(!inbox.claimSend(in: chat, draft: draft, chosen: .privateCloudCompute, usingCloud: true, cloudIsBlocked: blocked, ready: !blocked))
            #expect(!inbox.claimSend(in: chat, draft: draft, chosen: .privateCloudCompute, usingCloud: true, cloudIsBlocked: false, ready: true))
        }
    }
}
