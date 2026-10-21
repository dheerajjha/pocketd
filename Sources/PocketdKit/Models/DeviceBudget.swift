import Foundation

/// How much memory this app may hold resident, and whether a given model fits
/// inside it.
///
/// There are two memory questions and they are not the same question. This type
/// keeps them apart:
///
/// 1. **Does this model fit on this device?** A property of the hardware and
///    the entitlement, and therefore a constant for as long as the app is
///    installed. It is `fit(for:)`, and it is what the Models tab badges every
///    row with.
/// 2. **Is there room right now?** A property of this instant, which moves
///    every time anything is allocated — including by this app, doing the thing
///    it exists to do. It is `pressure`, it has its own words, and it never
///    reaches a fit badge.
///
/// Collapsing the two is the bug this shape exists to prevent, and it shipped.
/// `usableBytes` used to prefer whatever had been learned from
/// `os_proc_available_memory()` and from the last successful load, so the
/// Models screen read "Usable memory 15.46 GB, everything Fits" on a fresh
/// launch and "683.8 MB, everything Too large" after loading SmolLM2 360M —
/// 683.8 MB being, exactly, SmolLM2's own estimate. The app had answered the
/// second question in the first question's badge, and so contradicted itself
/// the moment it did its job: the model running fine right then was labelled
/// too large to run.
///
/// So the verdict is arithmetic on numbers that do not move — physical RAM
/// times the fraction iOS allows one app — and the live reading is a separate
/// signal with a separate sentence.
public struct DeviceBudget: Sendable, Equatable {

    /// Where this build is running, because the simulator's numbers describe a
    /// Mac and its limits do not.
    ///
    /// Injected rather than read at the point of use so the Kit's tests — which
    /// compile for macOS, where `targetEnvironment(simulator)` is false — can
    /// exercise the simulator rules at all.
    public enum Environment: Sendable, Equatable {
        case device
        case simulator

        public static var current: Environment {
            #if targetEnvironment(simulator)
            .simulator
            #else
            .device
            #endif
        }
    }

    public var physicalMemoryBytes: Int64
    /// True when the app ships `com.apple.developer.kernel.increased-memory-limit`.
    public var hasIncreasedMemoryLimit: Bool
    public var environment: Environment

    /// The largest estimate that has actually loaded on this device, from
    /// `MemoryCalibration`.
    ///
    /// A **floor**, never a ceiling. A model that loaded here is proof this
    /// device holds at least that much, so it can only ever widen the budget;
    /// reading it as "and no more than that" is what collapsed the budget to
    /// the size of the last thing loaded. `nil` until a load has succeeded.
    public var provenLoadBytes: Int64?

