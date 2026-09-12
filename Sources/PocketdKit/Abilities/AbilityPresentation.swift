import Foundation

/// Everything one row of the Abilities screen says, decided in one place.
///
/// Assembled here rather than in a `body`, for the reason the data inspector's
/// copy is: each of these is a claim the screen makes about this device, and a
/// claim built inline in a view is a claim nobody can write a test against. The
/// screen's whole value is that the state beside an ability can be trusted — so
/// the states, the sentences and the single button are decided where they can be
/// checked, and the view renders what it is handed.
public struct AbilityPresentation: Sendable, Equatable, Identifiable {
    public var ability: Ability
    public var state: AbilityState
    /// Where things stand, in the user's words. Never a claim iOS has not made.
    public var statusLine: String
    /// The one button on the row.
    public var action: AbilityAction
    /// Set whenever a system permission is standing that this app cannot take
    /// back — which is every state where one is known to exist. It exists
    /// because "off" invites the reading that the permission went off with it,
    /// and it did not: there is no API to revoke a permission from inside an
    /// app, and iOS goes on holding the grant until the user says otherwise.
    public var revocationNote: String?
    /// Whether the row should also offer the trip to iOS Settings.
    ///
    /// True exactly when `statusLine` or `revocationNote` names this ability's
    /// corridor — which is to say, when the real lever is not in this app. A
    /// test asserts the two agree for every combination, in both directions: a
    /// button to iOS with no corridor named leaves the reader hunting once they
    /// arrive, and a named corridor with no button makes them walk there alone.
    public var linksToSystemSettings: Bool

    public var id: String { ability.id }

    public init(
        ability: Ability,
        state: AbilityState,
        statusLine: String,
        action: AbilityAction,
        revocationNote: String? = nil,
        linksToSystemSettings: Bool = false
    ) {
        self.ability = ability
        self.state = state
        self.statusLine = statusLine
        self.action = action
        self.revocationNote = revocationNote
        self.linksToSystemSettings = linksToSystemSettings
    }

    /// The whole row, from the independent facts about it.
    ///
    /// - Parameter enabled: whether the user has switched this ability on in
    ///   this app. Not a permission, and never mistaken for one.
    /// - Parameter grant: where the system stands, as far as it will say.
    /// - Parameter registration: what the engine did with the switch, for the
    ///   three abilities that are tools.
    public static func decide(
        _ ability: Ability,
        enabled: Bool,
        grant: AbilityGrant,
        registration: AbilityRegistration = .notApplicable
    ) -> AbilityPresentation {
        let state = AbilityState.of(ability, enabled: enabled, grant: grant, registration: registration)
        return AbilityPresentation(
            ability: ability,
            state: state,
            statusLine: statusLine(for: state, ability),
            action: AbilityAction.of(state),
            revocationNote: revocationNote(for: state, ability),
            linksToSystemSettings: namesTheCorridor(state, ability)
        )
    }

    // MARK: - Where the wording comes from

    /// Where the switch that actually governs this ability lives, in iOS.
    private static func path(_ ability: Ability) -> String {
        // Every ability on this screen has one. The fallback is the front door
        // rather than a crash, because a missing corridor should cost a vaguer
        // sentence and not the screen.
        ability.systemSettingsPath ?? "iOS Settings"
    }

    /// The sentence for a state that describes where an iOS grant stands.
    ///
    /// Three families, and the third is a lock.
    ///
    /// The two EventKit abilities get the tool's own wording, unchanged: these
    /// are the sentences `PersonalDataAuthorization` hands the model when a read
    /// is refused, and they are already specific about which corridor each
    /// remedy is down. A second wording here would mean one problem with two
    /// descriptions, and the one on this screen would be the one nobody ever
    /// tested against the tool.
    ///
    /// The server gets its own, because it reads nothing of the user's and a
    /// sentence about their calendar would be nonsense there.
    ///
    /// Health gets the only sentence it may ever have. `AbilityState.of`
    /// coerces every grant-shaped answer for Health into `.neverReported`, so
    /// none of these states is reachable for it; this is the second lock on the
    /// same door, so that a caller reaching past the coercion still cannot make
    /// the screen say iOS told us anything about a Health read.
    private static func grantSentence(
        _ ability: Ability,
        eventKit: PersonalDataAuthorization,
        server: @autoclosure () -> String
    ) -> String {
        switch ability {
        case .calendar: eventKit.explanation(for: .calendar)
        case .reminders: eventKit.explanation(for: .reminders)
        case .localServer: server()
        case .health: unreportableSentence(ability)
        }
    }

