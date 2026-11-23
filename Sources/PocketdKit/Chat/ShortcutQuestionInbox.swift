import Foundation
import Observation

/// One Shortcut invocation, from delivery to the actual Send. Waking the app,
/// presenting Ask and finishing a model load can happen in any order; none of
/// those events is a second invocation. Only the editable draft goes to disk.
@MainActor @Observable
public final class ShortcutQuestionInbox {
    public struct Question: Identifiable, Sendable {
        public let id = UUID()
        public let text: String
        fileprivate let allowedCloud: Bool

        public init(_ text: String, chosen: BrainChoice?, residentID: String? = nil) {
            self.text = text
            // On a cold launch the saved choice is known before residency. On
            // a warm launch a local fallback actually answering is local.
            allowedCloud = chosen == .privateCloudCompute
                && (residentID == nil || residentID == ModelRecord.privateCloudComputeID)
        }
    }

    private enum Phase: Equatable { case arrived, opening, inDraft(UUID) }
    private enum Restore { case unread, replacing(UUID), ready }
    private var question: Question?
    private var phase = Phase.arrived
    private var restore = Restore.unread

    public init() {}

    public func receive(_ question: Question) {
        self.question = question
        phase = .arrived
    }

    /// Bootstrap installs the newest conversation immediately after reading
    /// history. Don't put a cold-launch question in the throwaway initial chat:
    /// its draft would be overwritten by the restored one a moment later.
    public func didReadHistory(current: UUID, latest: UUID?) {
        guard case .unread = restore else { return }
        restore = latest != nil && latest != current ? .replacing(current) : .ready
    }

    public func awaitingPresentation(in conversation: UUID) -> Question? {
        guard phase == .arrived else { return nil }
        switch restore {
        case .unread: return nil
        case .replacing(let placeholder) where placeholder == conversation: return nil
        default: return question
        }
    }

    public func takeForPresentation(in conversation: UUID) -> Question? {
        guard let arrival = awaitingPresentation(in: conversation) else { return nil }
        phase = .opening
        return arrival
    }

    public func isOpening(_ id: UUID) -> Bool { phase == .opening && question?.id == id }

    /// Recheck the ID after any asynchronous conversation switch. An older
    /// callback must not submit, overwrite or clear a newer arrival.
    public func stage(_ id: UUID, in conversation: UUID) -> String? {
        guard isOpening(id) else { return nil }
        phase = .inDraft(conversation)
        return question?.text
    }

    public var isWaiting: Bool {
        if case .inDraft = phase { return question != nil }
        return false
    }

    /// Claim *at dispatch*, on the same actor as the caller's Send. A change
    /// of processing location or a blocked quota leaves the words in the box,
    /// without a live request that can fire when the allowance comes back.
    public func claimSend(in conversation: UUID, draft: String, chosen: BrainChoice?, usingCloud: Bool,
                          cloudIsBlocked: Bool, ready: Bool) -> Bool {
        guard let question, case let .inDraft(target) = phase else { return false }
        guard target == conversation, question.text == draft.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.allowedCloud || chosen == .privateCloudCompute,
              !usingCloud || (question.allowedCloud && !cloudIsBlocked) else {
            self.question = nil
            return false
        }
        guard ready else { return false }
        self.question = nil
        return true
    }

    /// The user can explicitly Send the editable words before the wake-up
    /// callback runs. That action owns the turn, including its ordinary queue.
    public func sentFromComposer(in conversation: UUID, text: String) {
        guard phase == .inDraft(conversation), question?.text == text else { return }
        question = nil
    }
}
