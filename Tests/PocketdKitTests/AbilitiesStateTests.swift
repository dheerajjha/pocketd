import Foundation
import Testing
@testable import PocketdKit

/// Every input this screen can be handed, and the one state each of them means.
///
/// There are two independent facts per ability — whether the user switched it on
/// here, and where iOS stands on the permission underneath — and the states
/// nobody models are the ones that go wrong in the field. On-but-not-granted is
/// a switch that reads as working and reads nothing. Granted-but-off is a
/// permission iOS is still holding for an app that has stopped using it, which
/// the word "off" quietly implies it is not. And "iOS will not tell us" is most
/// of what is true about Health.
///
/// The table below is a specification and not a re-derivation: every row is
/// written out, so changing the mapping in `AbilityState.of` turns these red
/// rather than quietly agreeing with itself.
@Suite("What an ability's row is in")
struct AbilitiesStateTests {

    /// Every grant, including one of each of the two that carry a reason.
    ///
    /// The two strings are chosen to name no iOS corridor, so that the sweep in
    /// `AbilitiesCopyTests` is testing the sentences and not its own fixtures.
    static let everyGrant: [AbilityGrant] = [
        .granted, .notAsked, .refused, .addOnly, .restricted,
        .neverReported, .unavailable, .inProgress,
        .failed("port 11434 is already in use"),
    ]

    static let everyRegistration: [AbilityRegistration] = [
        .notApplicable,
        .registered,
        .withheld("A 4096-token context fits it."),
    ]

    // MARK: - The table

    /// What each grant means for an ability whose grant iOS actually reports.
    ///
    /// True of Calendar, Reminders and the server. Written out rather than
    /// computed: a test that recomputes the mapping it is checking agrees with
    /// any mapping at all.
    private static let reportedGrantTable: [(grant: AbilityGrant, enabled: Bool, state: AbilityState)] = [
        (.granted, false, .offWithGrantStanding),
        (.granted, true, .on),
        (.notAsked, false, .off),
        (.notAsked, true, .onAwaitingGrant),
        (.refused, false, .offAndRefused),
        (.refused, true, .onAndRefused),
        (.addOnly, false, .offAndAddOnly),
        (.addOnly, true, .onAndAddOnly),
        (.restricted, false, .offAndRestricted),
        (.restricted, true, .onAndRestricted),
        (.neverReported, false, .off),
        (.neverReported, true, .onButUnconfirmed),
        (.unavailable, false, .unsupported),
        (.unavailable, true, .unsupported),
        (.inProgress, false, .pending),
        (.inProgress, true, .pending),
        (.failed("port 11434 is already in use"), false, .off),
        (.failed("port 11434 is already in use"), true, .onButFailed("port 11434 is already in use")),
    ]

