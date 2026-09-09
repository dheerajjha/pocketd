import Foundation

/// Which pile of personal data a tool is asking for.
public enum PersonalDataEntity: Sendable, Equatable, CaseIterable {
    case calendar
    case reminders

    /// What the user calls it.
    public var noun: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "reminders"
        }
    }

    /// Where the switch actually is.
    ///
    /// "Permission denied" on its own sends people to the app's own page in
    /// Settings, which does not have this switch — the calendar and reminder
    /// toggles live under Privacy, per entity, and an app cannot deep-link a
    /// user to them.
    public var settingsPath: String {
        switch self {
        case .calendar: "Settings > Privacy & Security > Calendars > Pocketd"
        case .reminders: "Settings > Privacy & Security > Reminders > Pocketd"
        }
    }
}

/// What the app may do with one entity right now.
///
/// This is EventKit's `EKAuthorizationStatus` restated without EventKit, for
/// one reason: the sentences below are what the user ends up hearing, and they
/// are worth testing on a machine with no calendar database and no simulator.
/// The app target maps the real status onto this and nothing else.
public enum PersonalDataAuthorization: Sendable, Equatable, CaseIterable {
    case granted
    case notDetermined
    case denied
    case restricted
    /// Events only, and the trap in the whole API. iOS 17 split calendar
    /// access in two, and a user who taps "Add Only Access" on the prompt lands
    /// here: the app can file new events and can read none. It is reported as a
    /// grant by anything that only checks for "not denied".
    case writeOnly

    /// Only full access can read. `.writeOnly` is not a read grant, and
    /// `.notDetermined` is not one either — a status that has never been asked
    /// yields nothing until it is.
    public var canRead: Bool { self == .granted }

    /// What the tool returns in place of data.
    ///
    /// A sentence, because the model repeats it to the user more or less
    /// verbatim, and specific about the remedy, because every one of these
    /// states has a different one and "denied" alone has sent a lot of people
    /// to the wrong screen.
    public func explanation(for entity: PersonalDataEntity) -> String {
        switch self {
        case .granted:
            "Pocketd can read your \(entity.noun)."
        case .notDetermined:
            "Pocketd has not been given access to your \(entity.noun) yet and iOS returned no decision. Ask again, and allow the prompt."
        case .denied:
            "Pocketd cannot read your \(entity.noun): permission is switched off. Turn it on in \(entity.settingsPath)."
        case .restricted:
            "Pocketd cannot read your \(entity.noun): access is restricted on this device, by Screen Time or a management profile. This cannot be changed from inside Pocketd."
        case .writeOnly:
            "Pocketd can only add to your \(entity.noun), not read it. Change the permission to Full Access in \(entity.settingsPath)."
        }
    }
}
