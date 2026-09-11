import Foundation
import Testing
@testable import PocketdKit

/// A reply may only be written where it was aimed.
///
/// The transcript a generation started in is not necessarily the transcript on
/// screen when its first token comes back: a tool round spends a tool body plus
/// a second full prefill between the question and the answer, and History is one
/// tap away throughout. "Append to the last message" meant appending to the last
/// message of whatever was open by then.
@Suite("A reply writes where it was aimed")
struct GenerationTargetTests {

    private static let asked = UUID()
    private static let other = UUID()

    /// The transcript `send()` leaves behind: the question, and the empty
    /// assistant turn the answer fills in.
    private static let inProgress: [ChatMessage] = [.user("what's on today"), .assistant("")]

    @Test("the conversation it was started in is the only one it may write to")
    func writesOnlyToItsOwnConversation() {
        let target = GenerationTarget(conversation: Self.asked, slot: 1)

        #expect(target.canWrite(to: Self.asked, messages: Self.inProgress))
        // The reported failure: the user opens an older conversation while the
        // calendar tool is running, and the card — their meeting titles, times
        // and locations — is appended to it and then saved there, permanently,
        // because `AnswerCard` is `Codable`.
        #expect(target.canWrite(to: Self.other, messages: Self.inProgress) == false)
    }

    @Test("a transcript the same shape as another is still not the same transcript")
    func identityIsNotShape() {
        // The reason the id has to be carried at all. Every conversation in the
        // history list has a last message, and most of them have an assistant
        // one — so nothing about the array can tell the two apart, and a guard
        // that only asks "is there something to append to" says yes to all of
        // them.
        let target = GenerationTarget(conversation: Self.asked, slot: 1)
        let lookalike: [ChatMessage] = [.user("pasta recipe"), .assistant("Boil water.")]

        #expect(lookalike.count == Self.inProgress.count)
        #expect(lookalike.last?.role == .assistant)
        #expect(target.canWrite(to: Self.other, messages: lookalike) == false)
    }

    @Test("a slot that is no longer there is not written to")
    func gonePastTheEnd() {
        let target = GenerationTarget(conversation: Self.asked, slot: 1)

        // `deleteConversation` and `newConversation` both empty the array while
        // a reply can still be in flight, and an index into an emptied array is
        // a crash rather than a wrong answer.
        #expect(target.canWrite(to: Self.asked, messages: []) == false)
        #expect(target.canWrite(to: Self.asked, messages: [.user("what's on today")]) == false)
    }

    @Test("the slot has to still be an assistant turn")
    func roleIsChecked() {
        // A transcript that came back from disk the same length but not the
        // same shape. `ChatMessage` has no identity of its own, so the index is
        // all there is to carry, and the role is the only thing that can say
        // the index still means what it meant. A card in the user's own bubble
        // is the same leak wearing a different colour.
        let target = GenerationTarget(conversation: Self.asked, slot: 1)
        let reshaped: [ChatMessage] = [.assistant("Boil water."), .user("with what sauce")]

        #expect(reshaped.indices.contains(1))
        #expect(target.canWrite(to: Self.asked, messages: reshaped) == false)
    }

    @Test("the slot is the one that was stamped, not whatever is last")
    func writesToItsOwnSlot() {
        // `count - 1` is a moving target and the stamp is not. Two turns later
        // in the same conversation, the last message belongs to a different
        // question — which is what a second `send()` produces while the first
        // reply is still arriving.
        let target = GenerationTarget(conversation: Self.asked, slot: 1)
        let laterOn: [ChatMessage] = [
            .user("what's on today"), .assistant("One meeting."),
            .user("and tomorrow"), .assistant("")
        ]

        #expect(target.canWrite(to: Self.asked, messages: laterOn))
        #expect(target.slot == 1)
        #expect(target.slot != laterOn.count - 1)
    }

    @Test("the stamp is a value, so nothing can move it after the fact")
    func stampIsAValue() {
        let target = GenerationTarget(conversation: Self.asked, slot: 1)
        var copy = target
        copy.slot = 3
        #expect(target.slot == 1)
        #expect(target != copy)
    }
}
