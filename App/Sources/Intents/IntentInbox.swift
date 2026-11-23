import Foundation
import PocketdKit

/// `perform()` may arrive before AppModel, or while onboarding has no Ask
/// sheet. Record the processing choice now; only the inbox can grant a Send.
@MainActor
enum IntentInbox {
    static let questions = ShortcutQuestionInbox()

    /// A live AppModel knows whether a saved cloud choice is currently using
    /// a local fallback. Before it exists, only the saved choice is evidence.
    static var onDeliver: ((String) -> ShortcutQuestionInbox.Question?)?

    static func deliver(_ question: String) {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        questions.receive(onDeliver?(words) ?? .init(words, chosen: BrainChoice.load()))
    }

    #if DEBUG
    private static var hasStaged = false

    /// The same delivery path as a cold-launch Siri question. Stage this at
    /// the root, before onboarding, rather than when the shell finally opens.
    static func stageLaunchQuestionOnce() {
        guard !hasStaged else { return }
        hasStaged = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-pocketd.siriAsk"),
              arguments.indices.contains(flag + 1) else { return }
        deliver(arguments[flag + 1])
    }
    #endif
}
