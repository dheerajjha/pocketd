import Foundation
import Testing
@testable import PocketdKit

/// The phones this app is actually developed and tested against.
private enum Phone {
    static let gigabyte: Int64 = 1024 * 1024 * 1024

    /// iPhone 14, the primary test device.
    static func sixGB(entitled: Bool) -> DeviceBudget {
        DeviceBudget(physicalMemoryBytes: 6 * gigabyte, hasIncreasedMemoryLimit: entitled, environment: .device)
    }

    /// iPhone 16 Pro.
    static func eightGB(entitled: Bool) -> DeviceBudget {
        DeviceBudget(physicalMemoryBytes: 8 * gigabyte, hasIncreasedMemoryLimit: entitled, environment: .device)
    }
}

@Suite("Fit verdict")
struct FitVerdictTests {

    // MARK: The rule, in the words the README uses

    @Test("the budget is physical RAM times the documented fraction, and nothing else")
    func budgetIsTheDocumentedFraction() {
        for ram in [4, 6, 8] {
            let bytes = Int64(ram) * Phone.gigabyte
            let plain = DeviceBudget(physicalMemoryBytes: bytes, hasIncreasedMemoryLimit: false, environment: .device)
            let entitled = DeviceBudget(physicalMemoryBytes: bytes, hasIncreasedMemoryLimit: true, environment: .device)

            #expect(plain.usableBytes == Int64(Double(bytes) * 0.45))
            #expect(entitled.usableBytes == Int64(Double(bytes) * 0.58))
            #expect(entitled.usableBytes < bytes, "no fraction of RAM is all of it")
        }
    }

    /// The table under "Which models actually fit" in the README, row for row.
    ///
    /// It is published, people read it before buying bandwidth, and it is
    /// computed by hand from the same two fractions this code multiplies by. A
    /// change to the budget arithmetic that moves any of these rows is a change
    /// that makes the documentation false, and this is the test that says so.
    @Test("reproduces the README's table of what fits which phone", arguments: [
        ("smollm2-360m", "Fits", "Fits"),
        ("smolvlm-500m", "Fits", "Fits"),
        ("llama-3.2-1b", "Fits", "Fits"),
        ("qwen3-1.7b", "Fits", "Fits"),
        ("llama-3.2-3b", "Tight", "Fits"),
        ("qwen3-4b", "Needs the entitlement", "Fits"),
        ("gemma-3-4b-vision", "Too large", "Tight"),
        ("gemma-4-e2b", "Too large", "Tight")
    ])
    func readmeTable(id: String, iPhone14: String, iPhone16Pro: String) throws {
        let model = try #require(ModelCatalog.model(withID: id))

        // The iPhone 14 column is read without the entitlement, which is why
        // one row in it reads "needs the entitlement" rather than a verdict.
        let plain = Phone.sixGB(entitled: false).fit(for: model)
        let entitled = Phone.sixGB(entitled: true).fit(for: model)
        if iPhone14 == "Needs the entitlement" {
            #expect(plain == .willNotFit)
            #expect(entitled != .willNotFit)
        } else {
            #expect(label(plain) == iPhone14)
        }

        #expect(label(Phone.eightGB(entitled: true).fit(for: model)) == iPhone16Pro)
    }

    private func label(_ fit: DeviceBudget.Fit) -> String {
        switch fit {
        case .comfortable: return "Fits"
        case .tight: return "Tight"
        case .willNotFit: return "Too large"
        }
    }

    // MARK: The badge does not move under the app's own feet

