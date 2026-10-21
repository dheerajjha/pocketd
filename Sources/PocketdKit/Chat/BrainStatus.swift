import Foundation

/// Where the brain stands, as one answer every screen reads.
///
/// "Is there a usable brain?" used to be re-derived in twenty-seven places
/// across fourteen views, each combining the resident id, the loading flag, the
/// downloads and the tool gate by slightly different rules — so Today said
/// "Give it a brain" while one was loading, and Ask's chip and Ask's notice
/// disagreed about the same brain on the same screen. This is the one place the
/// combination is made, and a pure function so the whole table is tested.
///
/// No case carries a brain's name. Names belong on the Brain page, which reads
/// them from the catalogue; every other screen says what Pocketd can do, and a
/// status that carried "smollm2-360m" would end up printed on one of them.
public enum BrainStatus: Sendable, Equatable {
    /// Nothing can answer and nothing is on its way. `hasDownloaded` is a brain
    /// on this phone that is not in memory — it loads by itself when needed.
    case none(hasDownloaded: Bool)
    /// A brain is downloading and nothing can answer yet. `fraction` is `nil`
    /// until the first byte has arrived; `minutesLeft` until the rate is known.
    case arriving(fraction: Double?, minutesLeft: Int?)
    /// A brain is being put into memory.
    case loading
    /// A brain is ready and can read your calendar, reminders and health.
    case ready
    /// A brain is ready to talk and cannot read your day: anything it says
    /// about your calendar is a guess.
    case cannotReadYourDay
    /// The brain would not load and nothing else is answering. The reason is
    /// one plain sentence, never an engine error.
    case failed(reason: String)

    /// Whether a question can be sent now.
    public var canAnswer: Bool {
        switch self {
        case .ready, .cannotReadYourDay: true
        case .none, .arriving, .loading, .failed: false
        }
    }

    /// Whether this brain may write the daily brief. Only one that reads the
    /// day: the template is always true, and a brain that cannot read the day
    /// has been seen printing its own instructions in the brief's place.
    public var canWriteBrief: Bool { self == .ready }

    /// Whether a brain is on its way, so a question can wait for it.
    public var isGettingReady: Bool {
        switch self {
        case .arriving, .loading: true
        case .none, .ready, .cannotReadYourDay, .failed: false
        }
    }
}

// MARK: - Deciding

public extension BrainStatus {

    /// The brain in memory.
    struct Resident: Sendable, Equatable {
        /// Which brain. `.builtIn` is the place for Apple's model: the
        /// built-in brain plugs in here with `readsYourDay: true` and needs no
        /// other case, because to every screen it is simply a brain that is
        /// ready.
        public var choice: BrainChoice
        /// The engine's own verdict once loaded (`ToolGate`), not the
        /// catalogue's claim.
        public var readsYourDay: Bool

        public init(choice: BrainChoice, readsYourDay: Bool) {
            self.choice = choice
            self.readsYourDay = readsYourDay
        }
    }

    /// A download in progress.
    struct Arrival: Sendable, Equatable {
        public var fraction: Double?
        public var secondsLeft: TimeInterval?

        public init(fraction: Double? = nil, secondsLeft: TimeInterval? = nil) {
            self.fraction = fraction
            self.secondsLeft = secondsLeft
        }
    }

    /// Everything the status is made from, as plain values.
    struct Inputs: Sendable, Equatable {
        public var resident: Resident?
        public var isLoading: Bool
        /// The download that would bring a brain, if one is running. A built-in
        /// brain that Apple is still downloading arrives here too, with no
        /// fraction.
        public var arriving: Arrival?
        public var hasDownloaded: Bool
        /// Why the last load failed, as a sentence for a person.
        public var loadFailure: String?

        public init(
            resident: Resident? = nil,
            isLoading: Bool = false,
            arriving: Arrival? = nil,
            hasDownloaded: Bool = false,
            loadFailure: String? = nil
        ) {
            self.resident = resident
            self.isLoading = isLoading
            self.arriving = arriving
            self.hasDownloaded = hasDownloaded
            self.loadFailure = loadFailure
        }
    }

    /// The one status these inputs mean.
    ///
    /// The ranking is the order of the checks:
    /// 1. A load in progress outranks a brain already resident. Switching
    ///    brains holds the engine until the new one is in, so a question sent
    ///    now waits either way, and saying "ready" would be the lie.
    /// 2. A resident brain outranks a download: an upgrade arriving in the
    ///    background does not stop the current brain answering.
    /// 3. A download outranks an old failure, because it is the fix on its way.
    static func derive(_ inputs: Inputs) -> BrainStatus {
        if inputs.isLoading { return .loading }
        if let resident = inputs.resident {
            return resident.readsYourDay ? .ready : .cannotReadYourDay
        }
        if let arriving = inputs.arriving {
            return .arriving(
                fraction: arriving.fraction.map { min(max($0, 0), 1) },
                minutesLeft: arriving.secondsLeft.flatMap(minutes(for:))
            )
        }
        if let failure = inputs.loadFailure { return .failed(reason: failure) }
        return .none(hasDownloaded: inputs.hasDownloaded)
    }

    /// Whole minutes, rounded up and never zero — "about 0 minutes" is a
    /// promise nobody can keep — and nothing at all for a rate that has not
    /// settled into a believable figure.
    static func minutes(for seconds: TimeInterval) -> Int? {
        guard seconds.isFinite, seconds > 0, seconds < 24 * 60 * 60 else { return nil }
        return max(1, Int((seconds / 60).rounded(.up)))
    }
}

// MARK: - Why a load failed

public extension BrainStatus {
    /// Why a brain would not load, in a sentence for the Brain page.
    ///
    /// From the analytics bucket rather than the error, because the error is
    /// llama.cpp's or the file system's and names files, projectors and
    /// formats — none of it anything a person can act on.
    static func loadFailureSentence(for reason: LoadFailureReason) -> String {
        switch reason {
        case .outOfMemory: "It needs more memory than this iPhone has free."
        case .missingProjector, .fileMissing: "Part of it is missing. Download it again."
        case .unsupportedFormat: "This iPhone can't run it."
        case .other: "It couldn't start on this iPhone."
        }
    }
}

// MARK: - Loading what just arrived

public extension BrainStatus {

    /// Whether a brain that has just finished downloading should be loaded
    /// without anyone tapping anything.
    ///
    /// Yes when nothing is answering, or when what is answering cannot read the
    /// day and the new one can — the reason anyone downloads a second brain.
    /// No when the current brain already reads the day: swapping a working
    /// brain out from under somebody mid-conversation is a decision for the
    /// Brain page.
    ///
    /// - Parameter arrivedReadsYourDay: the catalogue's vetted claim about the
    ///   new brain. An unvetted brain is not swapped in for a working one on a
    ///   guess.
    static func shouldLoadArrival(current: BrainStatus, arrivedReadsYourDay: Bool) -> Bool {
        switch current {
        case .none, .arriving, .failed: true
        case .cannotReadYourDay: arrivedReadsYourDay
        case .ready, .loading: false
        }
    }
}
