import Foundation

/// Only these reasons cross from a PCC request to the screen. Apple's error
/// descriptions, refusal explanations and metadata can contain the prompt.
public enum AppleCloudFailure: Sendable, Equatable {
    case unavailable, notReady, network, serviceUnavailable
    case limitReached(reset: Date?)
    case busy, timedOut, refused, unsupportedLanguage, contextExceeded, other

    public init?(blocking status: AppleCloudStatus) {
        switch status {
        case .available, .approachingLimit: return nil
        case .unavailable: self = .unavailable
        case .notReady: self = .notReady
        case let .limitReached(reset): self = .limitReached(reset: reset)
        }
    }

    public var diagnosticCode: String {
        switch self {
        case .unavailable: "pcc.unavailable"
        case .notReady: "pcc.notReady"
        case .network: "pcc.network"
        case .serviceUnavailable: "pcc.serviceUnavailable"
        case .limitReached: "pcc.limitReached"
        case .busy: "pcc.busy"
        case .timedOut: "pcc.timedOut"
        case .refused: "pcc.refused"
        case .unsupportedLanguage: "pcc.unsupportedLanguage"
        case .contextExceeded: "pcc.contextExceeded"
        case .other: "pcc.other"
        }
    }

    func sentence(afterWrite: Bool) -> String {
        let cause: String
        let action: String
        switch self {
        case .unavailable:
            cause = "Apple Private Cloud Compute isn't available here."
            action = "Choose an on-device brain."
        case .notReady:
            cause = "Apple Private Cloud Compute isn't ready on this iPhone yet."
            action = "Try later or choose an on-device brain."
        case .serviceUnavailable:
            cause = "Apple Private Cloud Compute is temporarily unavailable."
            action = "Try later or choose an on-device brain."
        case .network:
            cause = "Pocketd couldn't reach Apple Private Cloud Compute."
            action = "Check your internet connection or choose an on-device brain."
        case let .limitReached(reset):
            cause = "You've reached today's Apple Private Cloud Compute limit."
                + (reset.map { " It resets \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "")
            action = "Wait for it to reset or choose an on-device brain."
        case .busy:
            cause = "Apple Private Cloud Compute is busy."
            action = "Try later or choose an on-device brain."
        case .timedOut:
            cause = "Apple Private Cloud Compute didn't answer in time."
            action = "Try later or choose an on-device brain."
        case .refused:
            cause = "Apple Private Cloud Compute declined this request."
            action = "Try rephrasing your question."
        case .unsupportedLanguage:
            cause = "Apple Private Cloud Compute can't answer in this language."
            action = "Try another language or choose an on-device brain."
        case .contextExceeded:
            cause = "This conversation got too long."
            action = "Start a new chat to keep going."
        case .other:
            cause = "Apple Private Cloud Compute couldn't finish this reply."
            action = "Try later or choose an on-device brain."
        }
        // A failed narration does not roll back an EventKit write. In
        // particular, don't advise simply retrying a change after a disconnect.
        return cause + " " + (afterWrite ? "Check your calendar or reminders before asking for the change again." : action)
    }
}
