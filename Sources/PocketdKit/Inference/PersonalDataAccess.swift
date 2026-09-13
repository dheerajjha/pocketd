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

    /// Whether this app may *add* to the store.
    ///
    /// `.writeOnly` is a real iOS 17 state and a genuine grant: the user said
    /// "you may put things in my calendar, you may not read it". Adding an
    /// event is therefore allowed where reading one is not, and conflating the
    /// two would refuse a write the user explicitly permitted.
    ///
    /// A reminder create still needs `.granted` in practice, because the
    /// duplicate check reads first — but that is the caller's requirement and
    /// is stated there rather than smuggled into this property.
    public var canWrite: Bool { self == .granted || self == .writeOnly }

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

public extension PersonalDataAuthorization {
    /// Whether `text` is one of the sentences a refused permission produces.
    ///
    /// Exists for the diagnostic log, which has to tell "iOS said no" apart
    /// from "there was nothing to report" — two outcomes that look identical
    /// to a caller, because these tools deliberately never throw and answer
    /// both with a sentence. Derived from `explanation(for:)` rather than
    /// matched against copies of the wording, so rewording a refusal cannot
    /// quietly reclassify it as an empty result.
    static func isRefusalSentence(_ text: String) -> Bool {
        for entity in PersonalDataEntity.allCases {
            for authorization in PersonalDataAuthorization.allCases where !authorization.canRead {
                if authorization.explanation(for: entity) == text { return true }
            }
        }
        return false
    }
}
