import Foundation
import Testing
@testable import PocketdKit

private let gibibyte: Int64 = 1024 * 1024 * 1024

private func phone(_ ram: Int, entitled: Bool = false) -> DeviceBudget {
    DeviceBudget(physicalMemoryBytes: Int64(ram) * gibibyte, hasIncreasedMemoryLimit: entitled, environment: .device)
}

/// A catalogue entry that reads the day, sized to taste.
private func reader(_ id: String, bytes: Int64, tools: ModelCapabilities.Support = .yes, projector: Int64 = 0) -> ModelRecord {
    ModelRecord(
        id: id, displayName: id, repoID: "test/\(id)", filename: "\(id).gguf",
        parameters: "?", quantization: "Q4_K_M", sizeBytes: bytes, contextLength: 32_768, license: "MIT",
        projectorFilename: projector > 0 ? "\(id)-mmproj.gguf" : nil, projectorSizeBytes: projector,
        toolSupport: tools
    )
}

@Suite("The one recommended brain")
struct BrainRecommendationTests {

    /// The table the screens now agree on. `nil` is a phone too small for any
    /// brain that reads the day; it is told so rather than handed SmolLM2.
    @Test("one answer per phone", arguments: [
        (3, false, nil),
        (3, true, "qwen3-1.7b"),
        (4, false, "qwen3-1.7b"),
        (4, true, "qwen3-1.7b"),
        (6, false, "qwen3-1.7b"),
        (6, true, "qwen3-1.7b"),
        (8, false, "qwen3-1.7b"),
        (8, true, "qwen3-1.7b"),
        (12, true, "qwen3-1.7b"),
        (16, true, "qwen3-1.7b"),
    ] as [(Int, Bool, String?)])
    func table(ram: Int, entitled: Bool, expected: String?) {
        #expect(BrainRecommendation.recommended(for: phone(ram, entitled: entitled))?.id == expected)
    }

    @Test("Gemma 4 E2B, 3.1 GB, is never the recommendation — least of all on a small phone", arguments: [3, 4, 6, 8, 12, 16])
    func gemmaIsNeverTheDefault(ram: Int) {
        for entitled in [false, true] {
            #expect(BrainRecommendation.recommended(for: phone(ram, entitled: entitled))?.id != "gemma-4-e2b")
        }
        let simulator = DeviceBudget(physicalMemoryBytes: 32 * gibibyte, hasIncreasedMemoryLimit: false, environment: .simulator)
        #expect(BrainRecommendation.recommended(for: simulator)?.id != "gemma-4-e2b")
    }

    @Test("the recommendation always reads your day and always fits")
    func alwaysReadsAndFits() {
        for ram in [3, 4, 6, 8, 12] {
            for entitled in [false, true] {
                let budget = phone(ram, entitled: entitled)
                guard let pick = BrainRecommendation.recommended(for: budget) else { continue }
                #expect(pick.dayAccess() == .readsYourDay)
                #expect(budget.fit(for: pick).isDownloadable)
                #expect(!pick.declaredCapabilities.vision.isYes)
            }
        }
    }

    @Test("a larger comfortable day reader under 1.5 GB does not displace the measured starter")
    func measuredStarter() throws {
        let starter = try #require(ModelCatalog.model(withID: "qwen3-1.7b"))
        let budget = phone(8, entitled: true)
        let catalog = [reader("larger", bytes: 1_400_000_000), reader("smaller", bytes: 600_000_000), starter]
        #expect(catalog.allSatisfy { budget.fit(for: $0) == .comfortable })
        #expect(BrainRecommendation.recommended(for: budget, in: catalog) == starter)
        #expect(StarterModels.shortlist(in: catalog, budget: budget, limit: 1) == [starter])
    }

    @Test("if the starter is missing or tight, choose the smallest comfortable reader unless one is already installed")
    func smallestComfortableFallback() throws {
        let starter = try #require(ModelCatalog.model(withID: "qwen3-1.7b"))
        let small = reader("small", bytes: 500_000_000)
        let other = reader("other", bytes: 700_000_000)
        let budget = phone(4)
        #expect(budget.fit(for: starter) == .tight)
        #expect([small, other].allSatisfy { budget.fit(for: $0) == .comfortable })
        for catalog in [[other, small], [starter, other, small]] {
            #expect(BrainRecommendation.recommended(for: budget, in: catalog) == small)
            #expect(StarterModels.recommended(in: catalog, budget: budget, installed: ["smollm2-360m"]) == small)
            #expect(StarterModels.recommended(in: catalog, budget: budget, installed: [other.id]) == nil)
        }
    }

    @Test("when nothing is comfortable, even the measured starter yields to a smaller tight reader")
    func smallestTight() throws {
        let starter = try #require(ModelCatalog.model(withID: "qwen3-1.7b"))
        let small = reader("small", bytes: 1_100_000_000)
        let catalog = [reader("large", bytes: 1_250_000_000), starter, small]
        let budget = phone(4)
        #expect(catalog.allSatisfy { budget.fit(for: $0) == .tight })
        #expect(BrainRecommendation.recommended(for: budget, in: catalog) == small)
    }

