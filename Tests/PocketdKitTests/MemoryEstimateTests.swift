import Foundation
import Testing
@testable import PocketdKit

/// Shapes taken from the real models, because the numbers these produce are the
/// point of the tests: a formula that is linear in the right variable but wrong
/// by a factor of three still ships a badge that lies.
enum ModelShapes {

    /// Llama 3.2 3B: 28 layers, 8 KV heads of 128, and the model the old
    /// estimate was most confidently wrong about.
    static let llama3B = GGUFModelDimensions(
        architecture: "llama",
        blockCount: 28,
        embeddingLength: 3072,
        headCount: 24,
        headCountKV: 8,
        keyLength: 128,
        valueLength: 128,
        vocabularySize: 128_256,
        trainedContextLength: 131_072
    )

    /// A 1.5B-class model at Q4: small enough to be comfortable at a short
    /// context, with a modern model's cache.
    static let small = GGUFModelDimensions(
        architecture: "qwen3",
        blockCount: 28,
        embeddingLength: 2048,
        headCount: 16,
        headCountKV: 8,
        keyLength: 128,
        valueLength: 128,
        vocabularySize: 151_936,
        trainedContextLength: 32_768
    )

    /// Gemma-shaped: attends to a fixed window, so its cache stops growing.
    static let slidingWindow = GGUFModelDimensions(
        architecture: "gemma3",
        blockCount: 34,
        embeddingLength: 2560,
        headCount: 8,
        headCountKV: 4,
        keyLength: 256,
        valueLength: 256,
        vocabularySize: 262_144,
        trainedContextLength: 131_072,
        slidingWindow: 4096
    )

    static func record(
        id: String = "fixture",
        weights: Int64,
        projector: Int64 = 0,
        contextLength: Int = 32_768,
        dimensions: GGUFModelDimensions? = nil
    ) -> ModelRecord {
        ModelRecord(
            id: id,
            displayName: id,
            repoID: "fixture/\(id)",
            filename: "\(id).gguf",
            parameters: "n/a",
            quantization: "Q4_K_M",
            sizeBytes: weights,
            contextLength: contextLength,
            license: "n/a",
            projectorFilename: projector > 0 ? "mmproj-\(id).gguf" : nil,
            projectorSizeBytes: projector,
            ggufDimensions: dimensions
        )
    }
}

@Suite("Memory estimate")
struct MemoryEstimateTests {

    /// An iPhone 14: 6 GB physical, no increased-memory-limit entitlement.
    private let iPhone14 = DeviceBudget(physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
                                        hasIncreasedMemoryLimit: false)

    @Test("the KV cache is linear in context")
    func kvCacheScalesWithContext() {
        let model = ModelShapes.record(weights: 2_020_000_000, dimensions: ModelShapes.llama3B)

        let short = model.memoryEstimate(atContext: 2048)
        let long = model.memoryEstimate(atContext: 32_768)

        #expect(long.kvCacheBytes == short.kvCacheBytes * 16)
        #expect(long.kvCacheBytesPerToken == short.kvCacheBytesPerToken)
        // 28 layers × 8 KV heads × (128 + 128) × 2 bytes, per token.
        #expect(short.kvCacheBytesPerToken == 114_688)
        // Nothing else moved: only the cache is a function of context.
        #expect(long.weightsBytes == short.weightsBytes)
        #expect(long.computeBufferBytes == short.computeBufferBytes)
    }

    @Test("a 3B model at 32K needs gigabytes more than at 2K")
    func longContextCostsGigabytes() {
        // The regression that would have caught the bug. The old estimate was
        // `size × 1.25 + 192 MB` — one number for every context — and it read
        // as loadable on a 6 GB phone at every one of them.
        let model = ModelShapes.record(weights: 2_020_000_000, dimensions: ModelShapes.llama3B)
        let old = Int64(Double(model.sizeBytes) * 1.25) + 192 * 1024 * 1024

        let short = model.memoryEstimate(atContext: 2048)
        let long = model.memoryEstimate(atContext: 32_768)

        #expect(long.totalBytes > short.totalBytes + 3 * 1024 * 1024 * 1024)
        #expect(long.kvCacheBytes > 3 * 1024 * 1024 * 1024, "the cache alone outweighs the weights at 32K")

        #expect(old <= iPhone14.usableBytes, "the old estimate said this loads")
        #expect(long.totalBytes > iPhone14.usableBytes, "and at 32K it does not")
        #expect(iPhone14.fit(for: model, contextTokens: 32_768) == .willNotFit)
    }