    @Test("every switch position and every answer iOS gives lands on one state", arguments: [Ability.calendar, .reminders, .localServer])
    func theTableHolds(for ability: Ability) {
        for row in Self.reportedGrantTable {
            #expect(
                AbilityState.of(ability, enabled: row.enabled, grant: row.grant) == row.state,
                "\(ability.title), enabled: \(row.enabled), grant: \(row.grant)"
            )
        }
    }

    @Test("the table covers every grant in both switch positions")
    func theTableIsComplete() {
        // Guards the suite against the failure that makes a table test
        // worthless: a grant added to the enum and to nothing else.
        #expect(Self.reportedGrantTable.count == Self.everyGrant.count * 2)
        for grant in Self.everyGrant {
            #expect(Self.reportedGrantTable.filter { $0.grant == grant }.count == 2, "\(grant)")
        }
    }

    // MARK: - Health may not be described

    /// The states that assert something about an iOS read grant.
    ///
    /// Health may never reach any of them. HealthKit reports write
    /// authorization and refuses, deliberately, to report read authorization —
    /// so a refused read and a day with nothing recorded are identical from
    /// inside the app, and every one of these states would be a guess printed as
    /// a fact on the screen whose whole argument is that it does not do that.
    private static let grantClaimingStates: [AbilityState] = [
        .on, .offWithGrantStanding, .onAwaitingGrant,
        .onAndRefused, .offAndRefused, .onAndAddOnly, .offAndAddOnly,
        .onAndRestricted, .offAndRestricted,
    ]

    @Test("no input can make the Health row claim iOS said anything about a read")
    func healthNeverClaimsAGrant() {
        for grant in Self.everyGrant {
            for enabled in [true, false] {
                for registration in Self.everyRegistration {
                    let state = AbilityState.of(.health, enabled: enabled, grant: grant, registration: registration)
                    #expect(
                        Self.grantClaimingStates.contains(state) == false,
                        "grant: \(grant), enabled: \(enabled) produced \(state)"
                    )
                }
            }
        }
    }

    @Test("a caller handing Health a confident answer gets the honest state anyway")
    func healthCoercesAConfidentAnswer() {
        // The realistic mistake: somebody reads `HKHealthStore.authorizationStatus(for:)`,
        // which answers about WRITING, and passes its confident-looking result
        // through as a read grant.
        #expect(AbilityState.of(.health, enabled: true, grant: .granted) == .onButUnconfirmed)
        #expect(AbilityState.of(.health, enabled: true, grant: .refused) == .onButUnconfirmed)
        #expect(AbilityState.of(.health, enabled: true, grant: .notAsked) == .onButUnconfirmed)
        #expect(AbilityState.of(.health, enabled: true, grant: .addOnly) == .onButUnconfirmed)
        // Screen Time is the one that looks like a device fact rather than a
        // grant. EventKit reports it; HealthKit has no such status, so for
        // Health it could only have been inferred.
        #expect(AbilityState.of(.health, enabled: true, grant: .restricted) == .onButUnconfirmed)
        #expect(AbilityState.of(.health, enabled: false, grant: .granted) == .off)

        // And the three that survive, because none of them is a claim about a
        // read: the Health store's absence, a request in flight, and a request
        // that could not be put to the user at all.
        #expect(AbilityState.of(.health, enabled: true, grant: .unavailable) == .unsupported)
        #expect(AbilityState.of(.health, enabled: true, grant: .inProgress) == .pending)
        #expect(AbilityState.of(.health, enabled: true, grant: .failed("HealthKit is not authorized"))
            == .onButFailed("HealthKit is not authorized"))

        // The calendar is the control: its grant IS reported, so the same
        // inputs have to survive there or the coercion is just deleting data.
        #expect(AbilityState.of(.calendar, enabled: true, grant: .granted) == .on)
        #expect(AbilityState.of(.calendar, enabled: true, grant: .restricted) == .onAndRestricted)
    }

    // MARK: - The ranking

    @Test("a tool the engine is not carrying outranks the permission for it")
    func withheldOutranksTheGrant() {
        // Settings already ranks these the same way, and says why: a model that
        // will never call the tool makes the calendar permission beside the
        // point. A 1,024-token window keeps the calendar and drops reminders.
        let squeezed = AbilityRegistration.withheld("A 2048-token context fits it.")
        #expect(AbilityState.of(.reminders, enabled: true, grant: .granted, registration: squeezed)
            == .onButWithheld("A 2048-token context fits it."))
        #expect(AbilityState.of(.reminders, enabled: true, grant: .refused, registration: squeezed)
            == .onButWithheld("A 2048-token context fits it."))

        // But not over a device that cannot do it at all, and not over a prompt
        // that is on screen right now.
        #expect(AbilityState.of(.health, enabled: true, grant: .unavailable, registration: squeezed) == .unsupported)
        #expect(AbilityState.of(.calendar, enabled: true, grant: .inProgress, registration: squeezed) == .pending)

        // And never against a switch that is off: there is nothing registered
        // to withhold, and saying so would be explaining a refusal of something
        // nobody asked for.
        #expect(AbilityState.of(.reminders, enabled: false, grant: .granted, registration: squeezed)
            == .offWithGrantStanding)
    }

    @Test("a switch that is off does not hide a permission iOS is still holding")
    func aStandingGrantSurvivesTheSwitch() {
        // The state that only exists because there is no API to revoke a
        // permission from inside an app. Turning the ability off deregisters
        // the tool; iOS goes on holding the grant.
        let row = AbilityState.of(.calendar, enabled: false, grant: .granted)
        #expect(row == .offWithGrantStanding)
        #expect(row != .off, "collapsing this into .off is the screen saying the permission went off with the switch")
        #expect(row.isWorking == false)
        // Not a warning. Nothing is broken — it is a fact the reader is owed,
        // and an orange row for it would be this screen crying wolf.
        #expect(row.needsAttention == false)
    }

    @Test("a failure from the last time it ran is not held against a switch that is off")
    func aStaleFailureIsNotAComplaint() {
        #expect(AbilityState.of(.localServer, enabled: false, grant: .failed("port 11434 is already in use")) == .off)
        #expect(AbilityState.of(.localServer, enabled: true, grant: .failed("port 11434 is already in use"))
            == .onButFailed("port 11434 is already in use"))
    }

    // MARK: - What the row offers

    @Test("turn-on is only ever offered from off, and turn-off only from on")
    func theButtonMatchesTheSwitch() {
        // The cheapest possible way to tell a reader the screen is not tracking
        // reality is to offer to turn on something that is already on.
        for ability in Ability.allCases {
            for grant in Self.everyGrant {
                for enabled in [true, false] {
                    for registration in Self.everyRegistration {
                        let state = AbilityState.of(ability, enabled: enabled, grant: grant, registration: registration)
                        switch AbilityAction.of(state) {
                        case .turnOn:
                            #expect(Self.isOffFamily(state), "\(ability.title) offers to turn on from \(state)")
                        case .turnOff:
                            #expect(Self.isOffFamily(state) == false, "\(ability.title) offers to turn off from \(state)")
                        case .askAgain, .openSystemSettings, .retry, .none:
                            break
                        }
                    }
                }
            }
        }
    }

    /// Whether the assistant is not using this ability, from the state alone.
    ///
    /// An exhaustive switch rather than a list, so that a state added to the
    /// enum stops this file compiling instead of quietly falling out of the
    /// invariant above.
    private static func isOffFamily(_ state: AbilityState) -> Bool {
        switch state {
        case .off, .offWithGrantStanding, .offAndRefused, .offAndAddOnly, .offAndRestricted:
            true
        case .unsupported, .pending, .on, .onAwaitingGrant, .onAndRefused, .onAndAddOnly,
             .onAndRestricted, .onButUnconfirmed, .onButWithheld, .onButFailed:
            false
        }
    }

    @Test("an ability this device does not have promises nothing and offers nothing")
    func unsupportedIsInert() {
        let state = AbilityState.of(.health, enabled: true, grant: .unavailable)
        #expect(state == .unsupported)
        #expect(AbilityAction.of(state) == .none)
        #expect(AbilityAction.none.label(for: .health) == nil)
        #expect(state.needsAttention == false)
        #expect(state.isWorking == false)
    }

    @Test("restricted is the one refusal with no door, because the lever is not behind it")
    func restrictedOffersNoDoor() {
        // Screen Time and management profiles are not in this app's own page in
        // iOS Settings, and `UIApplication.openSettingsURLString` goes no
        // further than that page. A button there is a dead end.
        #expect(AbilityAction.of(.onAndRestricted) == .none)
        #expect(AbilityAction.of(.offAndRestricted) == .none)
        // Where the lever IS behind that door, it is offered.
        #expect(AbilityAction.of(.onAndRefused) == .openSystemSettings)
        #expect(AbilityAction.of(.offAndRefused) == .openSystemSettings)
        #expect(AbilityAction.of(.onAndAddOnly) == .openSystemSettings)
    }

    @Test("only a working ability reads as working")
    func lookingOnIsNotBeingOn() {
        // All three of these put the word "On" on the row, and only one of them
        // is a claim that a single row of data will come back.
        #expect(AbilityState.on.isWorking)
        #expect(AbilityState.onAwaitingGrant.isWorking == false)
        #expect(AbilityState.onButUnconfirmed.isWorking == false)
        #expect(AbilityState.onButWithheld("A 2048-token context fits it.").isWorking == false)
        #expect(AbilityState.onButFailed("port 11434 is already in use").isWorking == false)
    }

    // MARK: - Reused vocabulary

    @Test("EventKit's answers arrive here without being translated twice")
    func eventKitVocabularyConverts() {
        // The trap is `.writeOnly`: iOS 17 split calendar access in two, and
        // anything testing for "not denied" reports add-only as a grant.
        #expect(AbilityGrant(PersonalDataAuthorization.granted) == .granted)
        #expect(AbilityGrant(PersonalDataAuthorization.notDetermined) == .notAsked)
        #expect(AbilityGrant(PersonalDataAuthorization.denied) == .refused)
        #expect(AbilityGrant(PersonalDataAuthorization.restricted) == .restricted)
        #expect(AbilityGrant(PersonalDataAuthorization.writeOnly) == .addOnly)
        #expect(AbilityGrant(PersonalDataAuthorization.writeOnly) != .granted)

        for authorization in PersonalDataAuthorization.allCases {
            let canRead = AbilityState.of(.calendar, enabled: true, grant: AbilityGrant(authorization)) == .on
            #expect(canRead == authorization.canRead, "\(authorization) reads as working: \(canRead)")
        }
    }

    @Test("the list leads with the assistant and keeps the server second")
    func theOrderIsTheProductsClaim() {
        // Onboarding already makes this ranking and gives the reason: "your
        // iPhone is the server" is the developer's answer to a developer's
        // question. The screen that lists what this app can do has to agree
        // with the screen that introduces it.
        #expect(Ability.allCases == [.calendar, .reminders, .health, .localServer])
        #expect(Ability.allCases.filter(\.readsPersonalData) == [.calendar, .reminders, .health])
    }

    @Test("the corridors are the ones the tools already name")
    func corridorsAreNotRewritten() {
        #expect(Ability.calendar.systemSettingsPath == PersonalDataEntity.calendar.settingsPath)
        #expect(Ability.reminders.systemSettingsPath == PersonalDataEntity.reminders.settingsPath)
        #expect(Ability.calendar.entity == .calendar)
        #expect(Ability.health.entity == nil)
        for ability in Ability.allCases {
            #expect(ability.systemSettingsPath?.isEmpty == false, "\(ability.title) has nowhere to send anyone")
        }
    }
}