    /// What may be said about an ability whose grant the system will not report.
    ///
    /// Deliberately without an "on" or "off" prefix so it is usable from either
    /// family. The shape is dictated from outside: HealthKit reports *write*
    /// authorization and refuses to report read authorization, so that an app
    /// cannot learn from a refusal that there was something to refuse. Every
    /// other row here can say on or off; this one may only say what is
    /// genuinely known, which is nothing, and say why.
    private static func unreportableSentence(_ ability: Ability) -> String {
        ability == .health
            ? "iOS never tells an app whether a Health read was allowed, so nothing here can show you a state — a refused read and a day with nothing recorded look identical from inside Pocketd. Check what you have shared in \(path(ability))."
            : "iOS does not report this one, so Pocketd cannot confirm it is working. Check it in \(path(ability))."
    }

    private static func offSentence(_ ability: Ability) -> String {
        ability == .localServer
            ? "Off. Nothing else on your network can reach this phone."
            : "Off. The assistant cannot read \(ability.noun)."
    }

    // MARK: - The sentences

    private static func statusLine(for state: AbilityState, _ ability: Ability) -> String {
        switch state {
        case .unsupported:
            switch ability {
            // Word for word what the health switch already says, so a device
            // with no Health store does not describe itself twice.
            case .health: return "Health data is not available on this device, so there is nothing here to read."
            case .localServer: return "This device cannot serve on a network."
            case .calendar, .reminders: return "\(ability.title) is not available on this device."
            }

        case .off:
            return offSentence(ability)

        case .offWithGrantStanding:
            guard ability.readsPersonalData else { return offSentence(ability) }
            return "Off. The assistant cannot read \(ability.noun) — but the iOS permission is still granted."

        // The three off-and-blocked sentences below are deliberately not the
        // tool's. A tool says "Pocketd cannot read your calendar: permission is
        // switched off", which is the right sentence to a model that has just
        // tried to read and the wrong one to a person who has this switched off
        // on purpose: it complains at them about a capability they declined.
        // `AppModel.refreshPersonalDataAuthorization` names exactly this as the
        // reason it reports no status at all for a switched-off entity, and
        // leaves the question to the screen that lists abilities whether they
        // are on or not. This is that screen, and this is the wording that
        // makes an off row's status readable without it reading as a grievance.
        case .offAndRefused:
            return ability.readsPersonalData
                ? "Off. iOS is refusing access to \(ability.noun), so turning this on would read nothing until you allow it in \(path(ability))."
                : "Off. iOS is refusing Pocketd access to the local network, so starting the server would reach nobody until you allow it in \(path(ability))."

        case .offAndAddOnly:
            return ability.readsPersonalData
                ? "Off. iOS has granted add-only access to \(ability.noun), which cannot read at all — change it to Full Access in \(path(ability)) before turning this on."
                : "Off. iOS has granted only partial network access, which is not enough to serve — change it in \(path(ability)) before starting the server."

        case .offAndRestricted:
            return ability.readsPersonalData
                ? "Off. Access to \(ability.noun) is restricted on this device, by Screen Time or a management profile. That is not something Pocketd can change."
                : "Off. Network access is restricted on this device, by Screen Time or a management profile. That is not something Pocketd can change."

        case .pending:
            return ability == .localServer ? "Starting." : "Waiting for iOS to answer."

        case .on:
            return ability == .localServer
                ? "On. Other devices on your network can use this phone's model."
                // The network exclusion is stated on the row rather than only
                // in the footer because this is the sentence someone reads
                // before deciding, and "my calendar, on a thing I am about to
                // put on the network" is the objection it answers.
                : "On. The assistant can read \(ability.noun) when a question needs it — on this phone, and never for a request that arrived over the network."

        case .onAwaitingGrant:
            return grantSentence(
                ability,
                eventKit: .notDetermined,
                server: "On here, but iOS has given no decision about the local network yet. Ask again, and allow the prompt."
            )

        case .onAndRefused:
            return grantSentence(
                ability,
                eventKit: .denied,
                server: "On here, and iOS is refusing Pocketd access to the local network. Allow it in \(path(ability))."
            )

        case .onAndAddOnly:
            return grantSentence(
                ability,
                eventKit: .writeOnly,
                server: "On here, and iOS has granted only partial network access, which is not enough to serve. Change it in \(path(ability))."
            )

        case .onAndRestricted:
            return grantSentence(
                ability,
                eventKit: .restricted,
                server: "On here, and network access is restricted on this device, by Screen Time or a management profile. This cannot be changed from inside Pocketd."
            )

        case .onButUnconfirmed:
            return "On. " + unreportableSentence(ability)

        case let .onButWithheld(reason):
            // The reason is a finished sentence from `CapabilityNotice`, which
            // has already ranked the gate against the budget and picked the one
            // that actually decided. Printing both is what this screen's
            // predecessor did, on the one screen someone opens to find out why
            // their reminders are never read.
            return "On here, and the model in memory is not carrying it. \(reason)"

        case let .onButFailed(reason):
            switch ability {
            case .localServer: return "On, but the server could not start: \(reason)"
            // Word for word what the health switch already says.
            case .health: return "Pocketd could not ask iOS for access to Health: \(reason)"
            case .calendar, .reminders: return "On, but Pocketd could not ask iOS for access: \(reason)"
            }
        }
    }