    @Test("comfortable at 4K, killed at 32K, on the same phone")
    func verdictChangesWithContext() {
        let model = ModelShapes.record(weights: 900_000_000, dimensions: ModelShapes.small)

        #expect(iPhone14.fit(for: model, contextTokens: 4096) == .comfortable)
        #expect(iPhone14.fit(for: model, contextTokens: 32_768) == .willNotFit)

        // And the refusal comes with the number that explains it, because
        // "will not fit" is not an answer someone can act on.
        let shortfall = iPhone14.shortfall(for: model.memoryEstimate(atContext: 32_768))
        #expect(shortfall > 2 * 1024 * 1024 * 1024)
        #expect(iPhone14.shortfall(for: model.memoryEstimate(atContext: 4096)) == 0)
    }

    @Test("a sliding window stops the cache growing")
    func slidingWindowClamps() {
        // Gemma attends to a fixed window, so llama.cpp never allocates a cache
        // longer than one. Charging it for the full context would refuse a
        // model that loads — the same error as the bug, pointed the other way.
        let model = ModelShapes.record(weights: 2_489_757_856,
                                       contextLength: 131_072,
                                       dimensions: ModelShapes.slidingWindow)

        let atWindow = model.memoryEstimate(atContext: 4096)
        let past = model.memoryEstimate(atContext: 32_768)

        #expect(past.effectiveContextTokens == 4096)
        #expect(past.kvCacheBytes == atWindow.kvCacheBytes)
        #expect(past.totalBytes == atWindow.totalBytes)
        #expect(model.memoryEstimate(atContext: 131_072).totalBytes == atWindow.totalBytes)

        // Below the window it still scales, or the clamp is just a ceiling
        // pretending to be a model.
        #expect(model.memoryEstimate(atContext: 2048).kvCacheBytes == atWindow.kvCacheBytes / 2)
    }

    @Test("the projector is resident too")
    func projectorIsCounted() {
        let text = ModelShapes.record(weights: 2_489_757_856, dimensions: ModelShapes.slidingWindow)
        let vision = ModelShapes.record(weights: 2_489_757_856,
                                        projector: 851_251_104,
                                        dimensions: ModelShapes.slidingWindow)

        #expect(vision.memoryEstimate(atContext: 4096).totalBytes
                > text.memoryEstimate(atContext: 4096).totalBytes + 851_251_104)
    }

    @Test("without a header the estimate is a guess, and says so")
    func fallbackIsFlagged() {
        let model = ModelShapes.record(weights: 2_020_000_000, projector: 100_000_000)
        let estimate = model.memoryEstimate(atContext: 8192)

        #expect(estimate.basis == .estimated)
        #expect(estimate.isMeasured == false)
        // Byte for byte what it was before any of this existed, so a catalogue
        // entry nobody has downloaded reads exactly as it always did.
        #expect(estimate.totalBytes == Int64(Double(2_020_000_000 + 100_000_000) * 1.25) + 192 * 1024 * 1024)
        // A guess cannot price context, and must not be read as pricing it at
        // nothing: `basis` is the field that says which.
        #expect(estimate.kvCacheBytes == 0)
        #expect(model.memoryEstimate(atContext: 32_768).totalBytes == estimate.totalBytes)
    }

    @Test("metadata that cannot be true is not believed")
    func invalidDimensionsFallBack() {
        // A manifest written by a build whose reader had a bug decodes
        // perfectly and describes nothing. Zero layers prices the cache at zero
        // bytes, which reads as "fits" for every model on every device.
        var broken = ModelShapes.llama3B
        broken.blockCount = 0
        let model = ModelShapes.record(weights: 2_020_000_000, dimensions: broken)

        #expect(broken.isValid == false)
        #expect(model.memoryEstimate(atContext: 32_768).basis == .estimated)
        #expect(iPhone14.fit(for: model, contextTokens: 32_768) == .tight,
                "the flat guess, not a cache priced at nothing")
    }

    @Test("an absurd context cannot overflow the arithmetic")
    func clampsHostileContexts() {
        let model = ModelShapes.record(weights: 2_020_000_000, dimensions: ModelShapes.llama3B)

        // The context arrives from a slider and, through a persisted
        // configuration, from whatever an older build wrote there.
        #expect(model.memoryEstimate(atContext: .max).totalBytes > 0)
        #expect(model.memoryEstimate(atContext: -1).contextTokens == 1)
        #expect(model.memoryEstimate(atContext: 0).kvCacheBytes > 0)
    }

    @Test("the whole path, from a file on disk to a verdict")
    func endToEnd() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("estimate-\(UUID().uuidString).gguf")
        try GGUFModelDimensionsTests.header(keys: GGUFModelDimensionsTests.qwen3Keys).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let downloaded = ModelShapes.record(weights: 1_107_409_472)
            .readingDimensions(fromFileAt: url)

        #expect(downloaded.memoryEstimate(atContext: 4096).isMeasured)
        #expect(iPhone14.fit(for: downloaded, contextTokens: 4096) != .willNotFit)
        #expect(iPhone14.fit(for: downloaded, contextTokens: 32_768) == .willNotFit)
    }

    @Test("a file whose header cannot be read leaves the record as it was")
    func unreadableFileChangesNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("estimate-\(UUID().uuidString).gguf")
        try Data(repeating: 0xFF, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // A half-downloaded or truncated file must leave the guess in place
        // rather than produce a shape, and must not be an error anyone sees.
        let model = ModelShapes.record(weights: 1_107_409_472)
        #expect(model.readingDimensions(fromFileAt: url) == model)
        #expect(model.readingDimensions(fromFileAt: URL(fileURLWithPath: "/nope.gguf")) == model)
    }
}

