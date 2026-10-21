import Foundation

// MARK: - The one door

/// How a source gets connected, decided in one place for every screen that
/// offers it.
///
/// There were five doors — Today's card, Ask's empty state, the offer above the
/// composer, the You switch and the intro — and each one had its own idea of
/// when to ask iOS. When one of them stopped asking, the iOS sheet appeared
/// instead in the middle of a reply, raised by the tool's own read, which is the
/// one moment a permission question can never be a real decision. So the
/// decision about *what* to do lives here, as a pure function the tests can
/// enumerate, and the app has exactly one method that does it.
public enum ConnectDoor {

    /// What tapping Connect should do, given where iOS stands.
    public enum Step: Sendable, Equatable {
        /// iOS has never been asked, or granted only add-only access, which a
        /// second request can still upgrade. Raise the iOS sheet.
        case askIOS
        /// iOS already said yes. Nothing to ask.
        case alreadyConnected
        /// iOS said no. An app cannot ask again, so the only way forward is the
        /// Settings app.
        case openSettings
        /// Screen Time or a management profile. Nothing on this phone's
        /// Settings page for Pocketd can change it, so no door is opened.
        case blocked
        /// This device has no such store.
        case unavailable
    }

    /// The step for one source.
    ///
    /// Health is its own rule. HealthKit never reports a read grant, so there
    /// is no answer to read first: the request is always made, and iOS shows
    /// its sheet only for the types it has not asked about yet. Asking twice
    /// costs nothing, which is also why "Try again" after a failed Health
    /// request is the same step and never anything else.
    public static func step(for ability: Ability, grant: AbilityGrant) -> Step {
        if grant == .unavailable { return .unavailable }
        if ability == .health { return .askIOS }
        switch grant {
        case .granted: return .alreadyConnected
        case .notAsked, .addOnly: return .askIOS
        case .refused: return .openSettings
        case .restricted: return .blocked
        case .unavailable: return .unavailable
        // A sheet already on screen, or an answer this subsystem never gives.
        // Asking is safe in both: iOS returns a settled answer without any UI.
        case .inProgress, .neverReported, .failed: return .askIOS
        }
    }

    /// What iOS said once the sheet, if any, was answered.
    ///
    /// - Parameter grant: the standing answer re-read after the request, for
    ///   Calendar and Reminders.
    public static func outcome(for ability: Ability, after grant: AbilityGrant) -> ConnectOutcome {
        switch grant {
        case .granted: return .connected
        case .refused, .addOnly: return .notAllowed
        case .restricted: return .blocked
        case .unavailable: return .unavailable
        case .neverReported, .inProgress: return ability == .health ? .connected : .notAllowed
        // Still unanswered after asking means the sheet never went up: iOS's
        // own sheet cannot be dismissed without a choice.
        case .notAsked, .failed: return .couldNotAsk
        }
    }
}

// MARK: - What happened

/// The result of one trip through the door, for the screen that opened it.
///
/// A screen says "Calendar connected" only for `.connected`. Every other case
/// carries one plain sentence, or none when there is nothing useful to add —
/// the iOS sheet or the Settings app has just said everything there is to say.
public enum ConnectOutcome: Sendable, Equatable {
    /// iOS granted it. For Health — which never reports a read grant — the
    /// question was put and answered, which is the strongest claim available.
    case connected
    /// iOS said no in the sheet, or only allowed adding.
    case notAllowed
    /// iOS had already said no, so the Settings app was opened.
    case openedSettings
    /// Screen Time or a management profile blocks it.
    case blocked
    /// This device has no such store.
    case unavailable
    /// The question could not be put to the user at all.
    case couldNotAsk

    /// Whether the source is now readable — the only case a screen may
    /// celebrate.
    public var isConnected: Bool { self == .connected }

    /// One sentence for the screen, or nothing.
    ///
    /// Never an iOS error string: the reason a request could not be put is
    /// written to the diagnostics log, and the person holding the phone gets a
    /// sentence they can act on.
    public func sentence(for ability: Ability) -> String? {
        switch self {
        case .connected, .openedSettings:
            return nil
        case .notAllowed:
            return "\(ability.title) is off in iOS Settings."
        case .blocked:
            return "\(ability.title) is blocked on this iPhone by Screen Time or a profile."
        case .unavailable:
            return "\(ability.title) isn't available on this iPhone."
        case .couldNotAsk:
            // Health has one sentence for this, wherever it is said.
            if ability == .health { return HealthRequestFailure.couldNotReach }
            return "Pocketd couldn't ask iOS for \(ability.title). Try again."
        }
    }
}

// MARK: - What a row's button does

/// What one of a row's actions actually does, decided here rather than in the
/// view that draws the button.
///
/// `AbilityAction.retry` is one case shared by every ability, and the view used
/// to decide what it meant. It decided the server: a failed Health request
/// offered "Try again", and the tap started a network listener and Bonjour
/// instead of asking Health again. A pure mapping can be tested for every
/// ability, so that cannot happen quietly a second time.
public enum AbilityEffect: Sendable, Equatable {
    /// Through the connect door: sets the switch, asks iOS where it can.
    case connect
    /// Sets the switch off. No app can hand a permission back to iOS.
    case disconnect
    case openSystemSettings
    case startServer
    case stopServer
    case none
}

public extension AbilityAction {
    /// What tapping this action does for one ability.
    func effect(for ability: Ability) -> AbilityEffect {
        let isServer = ability == .localServer
        switch self {
        case .turnOn: return isServer ? .startServer : .connect
        case .turnOff: return isServer ? .stopServer : .disconnect
        // Asking again and trying again are both the door for a source: it
        // re-reads where iOS stands and asks only if iOS has not answered.
        case .askAgain: return isServer ? .startServer : .connect
        case .retry: return isServer ? .startServer : .connect
        case .openSystemSettings: return .openSystemSettings
        case .none: return .none
        }
    }
}
