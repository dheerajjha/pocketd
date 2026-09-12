import Foundation
import Testing
@testable import PocketdKit

/// What the Abilities screen says, as against what it is in a position to know.
///
/// Two sentences on this screen are lies waiting to be written, and both are the
/// comfortable wording rather than the true one. "Off" invites the reading that
/// the iOS permission went off with the switch — it did not, and no app has an
/// API that would let it. And a Health row that reads "On" or "Denied" is a
/// guess dressed as a status, because HealthKit reports write authorization and
/// refuses to report read authorization at all.
///
/// A screen whose argument is that its details are checkable teaches the reader
/// nothing worse than that its details are decorative.
@Suite("What an ability's row says")
struct AbilitiesCopyTests {

    private static func sweep(_ body: (AbilityPresentation, Ability, Bool, AbilityGrant) -> Void) {
        for ability in Ability.allCases {
            for grant in AbilitiesStateTests.everyGrant {
                for enabled in [true, false] {
                    for registration in AbilitiesStateTests.everyRegistration {
                        body(
                            AbilityPresentation.decide(ability, enabled: enabled, grant: grant, registration: registration),
                            ability,
                            enabled,
                            grant
                        )
                    }
                }
            }
        }
    }

    // MARK: - The door and the corridor

    @Test("a row that names a corridor hands over the door, and only those rows do")
    func doorsAndCorridorsAgree() {
        // `UIApplication.openSettingsURLString` opens this app's own page and
        // goes no further, so the button is only half the answer — the sentence
        // has to name the rest of the walk. A button with no corridor leaves
        // somebody standing in Settings hunting; a corridor with no button
        // makes them walk there themselves.
        Self.sweep { row, ability, enabled, grant in
            guard let corridor = ability.systemSettingsPath else { return }
            let named = row.statusLine.contains(corridor) || (row.revocationNote?.contains(corridor) ?? false)
            #expect(
                row.linksToSystemSettings == named,
                "\(ability.title) in \(row.state) (enabled: \(enabled), grant: \(grant)) links: \(row.linksToSystemSettings), names: \(named)"
            )
        }
    }

    @Test("every refusal the user can lift names where to lift it")
    func everyLiftableRefusalNamesItsCorridor() {
        Self.sweep { row, ability, _, _ in
            switch row.state {
            case .offAndRefused, .offAndAddOnly, .onAndRefused, .onAndAddOnly, .onButUnconfirmed:
                #expect(row.linksToSystemSettings, "\(ability.title) in \(row.state) strands the reader")
                #expect(row.statusLine.contains(ability.systemSettingsPath ?? "\u{0}"))
            default:
                break
            }
        }
    }

    @Test("Screen Time is named as Screen Time, not as a trip to a pane without the switch")
    func restrictedDoesNotOpenTheWrongDoor() {
        for ability in Ability.allCases where ability.grantIsReportedByOS {
            let on = AbilityPresentation.decide(ability, enabled: true, grant: .restricted)
            let off = AbilityPresentation.decide(ability, enabled: false, grant: .restricted)
            for row in [on, off] {
                #expect(row.action == .none)
                #expect(row.linksToSystemSettings == false)
                #expect(row.statusLine.contains(ability.systemSettingsPath ?? "\u{0}") == false)
                #expect(row.statusLine.contains("Screen Time"))
            }
        }
    }

    // MARK: - Off is not revoked

    @Test("switching an ability off never claims the permission went with it")
    func offDoesNotImplyRevoked() throws {
        let row = AbilityPresentation.decide(.calendar, enabled: false, grant: .granted)
        #expect(row.state == .offWithGrantStanding)
        #expect(row.statusLine.contains("the iOS permission is still granted"))

        let note = try #require(row.revocationNote)
        let text = row.statusLine + " " + note
        // The three shapes of the lie, each of which reads perfectly naturally
        // and none of which any app is able to bring about.
        for forbidden in ["revoked", "no longer has access", "access removed", "permission withdrawn"] {
            #expect(text.lowercased().contains(forbidden) == false, "the row claims \(forbidden)")
        }
        #expect(note.contains("No app can hand a system permission back"))
        #expect(note.contains(PersonalDataEntity.calendar.settingsPath))
        #expect(row.linksToSystemSettings)
    }

    @Test("an ability that is on says what turning it off would and would not do")
    func theOnRowExplainsWhatOffMeans() {
        // The row a reader is looking at when they decide to turn it off, so it
        // is where the limit of the switch belongs.
        let row = AbilityPresentation.decide(.reminders, enabled: true, grant: .granted)
        #expect(row.state == .on)
        #expect(row.action == .turnOff)
        #expect(row.revocationNote?.contains("registers and deregisters the tool, and does nothing else") == true)
        #expect(row.revocationNote?.contains(PersonalDataEntity.reminders.settingsPath) == true)
    }

    @Test("the note only appears where a grant is known to be standing")
    func noNoteWhereNothingIsKnown() {
        Self.sweep { row, ability, _, _ in
            guard row.revocationNote != nil else { return }
            #expect(ability.readsPersonalData, "the server has no read permission to describe")
            #expect(
                row.state == .on || row.state == .offWithGrantStanding,
                "\(ability.title) in \(row.state) describes a grant it does not have"
            )
        }
        // Health in particular: its ordinary state is on-and-unconfirmable, and
        // a note about a standing permission there would be inventing one.
        #expect(AbilityPresentation.decide(.health, enabled: true, grant: .granted).revocationNote == nil)
    }

    // MARK: - Health says only what is known

    @Test("the Health row says iOS will not tell us, rather than guessing which way")
    func healthSaysWhatIsNotKnown() {
        let row = AbilityPresentation.decide(.health, enabled: true, grant: .granted)
        #expect(row.state == .onButUnconfirmed)
        #expect(row.statusLine.contains("iOS never tells an app whether a Health read was allowed"))
        // The half that makes it a fact about HealthKit rather than an excuse.
        #expect(row.statusLine.contains("a refused read and a day with nothing recorded look identical"))
        #expect(row.statusLine.contains(Ability.health.systemSettingsPath ?? "\u{0}"))
        #expect(row.linksToSystemSettings)
        // On, so the button is the one thing this app can actually do about it.
        #expect(row.action == .turnOff)
    }

    @Test("no input makes the Health row assert or deny a grant")
    func healthNeverAssertsAGrant() {
        // Every sentence EventKit's vocabulary would have supplied, none of
        // which HealthKit is in a position to support.
        let forbidden = [
            "permission is switched off",
            "can only add to",
            "has not been given access",
            "The assistant can read your health data",
            "the iOS permission is still granted",
        ]
        Self.sweep { row, ability, enabled, grant in
            guard ability == .health else { return }
            for phrase in forbidden {
                #expect(
                    row.statusLine.contains(phrase) == false,
                    "Health (enabled: \(enabled), grant: \(grant)) claims: \(phrase)"
                )
            }
        }
    }

    @Test("a device with no Health store is not described as a refusal")
    func noHealthStoreIsNotADenial() {
        let row = AbilityPresentation.decide(.health, enabled: true, grant: .unavailable)
        #expect(row.state == .unsupported)
        #expect(row.action == .none)
        #expect(row.linksToSystemSettings == false)
        // The wording the health switch already uses, so one device fact is not
        // described two different ways in two places.
        #expect(row.statusLine.hasPrefix("Health data is not available on this device"))
    }

    // MARK: - One wording for one problem

    @Test("a refusal reads exactly as the tool would have reported it")
    func refusalsReuseTheToolsWords() {
        // These are the sentences `PersonalDataAuthorization` hands the model,
        // which the model then repeats to the user more or less verbatim. A
        // second wording here is one problem with two descriptions, and the one
        // on this screen would be the one nobody tested against the tool.
        #expect(AbilityPresentation.decide(.calendar, enabled: true, grant: .refused).statusLine
            == PersonalDataAuthorization.denied.explanation(for: .calendar))
        #expect(AbilityPresentation.decide(.calendar, enabled: true, grant: .addOnly).statusLine
            == PersonalDataAuthorization.writeOnly.explanation(for: .calendar))
        #expect(AbilityPresentation.decide(.reminders, enabled: true, grant: .notAsked).statusLine
            == PersonalDataAuthorization.notDetermined.explanation(for: .reminders))
        #expect(AbilityPresentation.decide(.reminders, enabled: true, grant: .restricted).statusLine
            == PersonalDataAuthorization.restricted.explanation(for: .reminders))
    }

    @Test("an off row states its status without complaining at somebody who chose it")
    func theOffRowIsNotAGrievance() {
        // The tool's sentence is right for a model that has just tried to read
        // and wrong for a person who switched this off on purpose. `AppModel`
        // names this as the reason it reports no status at all for a
        // switched-off entity, and leaves the question to this screen.
        let row = AbilityPresentation.decide(.calendar, enabled: false, grant: .refused)
        #expect(row.state == .offAndRefused)
        #expect(row.statusLine != PersonalDataAuthorization.denied.explanation(for: .calendar))
        #expect(row.statusLine.hasPrefix("Off."))
        // And it still says the thing that saves the next two minutes: turning
        // the switch on will not be enough on its own.
        #expect(row.statusLine.contains("turning this on would read nothing"))
        #expect(row.linksToSystemSettings)
    }

    // MARK: - The server is not a personal-data ability

    @Test("the server row never talks about reading anything of the user's")
    func theServerRowKeepsItsOwnGrammar() {
        Self.sweep { row, ability, enabled, grant in
            guard ability == .localServer else { return }
            for phrase in ["your calendar", "your reminders", "your health data", "The assistant can read"] {
                #expect(
                    row.statusLine.contains(phrase) == false,
                    "the server row (enabled: \(enabled), grant: \(grant)) says: \(phrase)"
                )
            }
            #expect(row.revocationNote == nil)
        }
    }

    @Test("the server's own states read as reach, and its buttons as serving")
    func theServerSaysWhatItIsFor() {
        let running = AbilityPresentation.decide(.localServer, enabled: true, grant: .granted)
        #expect(running.state == .on)
        #expect(running.statusLine == "On. Other devices on your network can use this phone's model.")
        #expect(running.action.label(for: .localServer) == "Stop serving")

        let stopped = AbilityPresentation.decide(.localServer, enabled: false, grant: .notAsked)
        #expect(stopped.statusLine == "Off. Nothing else on your network can reach this phone.")
        #expect(stopped.action.label(for: .localServer) == "Start serving")

        let broken = AbilityPresentation.decide(.localServer, enabled: true, grant: .failed("port 11434 is already in use"))
        #expect(broken.state == .onButFailed("port 11434 is already in use"))
        #expect(broken.statusLine.contains("port 11434 is already in use"), "a failure with the reason stripped is unactionable")
        #expect(broken.action == .retry)
        #expect(broken.action.label(for: .localServer) == "Try again")
    }

    // MARK: - The row that is on and inert

    @Test("a tool the engine is not carrying does not read as a working ability")
    func withheldIsNotReportedAsWorking() {
        // The failure this row exists for: a 1,024-token window keeps the
        // calendar and drops reminders, and the only sentence on the old screen
        // said both were registered.
        let row = AbilityPresentation.decide(
            .reminders,
            enabled: true,
            grant: .granted,
            registration: .withheld("A 2048-token context fits it.")
        )
        #expect(row.state.isWorking == false)
        #expect(row.state.needsAttention)
        #expect(row.statusLine.contains("the model in memory is not carrying it"))
        #expect(row.statusLine.contains("A 2048-token context fits it."), "the half the reader can act on")
        // Not a permission problem, so not a trip to Settings.
        #expect(row.linksToSystemSettings == false)
        #expect(row.action == .none)
    }

    // MARK: - Nothing is blank

    @Test("every row says something, and says it about itself")
    func noRowIsEmpty() {
        Self.sweep { row, ability, enabled, grant in
            #expect(row.statusLine.isEmpty == false, "\(ability.title) (enabled: \(enabled), grant: \(grant)) is blank")
            #expect(row.revocationNote?.isEmpty != true)
            #expect(row.ability == ability)
            #expect(row.id == ability.rawValue)
            if row.action != .none {
                #expect(row.action.label(for: ability)?.isEmpty == false)
            } else {
                #expect(row.action.label(for: ability) == nil)
            }
        }
    }

    @Test("the promise every row is under is stated once, on the screen")
    func theNetworkExclusionIsStated() {
        // `RequestOrigin.mayReachPersonalData` is true only for `.onDeviceChat`,
        // and it is the reason a server can share a screen with three abilities
        // that read someone's calendar.
        #expect(RequestOrigin.onDeviceChat.mayReachPersonalData)
        #expect(RequestOrigin.network(host: "192.168.1.14", port: 11434).mayReachPersonalData == false)
        #expect(abilityNetworkExclusionNote.contains("never reach"))
        #expect(abilityNetworkExclusionNote.contains("Only the assistant on this phone can"))
    }
}