@Suite("Largest fitting context")
struct FittingContextTests {

    private let iPhone14 = DeviceBudget(physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
                                        hasIncreasedMemoryLimit: false)

    @Test("the answer is a context that actually loads, and the next one up is not")
    func largestContextIsLoadable() throws {
        let model = ModelShapes.record(weights: 900_000_000,
                                       contextLength: 32_768,
                                       dimensions: ModelShapes.small)

        let largest = try #require(iPhone14.largestFittingContext(for: model))

        #expect(iPhone14.fit(for: model, contextTokens: largest).allowsDownload)
        #expect(iPhone14.fit(for: model, contextTokens: largest + MemoryEstimate.contextGranularity) == .willNotFit,
                "the search stopped short of the real ceiling")
        #expect(largest % MemoryEstimate.contextGranularity == 0)
        #expect(largest < model.contextLength)
    }

    @Test("a model that fits at its full window says so")
    func fullWindowFits() {
        let model = ModelShapes.record(weights: 386_000_000,
                                       contextLength: 8192,
                                       dimensions: ModelShapes.small)

        #expect(iPhone14.largestFittingContext(for: model) == 8192)
    }

    @Test("a model that fits at no context at all returns nothing")
    func nothingFits() {
        let model = ModelShapes.record(weights: 19_000_000_000, dimensions: ModelShapes.llama3B)

        #expect(iPhone14.largestFittingContext(for: model) == nil)
        #expect(iPhone14.fittingContextTiers(for: model).isEmpty)
    }

    @Test("only tiers that load are offered")
    func tiersAreLoadable() {
        let model = ModelShapes.record(weights: 900_000_000,
                                       contextLength: 32_768,
                                       dimensions: ModelShapes.small)

        let tiers = iPhone14.fittingContextTiers(for: model)
        #expect(tiers.isEmpty == false)
        #expect(tiers.contains(32_768) == false)
        for tier in tiers {
            #expect(iPhone14.fit(for: model, contextTokens: tier).allowsDownload, "\(tier) was offered and cannot load")
        }
    }

    @Test("a sliding-window model is offered its whole window")
    func slidingWindowModelsGetEverything() {
        // Past the window the cache stops growing, so if any long context fits,
        // all of them do. A picker that hid 32K here would be inventing a
        // limit the model does not have.
        let model = ModelShapes.record(weights: 1_200_000_000,
                                       contextLength: 131_072,
                                       dimensions: ModelShapes.slidingWindow)

        #expect(iPhone14.largestFittingContext(for: model) == 131_072)
        #expect(iPhone14.fittingContextTiers(for: model) == MemoryEstimate.contextTiers)
    }

    @Test("the search respects what the weights were trained for")
    func honoursTrainedWindow() {
        // The catalogue's context length is written by hand and has been wrong
        // before. Allocating a cache longer than the weights can attend to
        // spends memory on nothing.
        let model = ModelShapes.record(weights: 386_000_000,
                                       contextLength: 131_072,
                                       dimensions: ModelShapes.small)

        #expect(model.supportedContextLength == 32_768)
        #expect((iPhone14.largestFittingContext(for: model) ?? 0) <= 32_768)
    }
}

