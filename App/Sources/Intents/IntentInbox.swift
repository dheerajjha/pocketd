import Foundation

/// One question, handed from an App Intent to the running app.
///
/// An intent and the app are the same process here but not the same moment:
/// `perform()` runs before the scene is active, and the conversation it is
/// aiming at may not exist yet on a cold launch. So the question is left here
/// and collected when there is somewhere to put it.
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

    /// The app's own ear, set by `AppModel` when it is built.
    ///
    /// The slot above is how the question reaches the screen it belongs on.
    /// This is how it reaches the one thing that can hold it until a brain can
    /// answer: the screen only ever put it in the box, so a question asked
    /// while the brain was still downloading sat there unsent for good.
    @MainActor static var onDeliver: ((String) -> Void)?

    @MainActor
    static func deliver(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        pending = trimmed
        lock.unlock()
        onDeliver?(trimmed)
    }

    /// Takes the question and clears it, so a scene that becomes active twice
    /// does not ask the same thing twice.
    static func take() -> String? {
        #if DEBUG
        stageLaunchQuestionOnce()
        #endif
        lock.lock()
        defer { lock.unlock() }
        defer { pending = nil }
        return pending
    }

    #if DEBUG
    /// `-pocketd.siriAsk "What's on today?"`: the question arrives exactly as
    /// `AskPocketdIntent.perform()` would leave it — through `deliver`, before
    /// the shell first collects the slot — because a simulator cannot speak to
    /// Siri, and the path from a Siri phrase to an answer is otherwise only ever
    /// walked on a phone.
    ///
    /// Once per launch. DEBUG only; a Release build has no path through this.
    nonisolated(unsafe) private static var hasStaged = false

    private static func stageLaunchQuestionOnce() {
        guard Thread.isMainThread else { return }
        lock.lock()
        let first = !hasStaged
        hasStaged = true
        lock.unlock()
        guard first else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-pocketd.siriAsk"),
              arguments.indices.contains(flag + 1) else { return }
        let question = arguments[flag + 1]
        MainActor.assumeIsolated { deliver(question) }
    }
    #endif
}
