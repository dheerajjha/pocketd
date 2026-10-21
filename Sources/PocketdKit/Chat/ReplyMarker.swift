import Foundation

/// What a reply says when it did not finish.
///
/// A stopped reply used to vanish if it had not produced a word yet, leaving
/// the question standing alone with no answer and no explanation, and a reply
/// cut off by the app being killed was saved half-written with nothing to say
/// so. Both now end in one word the reader can trust.
///
/// The marker is for the person, never for the brain: `strippingStopped` is
/// applied to the copy of the history that goes back to the model, so a small
/// model is never shown "Stopped." as an example of how to answer.
public enum ReplyMarker {
    public static let stopped = "Stopped."

    /// The reply as it should be kept once it has been stopped.
    public static func markingStopped(_ content: String) -> String {
        let kept = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return stopped }
        guard !isMarkedStopped(kept) else { return kept }
        return kept + "\n\n" + stopped
    }

    /// Whether a reply ends in the marker this type writes — the whole reply,
    /// or its own last paragraph. A sentence that merely ends in the word does
    /// not count.
    public static func isMarkedStopped(_ content: String) -> Bool {
        let kept = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return kept == stopped || kept.hasSuffix("\n\n" + stopped)
    }

    /// The reply without the marker, for the model's copy of the history.
    public static func strippingStopped(_ content: String) -> String {
        let kept = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if kept == stopped { return "" }
        guard kept.hasSuffix("\n\n" + stopped) else { return content }
        return String(kept.dropLast(stopped.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The history as the model should see it: markers removed, and an
    /// assistant turn that said nothing but the marker dropped altogether.
    public static func modelHistory(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.compactMap { message in
            guard message.role == .assistant, isMarkedStopped(message.content) else { return message }
            var copy = message
            copy.content = strippingStopped(message.content)
            return copy.content.isEmpty && copy.cards.isEmpty ? nil : copy
        }
    }
}