    @Test("a live reading cannot reach a fit verdict")
    func headroomIsNotTheBudget() throws {
        let model = try #require(ModelCatalog.model(withID: "qwen3-1.7b"))
        var budget = Phone.sixGB(entitled: false)
        let verdict = budget.fit(for: model)

        for headroom in [4 * Phone.gigabyte, 900_000_000, 200_000_000, 1] {
            budget.refreshHeadroom(.fixed(headroom))
            #expect(budget.fit(for: model) == verdict,
                    "the fit badge is a property of the phone, not of this second")
        }
        // The reading is not thrown away — it is answered somewhere else.
        #expect(budget.pressure == .critical)
    }

    @Test("pressure and fit are different vocabularies")
    func pressureHasItsOwnWords() {
        var budget = Phone.sixGB(entitled: false)
        #expect(budget.pressure == .unknown)
        #expect(budget.pressure.message == nil, "nothing to say when nothing is known")

        budget.refreshHeadroom(.fixed(3 * Phone.gigabyte))
        #expect(budget.pressure == .easy)
        #expect(budget.pressure.suggestsUnloading == false)

        budget.refreshHeadroom(.fixed(400 * 1024 * 1024))
        #expect(budget.pressure == .tight)

        budget.refreshHeadroom(.fixed(100 * 1024 * 1024))
        #expect(budget.pressure == .critical)
        #expect(budget.pressure.suggestsUnloading)
        #expect(budget.pressure.message?.contains("Unload") == true)
    }

    // MARK: The download gate

    @Test("too large has exactly one door, and it is the override")
    func oversizeNeedsTheOverride() throws {
        let tooBig = try #require(ModelCatalog.model(withID: "gemma-4-e2b"))
        let fits = try #require(ModelCatalog.model(withID: "llama-3.2-1b"))
        let budget = Phone.sixGB(entitled: false)

        #expect(budget.fit(for: tooBig).isDownloadable == false)
        #expect(budget.fit(for: tooBig).needsOverride)
        #expect(budget.fit(for: fits).isDownloadable)
        #expect(budget.fit(for: fits).needsOverride == false)

        // The two flags are each other's negation by construction, so a UI can
        // switch on either without the two disagreeing.
        for verdict: DeviceBudget.Fit in [.willNotFit, .tight, .comfortable] {
            #expect(verdict.isDownloadable == !verdict.needsOverride)
            #expect(verdict.allowsDownload == verdict.isDownloadable)
        }
    }

    @Test("the store refuses an oversize download unless the override says otherwise")
    func storeHonoursTheGate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Nothing is downloaded here: the point is which error comes back, and
        // the source is a closed port so the override's path fails at once.
        let model = ModelRecord(
            id: "oversize", displayName: "Oversize", repoID: "x/y", filename: "z.gguf",
            parameters: "1B", quantization: "Q4_K_M",
            sizeBytes: 40_000_000, contextLength: 4096, license: "n/a",
            sourceURL: URL(string: "http://127.0.0.1:9/z.gguf")!
        )
        let store = ModelStore(
            directory: directory,
            budget: DeviceBudget(
                physicalMemoryBytes: 64 * 1024 * 1024,
                hasIncreasedMemoryLimit: false,
                environment: .device
            )
        )

        await #expect(throws: ModelStoreError.insufficientMemory(model: model.id)) {
            for try await _ in await store.download(model) {}
        }

        // With the override the gate is no longer what stops it. Whatever comes
        // back now is a transport failure, which is the distinction that makes
        // the override an override rather than a second refusal.
        var overriddenError: (any Error)?
        do {
            for try await _ in await store.download(model, allowingOversized: true) {}
        } catch {
            overriddenError = error
        }
        #expect(overriddenError as? ModelStoreError != .insufficientMemory(model: model.id))
    }
}

@Suite("Simulator verdicts")
struct SimulatorBudgetTests {

    /// A 32 GB Mac, which is what `ProcessInfo.physicalMemory` reports inside
    /// the simulator. The simulator judges brains as the phone it stands in
    /// for, not as this.
    private func mac(gigabytes: Int64 = 32, entitled: Bool = false) -> DeviceBudget {
        DeviceBudget(
            physicalMemoryBytes: gigabytes * Phone.gigabyte,
            hasIncreasedMemoryLimit: entitled,
            environment: .simulator
        )
    }

    @Test("the simulator judges as an 8 GB iPhone with Pocketd's entitlement, whatever Mac it runs on")
    func judgesAsAPhone() {
        let phone = Phone.eightGB(entitled: true)
        for gigabytes: Int64 in [16, 32, 96] {
            #expect(mac(gigabytes: gigabytes).usableBytes == phone.usableBytes)
        }
        #expect(mac().verdictMemoryBytes == DeviceBudget.simulatedPhoneMemoryBytes)
        #expect(mac().environmentNote?.contains("8 GB iPhone") == true)
        #expect(Phone.sixGB(entitled: false).environmentNote == nil, "a phone has nothing to apologise for")
    }

    @Test("every catalogue brain gets the verdict an 8 GB iPhone gives it")
    func agreesWithThePhone() {
        let phone = Phone.eightGB(entitled: true)
        for model in ModelCatalog.all {
            #expect(mac().fit(for: model) == phone.fit(for: model), "\(model.id)")
        }
    }

    @Test("the recommended brain is comfortable here, as on the phones it stands for")
    func recommendationIsComfortable() throws {
        let pick = try #require(BrainRecommendation.recommended(for: mac()))
        #expect(pick.id == "qwen3-1.7b")
        #expect(mac().fit(for: pick) == .comfortable, "More brains must not call the recommendation a tight fit")
    }

    @Test("a load on a Mac proves nothing about a phone")
    func loadsDoNotWidenTheBudget() {
        var budget = mac()
        budget.provenLoadBytes = 12 * Phone.gigabyte
        #expect(budget.usableBytes == mac().usableBytes)
        #expect(!budget.isProven)
    }

    @Test("a ten-gigabyte file is too big, on a Mac with room for it")
    func tenGigabytesIsTooBig() {
        let estimate = MemoryEstimate(weightsBytes: 10_450_000_000, projectorBytes: 0, dimensions: nil, contextTokens: 4096)
        #expect(mac(gigabytes: 64).fit(for: estimate) == .willNotFit)
    }
}
