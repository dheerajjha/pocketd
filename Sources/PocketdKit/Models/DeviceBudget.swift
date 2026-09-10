import Foundation

/// How much memory this process may actually use before the kernel kills it.
///
/// iOS does not publish this number. What it publishes is total physical RAM,
/// which is roughly double what a single app is allowed to touch, and reporting
/// that to a user is how a "fits comfortably" badge turns into a jetsam crash.
/// The fractions below are conservative on purpose.
public struct DeviceBudget: Sendable, Equatable {
    public var physicalMemoryBytes: Int64
    /// True when the app ships `com.apple.developer.kernel.increased-memory-limit`.
    public var hasIncreasedMemoryLimit: Bool

    /// The context length this phone is configured to serve.
    ///
    /// Not the model's declared window, which is the trap: Llama 3.2 1B
    /// advertises 131,072 and charging its KV cache at that length needs
    /// 5.5 GiB, so a model that runs comfortably in 1.24 GiB at the 4K we
    /// actually serve would be refused outright. The number that governs the
    /// cache is the one the context is created with, and that is this.
    public var servedContextTokens: Int = 4096

    public init(
        physicalMemoryBytes: Int64,
        hasIncreasedMemoryLimit: Bool,
        servedContextTokens: Int = 4096
    ) {
        self.servedContextTokens = servedContextTokens
        self.physicalMemoryBytes = physicalMemoryBytes
        self.hasIncreasedMemoryLimit = hasIncreasedMemoryLimit
    }

    public static func current(
        hasIncreasedMemoryLimit: Bool,
        servedContextTokens: Int = 4096
    ) -> DeviceBudget {
        DeviceBudget(
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            hasIncreasedMemoryLimit: hasIncreasedMemoryLimit,
            servedContextTokens: servedContextTokens
        )
    }

    /// Bytes this app can reasonably hold resident.
    public var usableBytes: Int64 {
        let fraction = hasIncreasedMemoryLimit ? 0.58 : 0.45
        return Int64(Double(physicalMemoryBytes) * fraction)
    }

    /// Ordered worst to best, so a caller can ask for "at least tight" rather
    /// than enumerating the two verdicts that satisfy it.
    public enum Fit: Sendable, Equatable, Comparable {
        /// Will be killed by the kernel. Downloading it is wasted bandwidth.
        case willNotFit
        /// Loads, but leaves little room for anything else the phone is doing.
        case tight
        case comfortable

        public var allowsDownload: Bool { self != .willNotFit }
    }

    /// The verdict at a given context length.
    ///
    /// The context is the parameter that used to be missing, and it is the one
    /// that decides the answer: the same 3B model needs 2.6 GB at 2K and 6.2 GB
    /// at 32K, which is the difference between a phone that serves it and a
    /// phone that dies allocating the cache.
    ///
    /// Passing `nil` charges the model for the whole window it declares, which
    /// is the safe direction and the wrong one for most callers — see
    /// `ModelRecord.estimatedResidentBytes`. Pass the context that will
    /// actually be served.
    public func fit(for model: ModelRecord, contextTokens: Int? = nil) -> Fit {
        // A model is never run past the context this server creates, so
        // charging it for more cache than that can ever hold refuses models
        // that work.
        fit(for: model.memoryEstimate(
            atContext: contextTokens ?? min(model.contextLength, servedContextTokens)
        ))
    }

    public func fit(for estimate: MemoryEstimate) -> Fit {
        let needed = estimate.totalBytes
        if needed <= Int64(Double(usableBytes) * 0.7) { return .comfortable }
        if needed <= usableBytes { return .tight }
        return .willNotFit
    }

    /// How far over the limit a configuration is, in bytes; zero when it fits.
    ///
    /// This is what turns a refusal into an explanation. "32K context needs
    /// 2.1 GB more than this phone has" tells someone what to change; "will not
    /// fit" tells them to give up on a model that runs perfectly at 8K.
    public func shortfall(for estimate: MemoryEstimate) -> Int64 {
        max(0, estimate.totalBytes - usableBytes)
    }

    /// The longest context this model can be loaded with here, rounded down to
    /// `MemoryEstimate.contextGranularity`, or `nil` if even the shortest
    /// context is over budget.
    ///
    /// Offering a context tier that cannot be allocated is the bug in a
    /// different costume: the picker is where a user chooses 32K, and it should
    /// not list a choice that kills the process.
    ///
    /// - Parameter allowing: the worst verdict still counted as fitting.
    ///   `.tight` by default, matching the download gate — a model that loads
    ///   with little headroom is still a model that loads.
    public func largestFittingContext(for model: ModelRecord, allowing worstAcceptable: Fit = .tight) -> Int? {
        let step = MemoryEstimate.contextGranularity
        let ceiling = model.supportedContextLength

        func fits(_ context: Int) -> Bool { fit(for: model, contextTokens: context) >= worstAcceptable }

        // A window narrower than one step is all-or-nothing, and a manifest
        // claiming no window at all has no answer to give.
        guard ceiling > step else { return ceiling > 0 && fits(ceiling) ? ceiling : nil }
        // Both ends first, because for most models one of them is the answer.
        // Every estimate with no metadata behind it lands here: the flat guess
        // does not vary with context, so there is no context to search for.
        guard fits(step) else { return nil }
        if fits(ceiling) { return ceiling }

        // Memory needed only ever rises with context, so bisect. In steps
        // rather than tokens, because the answer is going to be rounded to one
        // anyway and a search that lands on 7,937 has spent iterations earning
        // a digit nobody should read.
        var fitting = 1
        var failing = ceiling / step
        while failing - fitting > 1 {
            let middle = (fitting + failing) / 2
            if fits(middle * step) { fitting = middle } else { failing = middle }
        }
        return fitting * step
    }

    /// The subset of `MemoryEstimate.contextTiers` this device can actually
    /// load this model with. Empty means the model does not fit at any context,
    /// which is a different sentence for the UI than "pick a smaller one".
    public func fittingContextTiers(for model: ModelRecord, allowing worstAcceptable: Fit = .tight) -> [Int] {
        guard let largest = largestFittingContext(for: model, allowing: worstAcceptable) else { return [] }
        return MemoryEstimate.contextTiers.filter { $0 <= largest }
    }
}