@Suite("Estimates without metadata are unchanged")
struct EstimateCompatibilityTests {

    /// The catalogue carries no dimensions — a header cannot be read over the
    /// network — so every verdict it produces has to be the one it produced
    /// before context entered the estimate. This is the promise that lets the
    /// change ship without re-auditing the download gate.
    @Test("every catalogue entry still estimates exactly as it did")
    func catalogueUnchanged() {
        for model in ModelCatalog.all {
            let old = Int64(Double(model.sizeBytes + model.projectorSizeBytes) * 1.25) + 192 * 1024 * 1024
            #expect(model.estimatedResidentBytes == old, "\(model.id) changed without anyone reading its header")
            #expect(model.memoryEstimate(atContext: 4096).basis == .estimated)
        }
    }

    @Test("the default context is what this phone serves, not what the model advertises")
    func defaultContextIsTheServedWindow() {
        // The trap this exists to prevent: charging a model's KV cache at its
        // declared window. Llama 3.2 1B advertises 131,072, which costs 5.5 GiB
        // of cache — so defaulting to the declared number refuses a model that
        // needs 1.24 GiB at the 4K it is actually run at. The cache is sized by
        // the context the engine creates, and nothing else.
        let budget = DeviceBudget(
            physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
            hasIncreasedMemoryLimit: false,
            servedContextTokens: 4096
        )
        let model = ModelShapes.record(weights: 900_000_000, contextLength: 131_072, dimensions: ModelShapes.small)

        #expect(budget.fit(for: model) == budget.fit(for: model, contextTokens: 4096))
        #expect(budget.fit(for: model) > budget.fit(for: model, contextTokens: model.contextLength))
    }

    @Test("a model whose own window is shorter than the served context is charged for the shorter one")
    func servedContextIsClampedToTheModel() {
        // A 2K model in a phone configured for 8K can only ever hold 2K of
        // cache, and charging it for 8K would be the same over-refusal in the
        // other direction.
        let budget = DeviceBudget(
            physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
            hasIncreasedMemoryLimit: false,
            servedContextTokens: 8192
        )
        let model = ModelShapes.record(weights: 900_000_000, contextLength: 2048, dimensions: ModelShapes.small)

        #expect(budget.fit(for: model) == budget.fit(for: model, contextTokens: 2048))
    }

    @Test("raising the context limit can take a model out of reach")
    func raisingTheLimitChangesTheVerdict() {
        // This is the whole point of threading the served context through: the
        // Settings stepper moves the memory ceiling, and the badges have to
        // follow it. Before this, the estimate was a constant and the stepper
        // silently changed what would actually load without changing what the
        // app claimed would load.
        let model = ModelShapes.record(weights: 2_000_000_000, contextLength: 131_072, dimensions: ModelShapes.small)
        func verdict(at context: Int) -> DeviceBudget.Fit {
            DeviceBudget(
                physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
                hasIncreasedMemoryLimit: true,
                servedContextTokens: context
            ).fit(for: model)
        }
        #expect(verdict(at: 2048) > verdict(at: 32_768))
    }

    @Test("dimensions survive the manifest round trip")
    func dimensionsRoundTrip() throws {
        let model = ModelShapes.record(weights: 900_000_000, dimensions: ModelShapes.small)
        let decoded = try JSONDecoder().decode(ModelRecord.self, from: JSONEncoder().encode(model))

        #expect(decoded.ggufDimensions == ModelShapes.small)
        #expect(decoded == model)
    }
}
