import Foundation
import Testing
@testable import PocketdKit

/// One screen, two deciders, and only one of them can be the reason.
///
/// `ToolGate` answers "can this model work the tool protocol" and
/// `CapabilityBudget` answers "does this window have room for the tools it was
/// handed". Both produce a finished English sentence, both used to be rendered,
/// and at a small context they said opposite things about the same registration
/// — on the one screen someone opens to find out why their reminders are never
/// read.
@Suite("What Settings says under the switches")
struct CapabilityNoticeTests {

    /// The configuration from the bug report: a model from Hugging Face search
    /// takes its window from the Settings stepper verbatim, so a 1,024-token
    /// limit is a 1,024-token window, and the pair costs 537 against a ceiling
    /// of 320.
    private static let squeezed = CapabilityBudget(contextTokens: 1024, templateIsToolNative: true)
    private static let roomy = CapabilityBudget(contextTokens: 4096, templateIsToolNative: true)
    private static let pair = [CapabilityFixture.calendar, CapabilityFixture.reminders]

    @Test("a window that refused a capability outranks a gate that says it is live")
    func budgetOverridesTheGateWhenItRefused() throws {
        let plan = Self.squeezed.admit(Self.pair)
        // The arithmetic the sentence rests on, restated so this test fails if
        // the fixture stops reproducing the report rather than passing on a
        // configuration that no longer refuses anything.
        #expect(plan.registered.map(\.name) == [CapabilityFixture.calendarName])
        #expect(plan.droppedGroups == [.reminders])

        let notice = try #require(CapabilityNotice.decide(
            gate: .declaredCapable,
            plan: plan,
            modelName: "Qwen3 1.7B"
        ))

        // The gate's own sentence, which the screen used to print here.
        #expect(ToolGate.Decision.declaredCapable.explanation(modelName: "Qwen3 1.7B")
            == "Qwen3 1.7B can use these tools, and both are registered.")
        #expect(notice.summary.contains("both are registered") == false)
        #expect(notice.summary.contains("Reminders could not be registered"))
        #expect(notice.summary.contains("1024-token context"))
        #expect(notice.isWarning)

        // And the row that says what to change, which is the half the summary
        // does not carry.
        #expect(notice.shortfalls.count == 1)
        #expect(notice.shortfalls[0].contains("Reminders"))
        #expect(notice.shortfalls[0].contains("2048-token context fits it"))
    }

    @Test("a window that refused everything still never claims anything is registered")
    func nothingRegisteredIsNotReportedAsWorking() throws {
        // 512 tokens allows 149 of schema and the first tool wants 315, so the
        // switch is on and not one tool exists. This is the worst case for the
        // old screen: the gate says yes, the budget armed nothing at all, and
        // the only sentence shown was the gate's.
        let tiny = CapabilityBudget(contextTokens: 512, templateIsToolNative: true)
        let plan = tiny.admit(Self.pair)
        #expect(plan.registered.isEmpty)
        #expect(plan.fit == .willNotFit)

        let notice = try #require(CapabilityNotice.decide(
            gate: .inferredCapable,
            plan: plan,
            modelName: "Some 3B"
        ))
        #expect(notice.summary.contains("both tools are registered") == false)
        #expect(notice.summary.contains("Calendar, Reminders could not be registered"))
        #expect(notice.isWarning)
        #expect(notice.shortfalls.count == 2)
    }

    @Test("a gate refusal is the whole answer, because nothing was ever priced")
    func gateRefusalSpeaksAlone() throws {
        // A model the gate refuses is handed nothing, so the engine prices an
        // empty set and there is no plan at all. Naming a window here would be
        // a second explanation for a refusal that already has one, and the
        // wrong one: a bigger context does not make Llama 3.2 1B able to work
        // the protocol.
        for gate in [ToolGate.Decision.declaredIncapable, .templateHasNoTools, .tooSmall(billions: 1.0), .unreadable] {
            let notice = try #require(CapabilityNotice.decide(
                gate: gate, plan: nil, modelName: "Llama 3.2 1B"
            ))
            #expect(notice.summary == gate.explanation(modelName: "Llama 3.2 1B"))
            #expect(notice.isWarning)
            #expect(notice.shortfalls.isEmpty)
        }
    }

    @Test("a gate refusal outranks a plan, even one that was somehow built")
    func gateRefusalIsNotOverriddenByABudget() throws {
        // Defence against the ordering being read backwards later. The engine
        // prices nothing for a refused model today; if that ever changes, the
        // budget must not start explaining a refusal it did not make.
        let notice = try #require(CapabilityNotice.decide(
            gate: .declaredIncapable,
            plan: Self.squeezed.admit(Self.pair),
            modelName: "Llama 3.2 1B"
        ))
        #expect(notice.summary == ToolGate.Decision.declaredIncapable.explanation(modelName: "Llama 3.2 1B"))
        #expect(notice.shortfalls.isEmpty)
    }

    @Test("a window that carried everything leaves the gate to speak")
    func gateSpeaksWhenNothingWasRefused() throws {
        let plan = Self.roomy.admit(Self.pair)
        #expect(plan.dropped.isEmpty)

        let notice = try #require(CapabilityNotice.decide(
            gate: .declaredCapable, plan: plan, modelName: "Qwen3 1.7B"
        ))
        // "On" and "working" were the same word on this screen until they were
        // not, so the working case still says which model is honouring the
        // switch rather than saying nothing.
        #expect(notice.summary == "Qwen3 1.7B can use these tools, and both are registered.")
        #expect(notice.isWarning == false)
        #expect(notice.shortfalls.isEmpty)
    }

    @Test("a routing exclusion is not reported as a fault")
    func routingIsNotAWarning() throws {
        // Routing is a saving. A question about sleep does not want the
        // calendar, and a warning row about it would train people to turn
        // routing off.
        let plan = Self.roomy.admit(CapabilityFixture.inventory, routedTo: [.health])
        #expect(plan.dropped.contains { $0.reason == .notRouted })
        #expect(plan.dropped.contains { $0.reason == .overBudget } == false)

        let notice = try #require(CapabilityNotice.decide(
            gate: .declaredCapable, plan: plan, modelName: "Qwen3 1.7B"
        ))
        #expect(notice.isWarning == false)
        #expect(notice.shortfalls.isEmpty)
    }

    @Test("no model loaded is a note about what happens next, not a refusal")
    func noModelIsNotAWarning() throws {
        let notice = try #require(CapabilityNotice.decide(
            gate: .noModelLoaded, plan: nil, modelName: "No model"
        ))
        #expect(notice.isWarning == false)
        #expect(notice.summary.contains("No model is loaded"))
    }

    @Test("every reachable pairing produces exactly one sentence")
    func oneSentenceAlways() {
        // The property the screen actually needs: whatever the two deciders
        // say, there is one summary, and it is never the gate's blanket claim
        // standing over a budget that refused something.
        let plans: [CapabilityBudget.Plan?] = [
            nil,
            Self.roomy.admit([]),
            Self.roomy.admit(Self.pair),
            Self.squeezed.admit(Self.pair),
            CapabilityBudget(contextTokens: 512, templateIsToolNative: true).admit(Self.pair)
        ]
        let gates: [ToolGate.Decision] = [
            .declaredCapable, .inferredCapable, .declaredIncapable,
            .templateHasNoTools, .tooSmall(billions: 0.5), .unreadable, .noModelLoaded
        ]
        for gate in gates {
            for plan in plans {
                guard let notice = CapabilityNotice.decide(gate: gate, plan: plan, modelName: "M") else {
                    Issue.record("every decision has something to say about the switch")
                    continue
                }
                #expect(!notice.summary.isEmpty)
                let refusedForRoom = plan?.dropped.contains { $0.reason == .overBudget } ?? false
                if gate.registersTools, refusedForRoom {
                    #expect(notice.summary.contains("could not be registered"))
                    #expect(notice.summary.contains("are registered.") == false)
                    #expect(notice.isWarning)
                } else {
                    #expect(notice.summary == gate.explanation(modelName: "M"))
                    #expect(notice.isWarning == gate.isRefusal)
                }
            }
        }
    }
}

