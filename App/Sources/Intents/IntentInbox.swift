import Foundation

/// One question, handed from an App Intent to the running app.
///
/// An intent and the app are the same process here but not the same moment:
/// `perform()` runs before the scene is active, and the Chat tab it is aiming
/// at may not exist yet on a cold launch. So the question is left here and
/// collected when there is somewhere to put it.
///
/// A single slot rather than a queue, deliberately. Two questions asked in the
/// half-second before the app comes up is somebody tapping twice, not somebody
/// asking two things, and answering both would start a generation the second
/// one immediately interrupts.
///
/// Lock-guarded statics rather than an actor for the same reason `DiagnosticLog`
/// uses them: `perform()` is `@MainActor` and the drain happens inside a
/// SwiftUI update, and neither wants to be `await`ing a separate actor to find
/// out whether there is anything to do.
enum IntentInbox {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: String?

    static func deliver(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pending = trimmed
    }

    /// Takes the question and clears it, so a scene that becomes active twice
    /// does not ask the same thing twice.
    static func take() -> String? {
        lock.lock()
        defer { lock.unlock() }
        defer { pending = nil }
        return pending
    }
}
