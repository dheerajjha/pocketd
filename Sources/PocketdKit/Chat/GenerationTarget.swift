import Foundation

/// Where one generation is allowed to write, stamped before it produces a word.
///
/// A reply does not arrive all at once. Tokens come back across an actor hop,
/// and a tool round holds that hop open for the length of a tool body plus a
/// second full prefill — seconds, on a phone — during which the transcript on
/// screen can be replaced wholesale by opening another conversation. "The last
/// message of whatever is on screen" is therefore not the same message it was
/// when the question was asked, and appending to it wrote a calendar card, with
/// the user's meetings in it, into an unrelated conversation, where it was
/// saved: `AnswerCard` is `Codable`, so reopening that conversation redrew
/// somebody's schedule under a question about pasta.
///
/// Both halves are load-bearing and neither implies the other. The conversation
/// id is what stops an event reaching a different transcript. The slot is what
/// stops it reaching a different *message* of the right transcript —
/// `ChatMessage` has no identity of its own, so an index is all there is to
/// carry, and an index only means anything against the array it was taken from.
///
/// This does not replace cancelling the generation, and cancelling does not
/// replace this: cancellation is cooperative, so an event already yielded is
/// already on its way to the main actor and arrives after the swap regardless.
public struct GenerationTarget: Sendable, Equatable {
    /// The conversation this reply belongs to.
    public var conversation: UUID
    /// The index of the assistant turn it is being written into.
    public var slot: Int

    public init(conversation: UUID, slot: Int) {
        self.conversation = conversation
        self.slot = slot
    }

    /// Whether an event from this generation may still be written.
    ///
    /// - Parameter current: The conversation on screen now.
    /// - Parameter messages: That conversation's transcript, as it stands.
    public func canWrite(to current: UUID, messages: [ChatMessage]) -> Bool {
        guard current == conversation else { return false }
        guard messages.indices.contains(slot) else { return false }
        // The role check is what survives a transcript that came back from disk
        // the same length but not the same shape. Writing a card into a user's
        // own message is the same leak wearing a different bubble.
        return messages[slot].role == .assistant
    }
}
