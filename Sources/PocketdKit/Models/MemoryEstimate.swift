import Foundation

/// What a model will occupy once llama.cpp has loaded it at a particular
/// context length.
///
/// The context length is the whole point. The estimate this replaced was a flat
/// 25% of the file size plus 192 MB, which is a fair description of a model
/// serving 2K tokens and a fiction at 32K: the KV cache is linear in context,
/// and on a 3B model at 32K it is 3.5 GB — more than the weights. So the badge
/// said "Fits", the user picked 32K in Settings, and the kernel killed the
/// process while the cache was being allocated. There is no crash dialog for
/// that, and because this app is an inference server, what the user actually
/// sees is a laptop whose connection dropped mid-answer.
///
/// The arithmetic is PocketPal's (`src/utils/memoryEstimator.ts`), which is in
/// turn llama.cpp's own accounting reduced to the three terms that dominate on
/// a phone: the weights, the KV cache, and the compute buffer that holds one
/// logits row per batched token. Everything else llama.cpp allocates is small
/// and awkward to predict, and is charged as a flat 10%.
///
/// Every term is kept separately because the UI has to explain the trade-off,
/// not just refuse: "32K needs 2.1 GB more than this phone has, 8K fits" is
/// only sayable if the KV term is a number rather than an ingredient.
public struct MemoryEstimate: Sendable, Equatable {

    /// Whether this is arithmetic or a guess.
    ///
    /// Two very different claims, and the UI must not present them the same
    /// way. `measured` comes from the model's own header and is worth refusing
    /// a download over; `estimated` is a percentage of the file size that knows
    /// nothing about the context at all, and can only be worth a hedge.
    public enum Basis: Sendable, Equatable {
        /// Computed from dimensions read out of the model's GGUF header.
        case measured
        /// The old flat heuristic, because the header was unreadable, has not
        /// been read yet, or did not survive validation.
        case estimated
    }

    /// The context the caller asked about.
    public let contextTokens: Int
    /// The context the KV cache is actually sized by. Smaller than
    /// `contextTokens` only on sliding-window models.
    public let effectiveContextTokens: Int
    public let weightsBytes: Int64
    public let kvCacheBytes: Int64
    public let computeBufferBytes: Int64
    /// The multimodal projector, resident for as long as the model is.
    public let projectorBytes: Int64
    /// llama.cpp's own allocations — graph, scratch buffers, the Metal command
    /// queue — as a fraction of everything above.
    public let overheadBytes: Int64
    public let basis: Basis

    public var totalBytes: Int64 {
        weightsBytes + kvCacheBytes + computeBufferBytes + projectorBytes + overheadBytes
    }

    /// True when this came out of the model's own header rather than a guess.
    /// Callers that word a warning should check it: "needs 4.2 GB" and "needs
    /// roughly 4.2 GB" are different promises.
    public var isMeasured: Bool { basis == .measured }

    /// Bytes the KV cache costs for each token of context. Zero when the
    /// estimate is a guess, which is exactly the information a caller needs
    /// before offering to trade context for headroom.
    public var kvCacheBytesPerToken: Int64 {
        effectiveContextTokens > 0 ? kvCacheBytes / Int64(effectiveContextTokens) : 0
    }

    private init(
        contextTokens: Int,
        effectiveContextTokens: Int,
        weightsBytes: Int64,
        kvCacheBytes: Int64,
        computeBufferBytes: Int64,
        projectorBytes: Int64,
        overheadBytes: Int64,
        basis: Basis
    ) {
        self.contextTokens = contextTokens
        self.effectiveContextTokens = effectiveContextTokens
        self.weightsBytes = weightsBytes
        self.kvCacheBytes = kvCacheBytes
        self.computeBufferBytes = computeBufferBytes
        self.projectorBytes = projectorBytes
        self.overheadBytes = overheadBytes
        self.basis = basis
    }

    /// The one entry point, so nothing can compute a measured estimate from
    /// dimensions that were never validated.
    public init(
        weightsBytes: Int64,
        projectorBytes: Int64,
        dimensions: GGUFModelDimensions?,
        contextTokens: Int
    ) {
        // Clamped, not trusted: the context arrives from a settings slider and,
        // via a persisted configuration, from whatever an older build wrote
        // there. The ceiling is the same one `GGUFModelDimensions.isValid`
        // enforces, and together they keep every product below Int64.
        let requested = min(max(contextTokens, 1), Self.maximumContext)

        guard let dimensions, dimensions.isValid else {
            self.init(fallbackWeightsBytes: weightsBytes, projectorBytes: projectorBytes, contextTokens: requested)
            return
        }

        // Sliding-window attention never looks further back than the window,
        // so llama.cpp does not keep a cache longer than one: past the window,
        // raising the context is free. Gemma is the model that matters here.
        //
        // Optimistic on Gemma 3 specifically, and knowingly so: it interleaves
        // five local layers with one global one, and the global layers do keep
        // a full-length cache. At 32K that is a few hundred megabytes this does
        // not charge for. The alternative — charging every layer for the full
        // context — is wrong by four gigabytes in the direction that refuses a
        // model which loads fine, and the per-layer pattern is not a key this
        // reader can read. Revisit if a Gemma is ever reported jetsammed at a
        // context this called safe.
        let effective = min(requested, dimensions.slidingWindow ?? requested)

        let kvPerToken = Int64(dimensions.blockCount)
            * Int64(dimensions.headCountKV)
            * (Int64(dimensions.keyLength) + Int64(dimensions.valueLength))
            * Self.kvCacheBytesPerElement
        let kvCache = kvPerToken * Int64(effective)
        let computeBuffer = (Int64(dimensions.vocabularySize) + Int64(dimensions.embeddingLength))
            * Self.physicalBatchTokens
            * Self.bytesPerLogit

        self.init(
            contextTokens: requested,
            effectiveContextTokens: effective,
            weightsBytes: weightsBytes,
            kvCacheBytes: kvCache,
            computeBufferBytes: computeBuffer,
            projectorBytes: projectorBytes,
            // The projector is charged the same overhead as everything else,
            // which is what PocketPal does: it is another set of weights and
            // another set of graph buffers.
            overheadBytes: Self.overhead(on: weightsBytes + kvCache + computeBuffer + projectorBytes),
            basis: .measured
        )
    }

