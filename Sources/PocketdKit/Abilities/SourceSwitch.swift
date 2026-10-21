import Foundation

/// What a source row on You says: On, Off, or "Off in iOS Settings" — and,
/// rarely, that the source is blocked or missing.
///
/// `AbilityState` has fifteen cases because a switch and a permission can
/// disagree in fifteen ways, and every one of them is true. A row a person
/// reads needs the version they can act on: Pocketd reads it, it does not, or
/// iOS has to be asked in the Settings app. The row that said all fifteen —
/// with an amber "Needs attention" pill and a paragraph each — was the one
/// that told people their calendar needed attention because the brain could
/// not use tools.
///
/// The engine's registration is deliberately not an input. Whether the brain
/// in use can read the day is said once, on the Brain row, where it can be
/// fixed; a source the person connected is On whatever brain is answering.
public enum SourceSwitch: Sendable, Equatable {
    /// On and reading — Health's ordinary state included, which iOS never
    /// confirms. A switch, on.
    case on
    /// Off — and also a switch left on that nothing reads through yet: iOS
    /// has never been asked, or the last request failed. Turning it on is the
    /// fix for both, so both show a switch that is off, and turning it on
    /// goes through the one door.
    case off
    /// iOS refused, or allows adding only. The row is a link to Settings
    /// rather than a switch: a switch that flips and springs back is broken.
    case offInSettings
    /// Screen Time or a management profile. Nothing on Pocketd's page in
    /// Settings changes it, so the row opens nothing.
    case blocked
    /// This device has no such store.
    case unavailable

    /// The one row state for these facts.
    public static func of(_ state: AbilityState) -> SourceSwitch {
        switch state {
        case .on, .onButUnconfirmed, .onButWithheld, .pending: .on
        case .off, .offWithGrantStanding, .onAwaitingGrant, .onButFailed: .off
        case .offAndRefused, .onAndRefused, .offAndAddOnly, .onAndAddOnly: .offInSettings
        case .offAndRestricted, .onAndRestricted: .blocked
        case .unsupported: .unavailable
        }
    }

    /// Whether the row is a switch.
    public var isSwitch: Bool { self == .on || self == .off }

    /// The words in place of the switch, when the row is not one.
    public var statusText: String? {
        switch self {
        case .on, .off: nil
        case .offInSettings: "Off in iOS Settings"
        case .blocked: "Blocked on this iPhone"
        case .unavailable: "Not on this iPhone"
        }
    }

    /// Whether tapping the row goes somewhere — the Settings app, through the
    /// connect door, which also turns Pocketd's own switch on so that allowing
    /// it there needs no second tap here.
    public var rowOpensSettings: Bool { self == .offInSettings }

    /// The one grey line under a source: what Pocketd does with it, never how
    /// it is wired.
    public static func detail(for ability: Ability) -> String {
        switch ability {
        case .calendar: "Reads and adds events"
        case .reminders: "Reads, adds and ticks off reminders"
        case .health: "Reads sleep and steps"
        case .localServer: ""
        }
    }
}