    /// The most recent `os_proc_available_memory()` reading, or `nil` where
    /// there is no such number — every macOS build, every simulator.
    ///
    /// Feeds `pressure` and nothing else. It is deliberately not part of
    /// `usableBytes`: it drops by the size of whatever is resident, which makes
    /// any verdict computed from it a function of the app's own success.
    public var availableNowBytes: Int64?

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
        servedContextTokens: Int = 4096,
        environment: Environment = .current,
        provenLoadBytes: Int64? = nil,
        availableNowBytes: Int64? = nil
    ) {
        self.servedContextTokens = servedContextTokens
        self.physicalMemoryBytes = physicalMemoryBytes
        self.hasIncreasedMemoryLimit = hasIncreasedMemoryLimit
        self.environment = environment
        self.provenLoadBytes = provenLoadBytes
        self.availableNowBytes = availableNowBytes
    }

    /// The budget for this device, folding in what previous launches proved and
    /// taking a live reading for the pressure signal while it is here.
    public static func current(
        hasIncreasedMemoryLimit: Bool,
        servedContextTokens: Int = 4096,
        calibration: MemoryCalibration = .standard,
        available: AvailableMemory = .system,
        environment: Environment = .current
    ) -> DeviceBudget {
        // Launch is the cleanest this process is ever going to be, so the
        // reading is worth keeping as a high-water mark — even though nothing
        // about the verdict depends on it any more.
        let reading = available.bytes
        calibration.recordAvailableMemory(reading)
        return DeviceBudget(
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            hasIncreasedMemoryLimit: hasIncreasedMemoryLimit,
            servedContextTokens: servedContextTokens,
            environment: environment,
            provenLoadBytes: calibration.largestSuccessfulLoadBytes,
            availableNowBytes: reading
        )
    }

    // MARK: - The stable budget

    /// The share of physical RAM iOS lets one app dirty without the
    /// entitlement. Documented in the README, and the number the fit table
    /// there is computed from.
    public static let unentitledFraction = 0.45
    /// The same share with `com.apple.developer.kernel.increased-memory-limit`.
    public static let entitledFraction = 0.58
    /// Under this share of the budget a model is `.comfortable` rather than
    /// `.tight` — room for a conversation, a request log and a compute buffer
    /// on top of the weights.
    public static let comfortableFraction = 0.7

    /// The share of `verdictMemoryBytes` this app may hold. On the simulator,
    /// the share a shipping build gets: the simulator has no provisioning
    /// profile to read the entitlement from, and the phone it stands in for
    /// carries it.
    public var entitlementFraction: Double {
        hasIncreasedMemoryLimit || environment == .simulator ? Self.entitledFraction : Self.unentitledFraction
    }

    /// The RAM the verdicts are computed from: this phone's, or — on the
    /// simulator, where `ProcessInfo.physicalMemory` is the Mac's — the phone
    /// it stands in for (`simulatedPhoneMemoryBytes`).
    public var verdictMemoryBytes: Int64 {
        environment == .simulator ? Self.simulatedPhoneMemoryBytes : physicalMemoryBytes
    }

    /// Bytes this app can hold resident — physical RAM times the entitlement
    /// fraction, and nothing else that moves.
    ///
    /// No further reserve is subtracted here. The fraction *is* the reserve:
    /// 45% of a 6 GB phone is already less than half of it, chosen because that
    /// is roughly where iOS starts killing, and the README's table of which
    /// models fit which phone is computed from exactly this arithmetic.
    /// `MemoryCalibration.loadReserveBytes` is still held back where it belongs
    /// — from the live reading, which is what `pressure` reads — but taking it
    /// off the verdict as well would move two published rows (Llama 3.2 3B on a
    /// 6 GB phone, Qwen3 4B on an 8 GB one) and make the documentation false.
    ///
    /// A proven load raises it and never lowers it, capped at the RAM that
    /// physically exists so a proof recorded against an overstated catalogue
    /// size — this project has shipped one out by 1.3 GB — cannot invent
    /// memory.
    ///
    /// On the simulator a load proves nothing — there is no jetsam there, and
    /// a 3 GB brain loads on a Mac that no 8 GB phone could hold — so the
    /// proof only ever widens a real phone's budget.
    public var usableBytes: Int64 {
        let fraction = Int64(Double(verdictMemoryBytes) * entitlementFraction)
        guard environment == .device, let proven = provenLoadBytes, proven > fraction else { return fraction }
        return min(proven, physicalMemoryBytes)
    }

    /// True when a model has actually loaded here, so `usableBytes` is backed
    /// by something that happened rather than by the fraction alone.
    public var isProven: Bool { environment == .device && (provenLoadBytes ?? 0) > 0 }

    /// Records that `model` loaded here, widening the budget if it was the
    /// biggest yet.
    ///
    /// Call it on the success path of a load, with the context the engine was
    /// actually given. Because the proof is a floor, recording a load can never
    /// change the verdict of a model that already fitted — which is the
    /// property `fit(for:)` promises and the one the old code broke.
    ///
    /// The store keeps its own copy of the budget, so this is followed by
    /// `await store.updateBudget(budget)` the same way a context-limit change is.
    public mutating func recordSuccessfulLoad(
        of model: ModelRecord,
        atContext contextTokens: Int? = nil,
        calibration: MemoryCalibration = .standard
    ) {
        let context = contextTokens ?? min(model.contextLength, servedContextTokens)
        calibration.recordSuccessfulLoad(estimatedBytes: model.memoryEstimate(atContext: context).totalBytes)
        provenLoadBytes = calibration.largestSuccessfulLoadBytes
    }

    // MARK: - The other signal: how much room there is right now

    /// Held back from the live reading before calling any of it room. The same
    /// number the calibration holds back, for the same reason: a reading taken
    /// with nothing loaded is not a promise that all of it can be spent.
    public static var pressureReserveBytes: Int64 { MemoryCalibration.loadReserveBytes }

    /// What the kernel says is left for this process right now, or `nil` where
    /// nothing says.
    ///
    /// Named so that no call site can mistake it for a budget. This is the
    /// number that drops by the size of whatever is resident.
    public var headroomNowBytes: Int64? { availableNowBytes }

    /// How close this process is to the kill line at this instant.
    ///
    /// Entirely separate from `Fit`, with its own words. "Too large" is a claim
    /// about a model and a phone; "under pressure" is a claim about right now,
    /// and the fix for it is unloading rather than choosing differently.
    public enum Pressure: Sendable, Equatable {
        /// No reading to be had — macOS, and the simulator, where there is no
        /// jetsam limit to have bytes remaining against.
        case unknown
        case easy
        case tight
        case critical

        /// True when the honest advice is to free the resident model.
        public var suggestsUnloading: Bool { self == .critical }

        /// The sentence to show. Never a fit verdict, and never about whether a
        /// model is too large for this phone — it is about this minute.
        public var message: String? {
            switch self {
            case .unknown, .easy:
                return nil
            case .tight:
                return "Memory is tight right now. Closing other apps, or unloading the model, frees room."
            case .critical:
                return "This phone is nearly out of memory. Unload the model to make room."
            }
        }
    }

    public var pressure: Pressure {
        guard let headroom = availableNowBytes, headroom > 0 else { return .unknown }
        if headroom < Self.pressureReserveBytes { return .critical }
        if headroom < Self.pressureReserveBytes * 2 { return .tight }
        return .easy
    }

    /// Takes a live reading, whenever. Cheap, and safe at any moment precisely
    /// because nothing it feeds is a verdict.
    public mutating func refreshHeadroom(_ available: AvailableMemory = .system) {
        availableNowBytes = available.bytes
    }

    /// Takes a reading where nothing is resident and keeps it as a high-water
    /// mark as well.
    ///
    /// Call it straight after an unload and nowhere else: the mark is only
    /// meaningful if every sample is comparable. It no longer moves any
    /// verdict, so a misplaced call is now a bad diagnostic rather than a
    /// screen full of wrong badges.
    public mutating func recordCleanStateMemory(
        _ available: AvailableMemory = .system,
        calibration: MemoryCalibration = .standard
    ) {
        let reading = available.bytes
        calibration.recordAvailableMemory(reading)
        availableNowBytes = reading
    }

    // MARK: - The simulator

    /// The phone the simulator stands in for when it judges a brain: an 8 GB
    /// iPhone, the top of the 6–8 GB class most people hold.
    ///
    /// The simulator runs llama.cpp on the Mac's CPU with no Metal and no
    /// jetsam, so `ProcessInfo.physicalMemory` reports the Mac. Judging by the
    /// Mac called 10 GB files "Tight fit" with a Get button, and listed 9B
    /// repos first in search; judging by one gigabyte instead (the rule this
    /// replaced) called Qwen3 1.7B "Tight fit" while the Brain page
    /// recommended it. A phone class gives every screen the answers a real
    /// iPhone would.
    public static let simulatedPhoneMemoryBytes: Int64 = 8 * 1024 * 1024 * 1024

    /// What the UI should say about these numbers when they came from a Mac.
    public var environmentNote: String? {
        guard environment == .simulator else { return nil }
        return "On the simulator, Pocketd judges every brain as an 8 GB iPhone would."
    }

    // MARK: - Verdicts

    /// Ordered worst to best, so a caller can ask for "at least tight" rather
    /// than enumerating the two verdicts that satisfy it.
    public enum Fit: Sendable, Equatable, Comparable {
        /// Will be killed by the kernel. Downloading it is wasted bandwidth.
        case willNotFit
        /// Loads, but leaves little room for anything else the phone is doing.
        case tight
        case comfortable

        /// True when a plain Download button is an honest offer.
        ///
        /// False does not mean "hide the button": it means the only honest path
        /// is the oversize override, which puts both numbers on screen before
        /// anyone spends the bandwidth. See `needsOverride`.
        public var isDownloadable: Bool { self != .willNotFit }

        /// True when downloading has to go through the override — the user is
        /// shown what they are overriding and says go ahead anyway.
        public var needsOverride: Bool { self == .willNotFit }

        /// The name this had before `needsOverride` existed as its other half.
        /// Identical to `isDownloadable`; kept so call sites need not all move
        /// at once.
        public var allowsDownload: Bool { isDownloadable }
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
        if needed <= Int64(Double(usableBytes) * Self.comfortableFraction) {
            return .comfortable
        } else if needed <= usableBytes {
            return .tight
        }
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
