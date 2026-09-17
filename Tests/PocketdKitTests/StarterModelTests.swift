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
    /// entitlement. The recommendation has to be a model that can work the
    /// tools, because tools are what the intro is introducing.
    @Test("recommends a tool-capable model on every device that can hold one", arguments: [
        (4, false, "qwen3-1.7b"),
        (4, true, "qwen3-1.7b"),
        (6, false, "qwen3-1.7b"),
        (6, true, "qwen3-1.7b"),
        (8, false, "qwen3-1.7b"),
        (8, true, "qwen3-4b")
    ])
    func recommendation(ram: Int, entitled: Bool, expected: String) throws {
        let budget = Phone.budget(ram: ram, entitled: entitled)
        let pick = try #require(StarterModels.recommended(budget: budget))

        #expect(pick.id == expected)
        #expect(pick.toolSupport.isYes, "an assistant that cannot call a tool is a different product")
        #expect(budget.fit(for: pick).isDownloadable, "never recommend something the gate would refuse")
        #expect(pick.id != "smollm2-360m", "the smallest model is a fallback, not a default")
    }

    @Test("falls back to the smallest model only when nothing tool-capable fits")
    func tinyDevice() throws {
        // 2 GB: nothing in the catalogue that can call a tool will load.
        let budget = Phone.budget(ram: 2, entitled: false)
        let pick = try #require(StarterModels.recommended(budget: budget))

        #expect(pick.id == "smollm2-360m")
        #expect(StarterModels.candidates(budget: budget).allSatisfy { !$0.toolSupport.isYes })
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

    @Test("the shortlist spans the phone and always contains the recommendation", arguments: [
        (4, false), (4, true), (6, false), (6, true), (8, false), (8, true)
    ])
    func shortlist(ram: Int, entitled: Bool) throws {
        let budget = Phone.budget(ram: ram, entitled: entitled)
        let list = StarterModels.shortlist(budget: budget)
        let pick = try #require(StarterModels.recommended(budget: budget))

        #expect(list.count <= 3)
        #expect(!list.isEmpty)
        #expect(list.contains { $0.id == pick.id }, "the intro selects this row; it has to be on screen")
        #expect(list.allSatisfy { budget.fit(for: $0).isDownloadable })
        #expect(list.allSatisfy { !$0.declaredCapabilities.vision.isYes }, "no projector downloads in the intro")
        #expect(list == list.sorted { $0.totalDownloadBytes < $1.totalDownloadBytes })
        #expect(Set(list.map(\.id)).count == list.count, "no duplicates")
    }

    @Test("on the primary test device the intro offers the three it always did")
    func iPhone14Shortlist() {
        let budget = Phone.iPhone14()
        #expect(StarterModels.shortlist(budget: budget).map(\.id)
                == ["smollm2-360m", "llama-3.2-1b", "qwen3-1.7b"])
        // The change is which one is selected. It used to be the middle by
        // download size — Llama 3.2 1B, whose template has no notion of tools.
        #expect(StarterModels.recommended(budget: budget)?.id == "qwen3-1.7b")
    }

    @Test("what is already on the phone is not offered again")
    func installedAreExcluded() throws {
        let budget = Phone.iPhone14()
        let withoutQwen = try #require(StarterModels.recommended(budget: budget, installed: ["qwen3-1.7b"]))

        #expect(withoutQwen.id != "qwen3-1.7b")
        #expect(StarterModels.shortlist(budget: budget, installed: ["qwen3-1.7b"])
            .allSatisfy { $0.id != "qwen3-1.7b" })
    }

    @Test("the simulator's demoted verdicts do not demote the recommendation")
    func simulatorStillRecommendsSomethingUseful() throws {
        // Everything over 1 GB is `.tight` on a Mac, so a rule that demanded
        // `.comfortable` would recommend SmolLM2 on every simulator — and the
        // simulator is where the tool loop is developed.
        let budget = DeviceBudget(
            physicalMemoryBytes: 32 * Phone.gigabyte,
            hasIncreasedMemoryLimit: false,
            environment: .simulator
        )
        let pick = try #require(StarterModels.recommended(budget: budget))

        #expect(pick.toolSupport.isYes)
        #expect(pick.id != "smollm2-360m")
    }
}