    /// The estimate from before any of this existed: a flat fraction of the
    /// bytes on disk, plus a fixed allowance for the runtime.
    ///
    /// Kept, and kept honest by `basis`, because the header is only readable
    /// once the file is on the device — which is precisely when the question
    /// "should I download this?" has already been answered. It is right to
    /// within a few hundred megabytes at the 2K–4K contexts this app serves by
    /// default and knows nothing about anything longer.
    private init(fallbackWeightsBytes weightsBytes: Int64, projectorBytes: Int64, contextTokens: Int) {
        let total = Int64(Double(weightsBytes + projectorBytes) * Self.heuristicMultiplier) + Self.heuristicRuntimeBytes
        self.init(
            contextTokens: contextTokens,
            effectiveContextTokens: contextTokens,
            weightsBytes: weightsBytes,
            // Not "the cache is free" — "nobody measured the cache". `basis`
            // is the field that says which, and a caller that reads this one
            // without reading that one is asking the wrong question.
            kvCacheBytes: 0,
            computeBufferBytes: 0,
            projectorBytes: projectorBytes,
            // Everything the guess cannot separate lands here rather than being
            // spread across terms it did not actually measure.
            overheadBytes: total - weightsBytes - projectorBytes,
            basis: .estimated
        )
    }
}

public extension MemoryEstimate {

    /// Two bytes per element, because llama.cpp's KV cache defaults to F16 and
    /// this app never says otherwise: LocalLLMClient builds its context from
    /// `llama_context_default_params()` and sets only `n_ctx` and the thread
    /// counts, so `type_k` and `type_v` stay at `GGML_TYPE_F16`. Quantising the
    /// cache would roughly halve this term — and would have to be changed here
    /// on the same day it is changed there.
    static let kvCacheBytesPerElement: Int64 = 2

    /// `n_ubatch`, the physical batch llama.cpp sizes its compute buffer for,
    /// at its default of 512. LocalLLMClient allocates its own `llama_batch` at
    /// 512 and never touches `ctx_params.n_ubatch`, so the default is what the
    /// buffer is actually sized for.
    static let physicalBatchTokens: Int64 = 512

    /// The logits row is F32, one float per vocabulary entry.
    static let bytesPerLogit: Int64 = 4

    /// Graph, scratch and Metal allocations, as a fraction of the rest.
    static let runtimeOverhead = 1.1

    /// The context-blind fallback: what the estimate was before this type, and
    /// what it still is until a model's header has been read.
    static let heuristicMultiplier = 1.25
    static let heuristicRuntimeBytes: Int64 = 192 * 1024 * 1024

    /// Contexts worth offering in a picker. The ceiling matches the Settings
    /// slider's, which stops at 32768 because past that a phone runs out of
    /// memory long before the weights run out of window.
    static let contextTiers = [512, 1024, 2048, 4096, 8192, 16384, 32768]

    /// The step `largestFittingContext` reports in. A tier of 7,936 tokens is
    /// noise: it reads as precision this estimate does not have, and the
    /// difference from 7,680 is a rounding error in the same term.
    static let contextGranularity = 256

    /// A ceiling on any context this will do arithmetic with. No weights
    /// declare a window near it; it exists so a corrupt setting cannot turn a
    /// multiplication into an overflow.
    static let maximumContext = 1 << 24

    private static func overhead(on bytes: Int64) -> Int64 {
        Int64(Double(bytes) * (runtimeOverhead - 1))
    }
}

public extension ModelRecord {

    /// What this model needs resident, if it is loaded with this much context.
    ///
    /// Ask with the context that will actually be served —
    /// `min(model.contextLength, configuration.maxContextTokens)` — not with
    /// the declared window. Several catalogue entries declare 128K and are
    /// served at 4K, and charging them for the window they will never allocate
    /// refuses models that would have loaded fine.
    func memoryEstimate(atContext contextTokens: Int) -> MemoryEstimate {
        MemoryEstimate(
            weightsBytes: sizeBytes,
            projectorBytes: projectorSizeBytes,
            dimensions: ggufDimensions,
            contextTokens: contextTokens
        )
    }

    /// This record with its shape filled in from the file on disk, unchanged if
    /// the header cannot be read.
    ///
    /// Call it once, where a download finishes: mapping the file is cheap but
    /// not free, and the answer never changes. Until something does, every
    /// estimate for this model is the flat guess — the honest answer for a
    /// model nobody has looked at, and the wrong one to leave in place for a
    /// model already sitting on the disk.
    func readingDimensions(fromFileAt url: URL) -> ModelRecord {
        guard let dimensions = GGUFModelDimensions.read(fromFileAt: url) else { return self }
        var updated = self
        updated.ggufDimensions = dimensions
        return updated
    }

    /// The longest context this model's own weights support: the catalogue's
    /// number, or the header's when it is smaller. The catalogue is written by
    /// hand and has been wrong before, and asking llama.cpp for more context
    /// than the weights were trained for wastes memory on a cache the model
    /// cannot attend to.
    var supportedContextLength: Int {
        guard let declared = ggufDimensions?.trainedContextLength, ggufDimensions?.isValid == true else {
            return contextLength
        }
        return min(contextLength, declared)
    }
}