    @Test("new downloads resolve the evaluated Q4_K_M, while a prior install keeps its identity")
    func starterArtifact() throws {
        let budget = phone(6)
        let pick = try #require(BrainRecommendation.recommended(for: budget))
        let filename = "Qwen3-1.7B-Q4_K_M.gguf"
        let revision = "d7f544eead698dbd1f15126ef60b45a1e1933222"
        #expect(pick.id == "qwen3-1.7b")
        #expect(pick.repoID == "unsloth/Qwen3-1.7B-GGUF")
        #expect(pick.filename == filename && pick.quantization == "Q4_K_M")
        #expect(pick.sizeBytes == 1_107_409_472)
        #expect(pick.downloadURL.absoluteString == "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/\(revision)/\(filename)?download=true")

        var prior = pick
        prior.sourceURL = nil  // Existing manifests predate the revision pin.
        #expect(prior.downloadURL != pick.downloadURL)
        let store = ModelStore(directory: FileManager.default.temporaryDirectory, budget: budget)
        #expect(store.fileURL(for: pick).lastPathComponent == "qwen3-1.7b.gguf")
        #expect(store.fileURL(for: prior) == store.fileURL(for: pick))
        #expect(BrainRecommendation.offer(for: budget, installed: [prior]) == nil)
    }

    @Test("chat-only, unvetted and vision brains are never recommended, however well they fit")
    func onlyReaders() {
        let catalog = [
            reader("chatty", bytes: 300_000_000, tools: .no),
            reader("unvetted", bytes: 400_000_000, tools: .unknown),
            reader("eyes", bytes: 500_000_000, projector: 100_000_000),
        ]
        #expect(BrainRecommendation.recommended(for: phone(8), in: catalog) == nil)
        #expect(BrainRecommendation.shortlist(for: phone(8), in: catalog).isEmpty)
    }

    @Test("the shortlist is comfortable brains that read the day, plus a tight recommendation")
    func shortlistShape() {
        #expect(BrainRecommendation.shortlist(for: phone(6)).map(\.id) == ["qwen3-1.7b"])
        #expect(BrainRecommendation.shortlist(for: phone(8, entitled: true)).map(\.id) == ["qwen3-1.7b", "qwen3-4b"])
        #expect(BrainRecommendation.shortlist(for: phone(12, entitled: true)).map(\.id) == ["qwen3-1.7b", "qwen3-4b", "gemma-4-e2b"])
        // Tight on a 4 GB phone and still listed, because it is the only one.
        #expect(BrainRecommendation.shortlist(for: phone(4)).map(\.id) == ["qwen3-1.7b"])
    }

    @Test("offer: nothing when the phone already reads your day, the recommendation otherwise")
    func offers() {
        let budget = phone(6)
        let qwen = ModelCatalog.model(withID: "qwen3-1.7b")!
        let smol = ModelCatalog.model(withID: "smollm2-360m")!
        let gemma = ModelCatalog.model(withID: "gemma-4-e2b")!

        #expect(BrainRecommendation.offer(for: budget, installed: []) == qwen)
        #expect(BrainRecommendation.offer(for: budget, installed: [smol]) == qwen)
        #expect(BrainRecommendation.offer(for: budget, installed: [qwen]) == nil)
        #expect(BrainRecommendation.offer(for: budget, installed: [gemma, smol]) == nil)

        #expect(BrainRecommendation.offer(for: budget, installedIDs: ["smollm2-360m"]) == qwen)
        #expect(BrainRecommendation.offer(for: budget, installedIDs: ["qwen3-4b"]) == nil)
        // A searched brain is unvetted, so it does not stand in for the offer.
        #expect(BrainRecommendation.offer(for: budget, installedIDs: ["someone-qwen3-8b-q4_k_m"]) == qwen)
    }

    @Test("the recommendation ignores what is installed; only the offer looks")
    func recommendationIsAFactAboutThePhone() {
        let budget = phone(6)
        let before = BrainRecommendation.recommended(for: budget)
        _ = BrainRecommendation.offer(for: budget, installedIDs: ["qwen3-1.7b"])
        #expect(BrainRecommendation.recommended(for: budget) == before)
    }
}

@Suite("Reads your day / Chat only")
struct DayAccessTests {

    @Test("every catalogue entry says plainly whether it reads your day", arguments: [
        ("gemma-4-e2b", DayAccess.readsYourDay),
        ("qwen3-1.7b", .readsYourDay),
        ("qwen3-4b", .readsYourDay),
        ("llama-3.2-1b", .chatOnly),
        ("llama-3.2-3b", .chatOnly),
        ("smolvlm-500m", .chatOnly),
        ("gemma-3-4b-vision", .chatOnly),
        ("smollm2-360m", .chatOnly),
    ])
    func catalogue(id: String, expected: DayAccess) throws {
        let model = try #require(ModelCatalog.model(withID: id))
        #expect(model.dayAccess() == expected)
    }

    @Test("every catalogue entry is covered")
    func everyEntry() {
        #expect(ModelCatalog.all.allSatisfy { [.readsYourDay, .chatOnly].contains($0.dayAccess()) })
    }

    @Test("the labels are the two words the list prints")
    func labels() {
        #expect(DayAccess.readsYourDay.label == "Reads your day")
        #expect(DayAccess.chatOnly.label == "Chat only")
    }

    @Test("once a brain is resident, the engine's verdict decides")
    func residentGateWins() throws {
        let llama3b = try #require(ModelCatalog.model(withID: "llama-3.2-3b"))
        #expect(llama3b.dayAccess(resident: .inferredCapable) == .readsYourDay)
        #expect(llama3b.dayAccess(resident: .tooSmall(billions: 0.5)) == .chatOnly)

        let qwen = try #require(ModelCatalog.model(withID: "qwen3-1.7b"))
        #expect(qwen.dayAccess(resident: .noModelLoaded) == .readsYourDay, "no verdict is not a verdict")
    }

    @Test("a manifest cannot promote a catalogue brain the catalogue calls chat-only")
    func catalogueWinsOnID() throws {
        var smol = try #require(ModelCatalog.model(withID: "smollm2-360m"))
        smol.toolSupport = .yes
        #expect(smol.dayAccess() == .chatOnly)
    }
}
