import Foundation
import Testing
@testable import PocketdKit

/// The one door every Connect button goes through.
///
/// Written as a table for the same reason `AbilitiesStateTests` is: a test that
/// recomputes the mapping it checks agrees with any mapping at all.
@Suite("The connect door")
struct ConnectDoorTests {

    // MARK: - What a tap does

    @Test("Calendar and Reminders ask iOS only when iOS has not answered")
    func eventKitAsksOnlyWhenUnanswered() {
        for ability in [Ability.calendar, .reminders] {
            #expect(ConnectDoor.step(for: ability, grant: .notAsked) == .askIOS)
            // Add-only is worth one more request: iOS can still offer the
            // upgrade to full access, and it returns at once if it will not.
            #expect(ConnectDoor.step(for: ability, grant: .addOnly) == .askIOS)
            #expect(ConnectDoor.step(for: ability, grant: .granted) == .alreadyConnected)
            // A refusal cannot be re-asked by the app that was refused.
            #expect(ConnectDoor.step(for: ability, grant: .refused) == .openSettings)
            // Screen Time is not behind Pocketd's page in Settings.
            #expect(ConnectDoor.step(for: ability, grant: .restricted) == .blocked)
            #expect(ConnectDoor.step(for: ability, grant: .unavailable) == .unavailable)
        }
    }

    @Test("Health always asks, because iOS never says where a read stands")
    func healthAlwaysAsks() {
        for grant: AbilityGrant in [.granted, .notAsked, .refused, .addOnly, .restricted,
                                    .neverReported, .inProgress, .failed("no entitlement")] {
            #expect(ConnectDoor.step(for: .health, grant: grant) == .askIOS, "\(grant)")
        }
        #expect(ConnectDoor.step(for: .health, grant: .unavailable) == .unavailable)
    }

    // MARK: - What a screen may say afterwards

    @Test("only a grant is announced as connected")
    func onlyAGrantIsConnected() {
        #expect(ConnectDoor.outcome(for: .calendar, after: .granted) == .connected)
        #expect(ConnectDoor.outcome(for: .calendar, after: .refused) == .notAllowed)
        #expect(ConnectDoor.outcome(for: .reminders, after: .addOnly) == .notAllowed)
        #expect(ConnectDoor.outcome(for: .reminders, after: .restricted) == .blocked)
        // The sheet cannot be dismissed without a choice, so an unanswered
        // question after asking means it never went up.
        #expect(ConnectDoor.outcome(for: .calendar, after: .notAsked) == .couldNotAsk)
        for outcome: ConnectOutcome in [.notAllowed, .openedSettings, .blocked, .unavailable, .couldNotAsk] {
            #expect(outcome.isConnected == false, "\(outcome) would toast \"connected\"")
        }
        #expect(ConnectOutcome.connected.isConnected)
    }

    @Test("Health is connected once the question was put, and never on a failure")
    func healthConnectsOnAnAnsweredQuestion() {
        #expect(ConnectDoor.outcome(for: .health, after: .neverReported) == .connected)
        #expect(ConnectDoor.outcome(for: .health, after: .failed("Missing com.apple.developer.healthkit entitlement"))
            == .couldNotAsk)
        #expect(ConnectDoor.outcome(for: .health, after: .unavailable) == .unavailable)
    }

    @Test("what a screen says is one plain sentence with no iOS error text")
    func sentencesArePlain() {
        let outcomes: [ConnectOutcome] = [.connected, .notAllowed, .openedSettings, .blocked, .unavailable, .couldNotAsk]
        for ability in [Ability.calendar, .reminders, .health] {
            for outcome in outcomes {
                guard let sentence = outcome.sentence(for: ability) else {
                    #expect([.connected, .openedSettings].contains(outcome))
                    continue
                }
                #expect(sentence.hasSuffix("."))
                #expect(sentence.split(separator: " ").count <= 25)
                for leak in ["entitlement", "com.apple", "TCC", "EventKit", "HealthKit", "error"] {
                    #expect(!sentence.localizedCaseInsensitiveContains(leak), "\(sentence)")
                }
            }
        }
        #expect(ConnectOutcome.notAllowed.sentence(for: .calendar) == "Calendar is off in iOS Settings.")
    }

    // MARK: - What a row's button does

    @Test("Try again on Health asks Health again and never starts the server")
    func healthRetryIsHealth() {
        // The P0 this exists for: a failed Health request offered "Try again",
        // and the tap opened a LAN listener and started Bonjour.
        let failed = AbilityPresentation.decide(.health, enabled: true, grant: .failed("HealthKit is not authorized"))
        #expect(failed.action == .retry)
        #expect(failed.action.effect(for: .health) == .connect)
        #expect(failed.action.effect(for: .health) != .startServer)
        #expect(ConnectDoor.step(for: .health, grant: .failed("HealthKit is not authorized")) == .askIOS)
    }

    @Test("only the server's own buttons ever touch the server")
    func onlyTheServerStartsTheServer() {
        let actions: [AbilityAction] = [.turnOn, .turnOff, .askAgain, .openSystemSettings, .retry, .none]
        for ability in [Ability.calendar, .reminders, .health] {
            for action in actions {
                let effect = action.effect(for: ability)
                #expect(effect != .startServer && effect != .stopServer, "\(ability) \(action) → \(effect)")
            }
        }
        #expect(AbilityAction.retry.effect(for: .localServer) == .startServer)
        #expect(AbilityAction.turnOff.effect(for: .localServer) == .stopServer)
    }

    @Test("every state's button maps to an effect that matches it")
    func everyStateHasAnHonestEffect() {
        for ability in [Ability.calendar, .reminders, .health] {
            for grant in AbilitiesStateTests.everyGrant {
                for enabled in [true, false] {
                    let row = AbilityPresentation.decide(ability, enabled: enabled, grant: grant)
                    switch row.action.effect(for: ability) {
                    case .connect: #expect(row.action != .turnOff)
                    case .disconnect: #expect(row.action == .turnOff)
                    case .openSystemSettings: #expect(row.action == .openSystemSettings)
                    case .none: #expect(row.action == .none)
                    case .startServer, .stopServer: Issue.record("\(ability) row reached the server")
                    }
                }
            }
        }
    }
}