    /// The sentence under a standing grant, and only under a standing grant.
    ///
    /// Not shown where nothing is known to be granted: on Health it would be a
    /// guess, and on the server there is no read permission to describe. The
    /// failure it prevents is the word "Off" doing double duty — meaning both
    /// "the assistant has stopped using this" (true) and "iOS has stopped
    /// allowing it" (false, and not something any app is able to arrange).
    private static func revocationNote(for state: AbilityState, _ ability: Ability) -> String? {
        guard ability.readsPersonalData, let path = ability.systemSettingsPath else { return nil }
        switch state {
        case .on, .offWithGrantStanding:
            return "This switch registers and deregisters the tool, and does nothing else. No app can hand a system permission back — only you can, in \(path)."
        default:
            return nil
        }
    }

    /// Whether the row's text sends the reader to iOS, and therefore whether it
    /// should also hand them the door.
    ///
    /// The door is `UIApplication.openSettingsURLString`, which opens this app's
    /// own page and goes no further; the corridor named in the sentence is the
    /// rest of the walk. Both halves are needed and neither is any use alone.
    private static func namesTheCorridor(_ state: AbilityState, _ ability: Ability) -> Bool {
        guard ability.systemSettingsPath != nil else { return false }
        switch state {
        case .offAndRefused, .offAndAddOnly, .onAndRefused, .onAndAddOnly, .onButUnconfirmed:
            return true
        // Only where the note is shown at all, which is the two states with a
        // grant known to be standing, and only for the abilities that have one.
        case .on, .offWithGrantStanding:
            return ability.readsPersonalData
        // Restricted is the deliberate omission. Screen Time and management
        // profiles are not behind this app's own page in iOS Settings, and the
        // sentence says where they are rather than opening a door onto a room
        // the lever is not in — which is the dead end this screen replaces.
        case .unsupported, .off, .offAndRestricted, .pending, .onAwaitingGrant,
             .onAndRestricted, .onButWithheld, .onButFailed:
            return false
        }
    }
}