/// The one sentence in this app whose wording is constrained from outside.
///
/// iOS never tells an app whether a *read* of Health was granted or refused —
/// `authorizationStatus(for:)` answers about writing — so nothing on screen may
/// imply the app knows which, however convenient that sentence would be.
@Suite("What the health switch says about itself")
struct HealthAvailabilityNoticeTests {

    @Test("a working store says nothing at all")
    func availableIsSilent() {
        #expect(HealthAvailability.available.explanation == nil)
    }

    @Test("a device with no Health store says so, and says nothing about permission")
    func noStoreExplainsItself() throws {
        let sentence = try #require(HealthAvailability.noHealthData.explanation)
        #expect(sentence.contains("not available on this device"))
        // The switch is on, the tool is never registered, and this row is the
        // only thing that can say why — the tool gate above it is describing
        // the calendar pair and a model, neither of which is the reason.
        #expect(sentence.contains("nothing to read"))
    }

    @Test("a failed request carries the reason iOS gave")
    func failureNamesTheReason() throws {
        let sentence = try #require(HealthAvailability.requestFailed("Health is restricted").explanation)
        #expect(sentence.contains("Health is restricted"))
        // Word for word what the tool tells the model, so one problem has one
        // wording wherever it surfaces.
        #expect(sentence == "Pocketd could not ask iOS for access to Health: Health is restricted")
    }

    @Test("no wording anywhere claims a read was refused")
    func neverClaimsDenial() {
        // The constraint, checked rather than trusted to review. HealthKit
        // cannot distinguish "denied" from "no data", so a sentence that says
        // it can is a lie the whole screen then repeats.
        let sentences = [
            HealthAvailability.noHealthData.explanation,
            HealthAvailability.requestFailed("the store is unavailable").explanation
        ].compactMap { $0 }
        #expect(sentences.count == 2)
        for sentence in sentences {
            let lowered = sentence.lowercased()
            for forbidden in ["denied", "refused", "declined", "not allowed", "rejected", "you said no"] {
                #expect(!lowered.contains(forbidden), "\(sentence) implies iOS reported a read decision")
            }
        }
    }
}
