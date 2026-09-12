import Foundation

/// One thing the assistant can be given, as the Abilities screen lists them.
///
/// The list exists because the differentiator was invisible. Reading your
/// calendar, your reminders and your health is the single thing this app does
/// that a local-chat app cannot, and all three lived as switches two thirds of
/// the way down Settings, defaulting off, under a header nobody scrolls to.
/// Naming them in one place, with their real state beside them, is the fix.
///
/// The order is the product's claim about what this is. Assistant first, server
/// second — the same ranking `OnboardingView` already makes, for the same
/// reason: "your iPhone is the server" is the developer's answer to a
/// developer's question and it only lands for someone who already owns a laptop
/// they want to point at this phone.
public enum Ability: String, Sendable, Equatable, CaseIterable, Identifiable, Codable {
    case calendar
    case reminders
    case health
    case localServer

    public var id: String { rawValue }

    /// The row's heading.
    public var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .health: "Health"
        case .localServer: "Serve on your network"
        }
    }

    /// What the assistant can actually do with it, in one plain sentence.
    ///
    /// Phrased as things a person would type, not as a description of a
    /// capability. "Read calendar" — the Settings switch's label — tells a
    /// reader what the app will do and not one thing about what they get, and a
    /// switch whose payoff is unstated is a switch that stays off.
    public var summary: String {
        switch self {
        case .calendar:
            "Ask what is on today, when your next meeting is, or whether Thursday is free."
        case .reminders:
            "Ask what is overdue, what is due today, or what is still on a list."
        case .health:
            "Ask how you slept, how active you have been, or whether your resting heart rate has moved."
        case .localServer:
            "Use this phone's model from your laptop — point Ollama or any OpenAI client at its address."
        }
    }

    /// What the user calls the thing being read, for the sentences below.
    public var noun: String {
        switch self {
        case .calendar: "your calendar"
        case .reminders: "your reminders"
        case .health: "your health data"
        case .localServer: "this phone's model"
        }
    }

    /// SF Symbol for the row. A string rather than an `Image` so this file
    /// stays buildable on Linux with the rest of the package.
    public var symbolName: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .health: "heart.text.square"
        case .localServer: "network"
        }
    }

    /// Whether this one reads something of the user's off this device.
    ///
    /// The server does not — it serves weights, and `RequestOrigin` guarantees
    /// a network caller never reaches any of the three that do. That guarantee
    /// is the reason the two kinds of ability can share one screen at all.
    public var readsPersonalData: Bool { self != .localServer }

    /// The EventKit entity this ability is, when it is one.
    ///
    /// Existing so the two abilities that already have a vocabulary keep using
    /// it: `PersonalDataAuthorization.explanation(for:)` is what the tools hand
    /// the model when a read is refused, and the screen saying something
    /// different about the same refusal is how one problem grows two wordings.
    public var entity: PersonalDataEntity? {
        switch self {
        case .calendar: .calendar
        case .reminders: .reminders
        case .health, .localServer: nil
        }
    }

    /// Where the switch that actually governs this lives, in iOS.
    ///
    /// Every one of these is a corridor and not a destination, because no app
    /// can deep-link a user to another app's privacy pane —
    /// `UIApplication.openSettingsURLString` opens this app's own page and goes
    /// no further. So the sentence names the corridor and the button opens the
    /// front door, which between them is the most honest thing available.
    public var systemSettingsPath: String? {
        switch self {
        case .calendar, .reminders: entity?.settingsPath
        case .health: "Settings > Privacy & Security > Health > Pocketd"
        case .localServer: "Settings > Privacy & Security > Local Network > Pocketd"
        }
    }

    /// Whether iOS will ever say where this ability's read grant stands.
    ///
    /// False for Health and only for Health. `HKAuthorizationStatus` describes
    /// *write* access; HealthKit deliberately refuses to report read
    /// authorization so that an app cannot tell "you refused me" apart from
    /// "you have never recorded this", which is the whole point — an app that
    /// could tell would learn that you have a diagnosis from the shape of the
    /// silence. The cost is that any UI claiming a Health state is guessing,
    /// and `AbilityState.of` is where that guess is made impossible rather than
    /// merely discouraged.
    public var grantIsReportedByOS: Bool { self != .health }
}

/// The one fact about this screen that is true of every row on it, and the
/// reason the server can sit on the same list as the other three.
///
/// Kept here rather than typed into the view because it is a claim about
/// `RequestOrigin.mayReachPersonalData`, and a claim about code belongs next to
/// something that can be tested against it.
public let abilityNetworkExclusionNote =
    "Requests that arrive over the network never reach your calendar, reminders or health data. Only the assistant on this phone can."
