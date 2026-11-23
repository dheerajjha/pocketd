import Foundation
import Testing
@testable import PocketdKit

@Suite("Dictation only sends confirmed words from this press")
struct DictationHandoffTests {
    /// Keep the submitted text in the box, as Ask does when no brain is ready.
    /// Exactly-once delivery cannot rely on send() clearing the draft for us.
    private struct Composer {
        var handoff = DictationHandoff()
        var conversation = UUID()
        var draft = ""
        var sent: [String] = []
        var reviews: [String] = []
        var endAudioCount = 0

        mutating func begin() -> UUID {
            let id = handoff.begin(draft: draft, in: conversation)
            let opened = handoff.beginCapture(for: id, draft: draft, in: conversation)
            #expect(opened)
            return id
        }

        mutating func receive(_ event: DictationHandoff.Event, for id: UUID) {
            switch handoff.receive(event, for: id, draft: draft, in: conversation) {
            case .preview(let words): draft = words
            case .submit(let words): draft = words; sent.append(words)
            case .review(let message): reviews.append(message)
            case .endAudio: endAudioCount += 1
            case .cancel: handoff.cancel()
            case nil: break
            }
        }
    }

    @Test("One drag starts once, and a release before permissions or a redraw cannot open the mic later")
    func releaseDuringAuthorization() throws {
        var press = DictationHandoff.Press()
        var handoff = DictationHandoff()
        let chat = UUID()
        var starts = 0
        for _ in 0..<3 {
            press.begin {
                starts += 1
                return handoff.begin(draft: "", in: chat)
            }
        }
        #expect(starts == 1)
        let lifted = press.end()
        let id = try #require(lifted)
        #expect(handoff.id == id)
        let action = handoff.receive(.release, for: id, draft: "", in: chat)
        #expect(action == .cancel) // Also retire the composer's pending permission task.
        #expect(handoff.id == nil)
        let opened = handoff.beginCapture(for: id, draft: "", in: chat)
        #expect(!opened)
        #expect(!press.isDown)
    }

    @Test("Release ends audio once; later provisional words never substitute for the delayed final")
    func delayedFinal() {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("remind me"), for: id)
        #expect(box.draft == "remind me")
        #expect(box.handoff.isHeld)
        box.receive(.release, for: id)
        box.receive(.release, for: id)
        box.receive(.partial("remind me at"), for: id)
        #expect(box.endAudioCount == 1)
        #expect(!box.handoff.isHeld)
        #expect(box.draft == "remind me at")
        #expect(box.sent.isEmpty)

        box.receive(.final("Remind me at four.\n"), for: id)
        box.receive(.final("Remind me at five."), for: id)
        box.receive(.partial("late partial"), for: id)
        box.receive(.timedOut, for: id)
        box.receive(.release, for: id)
        #expect(box.draft == "Remind me at four.")
        #expect(box.sent == ["Remind me at four."])
        #expect(box.reviews.isEmpty)
        #expect(box.handoff.id == nil)
    }

    @Test("A final before release, including after the audio cap, waits for the user's release")
    func earlyFinal() throws {
        var box = Composer()
        let id = box.begin()
        box.receive(.final("What's next?"), for: id)
        box.receive(.partial("what"), for: id)
        box.receive(.failed("Recognition has ended"), for: id)
        #expect(box.draft == "What's next?")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.isEmpty)
        #expect(box.handoff.isHeld)

        // A page may have opened the mic with no finger down. A tap adopts
        // that turn rather than starting over with an empty recording.
        var tap = DictationHandoff.Press()
        tap.begin { box.handoff.id }
        let tapped = tap.end()
        #expect(tapped == id)
        box.receive(.release, for: try #require(tapped))
        box.receive(.release, for: id)
        #expect(box.sent == ["What's next?"])
        #expect(box.endAudioCount == 0)
    }

    @Test("Timeout, error and an empty final keep the last heard words for editing",
          arguments: [DictationHandoff.Event.timedOut, .failed("Microphone disconnected"), .final(" \n ")])
    func unfinished(_ terminal: DictationHandoff.Event) {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("bring"), for: id)
        box.receive(.release, for: id)
        box.receive(.partial("bring bread"), for: id)
        box.receive(.partial(""), for: id)
        box.receive(terminal, for: id)
        box.receive(.final("obsolete"), for: id)
        #expect(box.draft == "bring bread")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.count == 1)
        #expect(box.handoff.id == nil)
    }

    @Test("Auto-stop without a final releases the draft even if the mic button is still held")
    func timeoutWhileHeld() {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("pick up"), for: id)
        box.receive(.timedOut, for: id)
        box.receive(.release, for: id)
        #expect(!box.handoff.isHeld)
        #expect(box.draft == "pick up")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.count == 1)
    }

    @Test("Old callbacks and an old release cannot finalize a newer press on an identical draft")
    func replacement() throws {
        var box = Composer()
        let old = box.begin()
        var oldPress = DictationHandoff.Press()
        oldPress.begin { old }
        box.receive(.partial("buy"), for: old)
        box.receive(.release, for: old)
        let new = box.begin()
        box.receive(.partial("old partial"), for: old)
        box.receive(.final("old final"), for: old)
        box.receive(.timedOut, for: old)
        let lateLift = oldPress.end()
        box.receive(.release, for: try #require(lateLift))
        #expect(box.draft == "buy")
        #expect(box.handoff.id == new)
        #expect(box.handoff.isHeld)
        #expect(box.reviews.isEmpty)
        box.receive(.release, for: new)
        box.receive(.final("Buy apples."), for: new)
        #expect(box.sent == ["Buy apples."])
    }

    @Test("A changed draft wins even if a recognition callback beats the UI change notification",
          arguments: [DictationHandoff.Event.partial("old partial"), .final("old final"), .timedOut])
    func editsWin(_ late: DictationHandoff.Event) {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("ask"), for: id)
        box.receive(.release, for: id)
        box.draft = "my correction"
        box.receive(late, for: id)
        #expect(box.draft == "my correction")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.isEmpty)
        #expect(box.handoff.id == nil)
    }

    @Test("A view dismissal cancels a buffered final without erasing its words")
    func cancelledBeforeRelease() {
        var box = Composer()
        let id = box.begin()
        box.receive(.final("Heard words."), for: id)
        box.handoff.cancel()
        box.receive(.release, for: id)
        box.receive(.final("Late words."), for: id)
        #expect(box.draft == "Heard words.")
        #expect(box.sent.isEmpty)
    }

    @Test("Editing and undoing while waiting cannot revive the old automatic send")
    func editAndUndo() {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("Heard words"), for: id)
        box.receive(.release, for: id)
        box.handoff.cancel() // the text binding retires the turn on its first edit
        box.draft = "My correction"
        box.draft = "Heard words"
        box.receive(.final("Heard words and more."), for: id)
        #expect(box.draft == "Heard words")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.isEmpty)
    }

    @Test("The same draft in another conversation does not belong to the microphone")
    func changedConversation() {
        var box = Composer()
        let id = box.begin()
        box.receive(.release, for: id)
        box.conversation = UUID()
        box.receive(.final("Other conversation's words"), for: id)
        #expect(box.draft.isEmpty)
        #expect(box.sent.isEmpty)
        #expect(box.handoff.id == nil)
    }
}
