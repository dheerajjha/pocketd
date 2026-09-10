import Foundation

/// The sampler, as a value.
///
/// Deliberately not `GenerationOptions`, which is the wire shape: all-optional,
/// "what did this particular caller actually say". An engine needs the opposite
/// — a complete set with no holes — because it has to answer one question per
/// request: *is this the sampler I already have?* llama.cpp binds its sampler
/// chain to the context when the context is built, so the answer decides
/// between doing nothing and rebuilding the whole thing. `Equatable` is not
/// decoration here; it is the mechanism that keeps the common case — every
/// request arriving with the same settings — free.
///
/// The defaults are llama.cpp's own, taken from `common_params_sampling` in
/// `common/common.h`, so that a request naming no sampling field gets what
/// `llama-server` with no flags would give it. That deliberately differs from
/// LocalLLMClient's `Parameter` defaults in one place: the repetition penalty,
/// which llama.cpp leaves at 1.0 (disabled) and LocalLLMClient sets to 1.1.
/// pocketd used to inherit 1.1 by never setting the field at all. Following
/// llama.cpp means the number in the README is the number in the sampler.
public struct SamplingParameters: Sendable, Equatable, Codable {
    /// Lower is more deterministic. Zero is greedy decoding: llama.cpp's
    /// temperature sampler keeps the highest logit and sets the rest to `-inf`
    /// whenever `t <= 0`, which is exactly what a client asking for
    /// `temperature: 0` means by it.
    public var temperature: Double
    /// Nucleus sampling. Note that LocalLLMClient also derives llama.cpp's
    /// `min_p` from this as `1 - topP`, so lowering it filters harder than the
    /// same number would on `llama-server`; there is no separate `min_p` to
    /// set, which is why the routes refuse one rather than pretend.
    public var topP: Double
    /// Keep only the K most likely tokens. `0` means the whole vocabulary.
    public var topK: Int
    /// Locally typical sampling. `1.0` disables it.
    public var typicalP: Double
    /// Multiplier applied to tokens already seen. `1.0` disables it.
    public var repeatPenalty: Double
    /// How far back `repeatPenalty` looks. `-1` means the whole context.
    public var repeatLastN: Int
    /// The RNG seed, or `nil` for a fresh random one per generation.
    ///
    /// llama.cpp seeds the distribution sampler once, when the chain is built,
    /// and the generator advances it from there — so a fixed seed reproduces an
    /// answer only against a sampler that has not sampled anything yet. That
    /// makes an explicit seed the one parameter whose rebuild cannot be skipped
    /// on equality; see `pinsRandomness`.
    public var seed: UInt64?

    public init(
        temperature: Double = 0.8,
        topP: Double = 0.95,
        topK: Int = 40,
        typicalP: Double = 1.0,
        repeatPenalty: Double = 1.0,
        repeatLastN: Int = 64,
        seed: UInt64? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.typicalP = typicalP
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.seed = seed
    }

    /// llama.cpp's defaults, unchanged.
    public static let `default` = SamplingParameters()

    /// Whether honouring this request means rebuilding even against an
    /// identical resident sampler.
    ///
    /// A seed that is not `nil` is a promise of reproducibility, and the only
    /// way to keep it is a sampler whose RNG is back where it started. Skipping
    /// the rebuild here would make the second identical seeded request answer
    /// differently from the first — precisely the thing a seed exists to rule
    /// out, and a failure no client could detect from the outside.
    public var pinsRandomness: Bool { seed != nil }

    /// These parameters with whatever the caller actually named laid over them.
    ///
    /// The base carries the server's configured defaults, so a request that
    /// names only `temperature` keeps the operator's `top_p` rather than
    /// silently reverting it to llama.cpp's. That is how `llama-server` merges
    /// its CLI flags with a request body, and clients are written against it.
    ///
    /// Values arrive here straight off an untrusted socket, so this is also the
    /// clamp. It is a narrow one on purpose — only where the alternative is a
    /// crash or an unobservable difference:
    ///
    /// * `topK` and `repeatLastN` are handed to llama.cpp as `Int32`, and
    ///   LocalLLMClient converts with a trapping initialiser. A client sending
    ///   `"top_k": 99999999999` would take the process down, taking every other
    ///   client's connection with it.
    /// * A non-finite `temperature` poisons the whole logit array, so `NaN` is
    ///   read as "said nothing" rather than propagated.
    /// * Negative temperatures clamp to zero, which llama.cpp already treats as
    ///   identical, so nothing observable is being taken away.
    public func overriding(_ options: GenerationOptions) -> SamplingParameters {
        var merged = self
        if let temperature = options.temperature, temperature.isFinite {
            merged.temperature = max(0, temperature)
        }
        if let topP = options.topP, topP.isFinite {
            merged.topP = min(max(0, topP), 1)
        }
        if let topK = options.topK {
            merged.topK = min(max(0, topK), Int(Int32.max))
        }
        if let repeatPenalty = options.repeatPenalty, repeatPenalty.isFinite {
            merged.repeatPenalty = max(0, repeatPenalty)
        }
        if let seed = options.seed {
            merged.seed = seed
        }
        return merged
    }
}

public extension GenerationRequest {
    /// The sampler this request actually asks for.
    ///
    /// Every engine resolves through here rather than merging for itself, so
    /// that `EchoEngine` and `LlamaEngine` cannot answer the same request
    /// differently — the whole value of the tests below the HTTP layer rests on
    /// them agreeing.
    ///
    /// - Parameter defaults: what the engine is configured with, used for every
    ///   field the caller left unset.
    func resolvedSampling(defaults: SamplingParameters = .default) -> SamplingParameters {
        (sampling ?? defaults).overriding(options)
    }
}
