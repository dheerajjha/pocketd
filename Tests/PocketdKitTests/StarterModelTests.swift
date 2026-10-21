import Foundation
import Testing
@testable import PocketdKit

/// The device classes the intro has to make a sensible choice on.
private enum Phone {
    static let gigabyte: Int64 = 1024 * 1024 * 1024

    static func budget(ram: Int, entitled: Bool) -> DeviceBudget {
        DeviceBudget(
            physicalMemoryBytes: Int64(ram) * gigabyte,
            hasIncreasedMemoryLimit: entitled,
            environment: .device
        )
    }

    /// iPhone 14, the primary test device.
    static func iPhone14(entitled: Bool = false) -> DeviceBudget { budget(ram: 6, entitled: entitled) }
}

@Suite("Starter models")
struct StarterModelTests {

    /// Every device class this app is expected to run on, with and without the
    /// entitlement. One answer everywhere it fits: the brain that reads your day
    /// and downloads in a few minutes.
    @Test("recommends the one brain that reads your day on every phone that can hold it", arguments: [
        (4, false), (4, true), (6, false), (6, true), (8, false), (8, true), (12, false), (12, true)
    ])
    func recommendation(ram: Int, entitled: Bool) throws {
        let budget = Phone.budget(ram: ram, entitled: entitled)
        let pick = try #require(StarterModels.recommended(budget: budget))

        #expect(pick.id == "qwen3-1.7b")
        #expect(pick.toolSupport.isYes, "an assistant that cannot call a tool is a different product")
        #expect(budget.fit(for: pick).isDownloadable, "never recommend something the gate would refuse")
        #expect(pick == BrainRecommendation.recommended(for: budget), "the intro asks the one rule")
    }

    @Test("a phone too small for any brain that reads the day is offered nothing, not a chat-only one")
    func tinyDevice() {
        // 2 GB: nothing that can call a tool will load. SmolLM2 would, and it
        // used to be the fallback; it printed its own instructions as the brief.
        let budget = Phone.budget(ram: 2, entitled: false)
        #expect(StarterModels.recommended(budget: budget) == nil)
        #expect(StarterModels.candidates(budget: budget).isEmpty)
        #expect(StarterModels.shortlist(budget: budget).isEmpty)
    }

    @Test("a phone that can hold nothing is told so rather than offered a refusal")
    func nothingFits() {
        let budget = DeviceBudget(
            physicalMemoryBytes: 512 * 1024 * 1024,
            hasIncreasedMemoryLimit: false,
            environment: .device
        )
        #expect(StarterModels.recommended(budget: budget) == nil)
        #expect(StarterModels.shortlist(budget: budget).isEmpty)
    }

    @Test("the shortlist only ever lists brains that read your day, the recommendation among them", arguments: [
        (4, false), (4, true), (6, false), (6, true), (8, false), (8, true), (12, true)
    ])
    func shortlist(ram: Int, entitled: Bool) throws {
        let budget = Phone.budget(ram: ram, entitled: entitled)
        let list = StarterModels.shortlist(budget: budget)
        let pick = try #require(StarterModels.recommended(budget: budget))

        #expect(list.count <= 3)
        #expect(list.contains { $0.id == pick.id }, "the intro selects this row; it has to be on screen")
        #expect(list.allSatisfy { $0.dayAccess().readsYourDay }, "a recommended list is a list of brains that read your day")
        #expect(list.allSatisfy { budget.fit(for: $0).isDownloadable })
        #expect(list.allSatisfy { !$0.declaredCapabilities.vision.isYes }, "no projector downloads in the intro")
        #expect(list == list.sorted { $0.totalDownloadBytes < $1.totalDownloadBytes })
        #expect(Set(list.map(\.id)).count == list.count, "no duplicates")
    }

    @Test("on the primary test device the intro offers one brain, and it reads your day")
    func iPhone14Shortlist() {
        let budget = Phone.iPhone14()
        // It used to be SmolLM2, Llama 3.2 1B and Qwen3 1.7B — two of three
        // unable to open the calendar, and nothing on screen saying so.
        #expect(StarterModels.shortlist(budget: budget).map(\.id) == ["qwen3-1.7b"])
        #expect(StarterModels.recommended(budget: budget)?.id == "qwen3-1.7b")
    }

    @Test("a replayed intro never offers a second brain to a phone that already reads your day", arguments: [
        ["qwen3-1.7b"], ["gemma-4-e2b"], ["qwen3-4b", "smollm2-360m"]
    ])
    func replayOffersNothing(installed: [String]) {
        // The walkthrough's replay offered Qwen3 4B, 2.5 GB, to a phone holding
        // Gemma 4 E2B and SmolLM2.
        #expect(StarterModels.recommended(budget: Phone.iPhone14(), installed: Set(installed)) == nil)
    }

    @Test("a phone holding only chat-only brains is offered the one that reads your day")
    func chatOnlyPhoneIsOffered() {
        let pick = StarterModels.recommended(budget: Phone.iPhone14(), installed: ["smollm2-360m", "llama-3.2-1b"])
        #expect(pick?.id == "qwen3-1.7b")
    }

    @Test("what is already on the phone is not listed again")
    func installedAreExcluded() {
        let budget = Phone.budget(ram: 8, entitled: true)
        #expect(StarterModels.shortlist(budget: budget, installed: ["qwen3-1.7b"])
            .allSatisfy { $0.id != "qwen3-1.7b" })
    }

    @Test("the simulator's demoted verdicts still recommend a brain that reads the day")
    func simulatorStillRecommendsSomethingUseful() throws {
        // Everything over 1 GB is `.tight` on a Mac, so a rule that demanded
        // `.comfortable` would recommend nothing on every simulator — and the
        // simulator is where the tool loop is developed.
        let budget = DeviceBudget(
            physicalMemoryBytes: 32 * Phone.gigabyte,
            hasIncreasedMemoryLimit: false,
            environment: .simulator
        )
        let pick = try #require(StarterModels.recommended(budget: budget))

        #expect(pick.id == "qwen3-1.7b", "the smallest that reads the day, not the 3.1 GB Gemma the simulator used to get")
    }
}
