import Foundation

/// The one thing the conversation has to say above the composer, or nothing.
///
/// Ask's notice area was a seven-branch `if` over five optionals, a
/// capability warning written for Settings and a brain-upgrade check, with the
/// silencing held in view state that reset on every visit — so a dismissed
/// warning came back each time the tab was opened. One notice at a time, in a
/// fixed order, each one plain sentence and one action, decided here where the
/// whole table can be tested.
public enum AskNotice: Sendable, Equatable {
    /// A reply failed. The sentence is plain; the way out is a new chat.
    case replyFailed(String)
    /// The last question needed a source that is off.
    case offer(ToolOffer)
    /// Nothing can answer yet, and a brain is on its way.
    case gettingReady(minutesLeft: Int?, questionWaiting: Bool)
    /// Nothing can answer and nothing is coming.
    case chooseBrain(questionWaiting: Bool)
    /// The brain would not start.
    case brainFailed(questionWaiting: Bool)
    /// The brain answers, and cannot read your calendar.
    case cannotReadYourDay

    /// What the notice's one button does.
    public enum Action: Sendable, Equatable {
        case startNewChat
        case connect(Ability)
        /// The Brain page.
        case chooseBrain
        case none
    }

    /// Whether the reader can put it away, and for how long.
    public enum Dismissal: Sendable, Equatable {
        /// It goes when what it describes changes.
        case never
        /// Until it happens again.
        case forNow
        /// Never shown again on this phone; the key is what is stored.
        case forever(key: String)
    }

    /// One plain sentence, never more than about twenty-five words.
    public var sentence: String {
        switch self {
        case let .replyFailed(sentence):
            return sentence
        case let .offer(offer):
            return "Connect \(offer.ability.noun) so Pocketd can answer that."
        case let .gettingReady(minutesLeft, waiting):
            let minutes = minutesLeft.map { "about \($0) minute\($0 == 1 ? "" : "s")" }
            switch (waiting, minutes) {
            case let (false, minutes?): return "Pocketd is getting ready — \(minutes)."
            case (false, nil): return "Pocketd is getting ready."
            case let (true, minutes?): return "Pocketd is getting ready and will send your question in \(minutes)."
            case (true, nil): return "Pocketd will send your question as soon as it's ready."
            }
        case let .chooseBrain(waiting):
            return waiting
                ? "Choose how Pocketd thinks, and your question will be sent."
                : "Choose how Pocketd thinks to start asking."
        case let .brainFailed(waiting):
            // "Brain" stays off this screen; the button says where the fix is.
            return waiting
                ? "Pocketd couldn't get ready, so your question is waiting."
                : "Pocketd couldn't get ready on this iPhone."
        case .cannotReadYourDay:
            // The spec's own wording, and the one place the conversation names
            // the brain: the fix is to switch it.
            return "This brain can't read your calendar."
        }
    }

    public var action: Action {
        switch self {
        case .replyFailed: .startNewChat
        case let .offer(offer): .connect(offer.ability)
        case .gettingReady: .none
        case .chooseBrain, .brainFailed, .cannotReadYourDay: .chooseBrain
        }
    }

    /// The button's word — a verb, per the glossary.
    public var actionTitle: String? {
        switch self {
        case .replyFailed: "Start a new chat"
        case .offer: "Connect"
        case .gettingReady: nil
        case .chooseBrain, .brainFailed: "Choose"
        case .cannotReadYourDay: "Switch"
        }
    }

    public var dismissal: Dismissal {
        switch self {
        case .replyFailed, .offer: .forNow
        case .gettingReady, .chooseBrain, .brainFailed: .never
        case .cannotReadYourDay: .forever(key: Self.cannotReadYourDayKey)
        }
    }

    /// Stored when the reader puts the brain warning away. Once, per the spec:
    /// the Brain page goes on saying it, quietly, for anyone who looks.
    public static let cannotReadYourDayKey = "cannotReadYourDay"
}

// MARK: - Deciding

public extension AskNotice {

    struct Inputs: Sendable, Equatable {
        public var brain: BrainStatus
        /// The last reply's failure, already a plain sentence.
        public var replyFailure: String?
        public var offer: ToolOffer?
        /// A question that arrived — from Siri, a Shortcut, the Control Center
        /// button or the composer — and is waiting for a brain.
        public var questionWaiting: Bool
        /// Keys of notices put away for good.
        public var dismissed: Set<String>

        public init(
            brain: BrainStatus,
            replyFailure: String? = nil,
            offer: ToolOffer? = nil,
            questionWaiting: Bool = false,
            dismissed: Set<String> = []
        ) {
            self.brain = brain
            self.replyFailure = replyFailure
            self.offer = offer
            self.questionWaiting = questionWaiting
            self.dismissed = dismissed
        }
    }

    /// The one notice these inputs mean, or `nil` for silence.
    ///
    /// The order is fixed and each rung is a judgement:
    /// 1. A reply that just failed — it is the newest thing that happened and
    ///    the only one that blocks the next question.
    /// 2. An offer about the question just asked — it is about this turn.
    /// 3. No brain that can answer — every question waits on it.
    /// 4. A brain that cannot read the day — true, and worth saying once.
    static func decide(_ inputs: Inputs) -> AskNotice? {
        if let failure = inputs.replyFailure { return .replyFailed(failure) }
        if let offer = inputs.offer { return .offer(offer) }
        switch inputs.brain {
        case let .arriving(_, minutesLeft):
            return .gettingReady(minutesLeft: minutesLeft, questionWaiting: inputs.questionWaiting)
        case .loading:
            return .gettingReady(minutesLeft: nil, questionWaiting: inputs.questionWaiting)
        case let .none(hasDownloaded):
            // A brain on the phone that is not in memory loads itself when a
            // question arrives, so it is only worth a word while one is waiting.
            if hasDownloaded {
                return inputs.questionWaiting ? .gettingReady(minutesLeft: nil, questionWaiting: true) : nil
            }
            return .chooseBrain(questionWaiting: inputs.questionWaiting)
        case .failed:
            return .brainFailed(questionWaiting: inputs.questionWaiting)
        case .cannotReadYourDay:
            return inputs.dismissed.contains(cannotReadYourDayKey) ? nil : .cannotReadYourDay
        case .ready:
            return nil
        }
    }
}
