import Foundation

/// Finishing the mic and receiving a final are separate events, in either order.
/// Partials only belong in the draft, and only while this turn owns that draft.
public struct DictationHandoff: Sendable {
    /// One native contact, using touch timestamps rather than the time SwiftUI
    /// redraws. A quick first tap leaves its new session running; any tap on a
    /// running session (including a page handoff) finishes that exact session.
    public struct Press: Sendable {
        public enum Session: Sendable {
            case started(UUID), joined(UUID)

            public var id: UUID {
                switch self { case .started(let id), .joined(let id): id }
            }
        }

        public static let holdDuration: TimeInterval = 0.4
        private var beganAt: TimeInterval?
        private var session: Session?
        public var isDown: Bool { beganAt != nil }

        public init() {}

        public mutating func begin(at time: TimeInterval, _ startOrJoin: () -> Session?) {
            guard !isDown else { return }
            beganAt = time
            session = startOrJoin()
        }

        public mutating func end(at time: TimeInterval) -> UUID? {
            defer { self = Self() }
            guard let beganAt, let session else { return nil }
            if case .started = session, time - beganAt < Self.holdDuration { return nil }
            return session.id
        }

        public mutating func cancel() -> UUID? {
            defer { self = Self() }
            return session?.id
        }
    }

    /// Finishing addresses the same ready brain as mic-down. The cloud is a
    /// destination only when explicitly chosen, effective and resident.
    public enum Destination: Equatable, Sendable {
        case review, local(modelID: String, selection: UUID), explicitCloud(modelID: String, selection: UUID)

        public static func resolve(
            chosen: BrainChoice?, effective: BrainChoice?, residentID: String?,
            canAnswer: Bool, cloud: AppleCloudStatus, selection: UUID
        ) -> Self {
            guard canAnswer, let effective, let id = residentID, !id.isEmpty,
                  BrainChoice(residentID: id) == effective else { return .review }
            if effective == .privateCloudCompute {
                guard chosen == .privateCloudCompute, cloud.canChoose else { return .review }
                return .explicitCloud(modelID: id, selection: selection)
            }
            // A ready on-device default is local. A fallback for a different
            // saved selection is ambiguous until the person chooses to send.
            guard chosen == nil || chosen == effective else { return .review }
            return .local(modelID: id, selection: selection)
        }
    }

    public enum Phase: Equatable, Sendable { case idle, starting, listening, awaitingFinish, finishing }

    public enum Event: Sendable {
        case partial(String, timing: DictationTiming = .init()), final(String, timing: DictationTiming = .init())
        /// A disjoint, sealed audio request finished while the same mic turn continues.
        case nextRequest(final: String?, timing: DictationTiming), emptyTail
        case release, timedOut, failed(String)
    }

    public enum Action: Equatable, Sendable {
        case preview(String), endAudio, submit(String), reviewFinal(String), review(String), cancel
    }

    public private(set) var id: UUID?
    /// True until the person finishes, even with their finger up in tap mode.
    public private(set) var isHeld = false
    private var destination: Destination = .review
    private var conversation: UUID?
    private var expectedDraft = ""
    private var prefix = ""
    private var earlierSpeech = ""
    private var transcript = DictationTranscript()
    private var requiresReview = false
    private var earlyFinal: String?
    private var captureStarted = false

    public init() {}

    /// Consult the current turn at contact time, including before a redraw.
    /// A third tap during finalization cannot restart the mic or send a partial.
    public func startOrJoin(_ start: () -> UUID?) -> Press.Session? {
        if let id { return isHeld ? .joined(id) : nil }
        return start().map(Press.Session.started)
    }

    public func phase(isListening: Bool) -> Phase {
        guard id != nil else { return .idle }
        guard isHeld else { return .finishing }
        guard captureStarted else { return .starting }
        return isListening ? .listening : .awaitingFinish
    }

    public mutating func begin(draft: String, in conversation: UUID, destination: Destination, hasAttachments: Bool = false) -> UUID {
        let id = UUID()
        self.id = id
        self.conversation = conversation
        self.destination = destination
        isHeld = true
        expectedDraft = draft
        prefix = draft
        earlierSpeech = ""
        transcript = DictationTranscript()
        requiresReview = !draft.isEmpty || hasAttachments
        earlyFinal = nil
        captureStarted = false
        return id
    }

    /// Check before each OS prompt as well as before capture: the user may
    /// have left the question while the previous prompt was on screen.
    public func awaitsCapture(for id: UUID, draft: String, in conversation: UUID) -> Bool {
        self.id == id && isHeld && !captureStarted && owns(draft: draft, in: conversation)
    }

    public mutating func beginCapture(for id: UUID, draft: String, in conversation: UUID) -> Bool {
        guard awaitsCapture(for: id, draft: draft, in: conversation) else { return false }
        captureStarted = true
        return true
    }

    public mutating func cancel() { self = Self() }

    /// Recognition ended on its own. Finish the question or explicitly start
    /// a new recording whose immutable draft prefix includes this one.
    public var canContinue: Bool { isHeld && earlyFinal != nil }

    /// Sticky for this turn: losing the destination at release (or between
    /// partials) cannot be undone by its return before the recognizer's final.
    public mutating func observeDestination(_ current: Destination) {
        guard id != nil, destination != .review, current != destination else { return }
        destination = .review
    }

    public func owns(draft: String, in conversation: UUID) -> Bool {
        self.conversation == conversation && expectedDraft == draft
    }

    public mutating func receive(_ event: Event, for id: UUID, draft: String, in conversation: UUID, destination current: Destination,
                                 hasAttachments: Bool = false) -> Action? {
        guard self.id == id else { return nil }
        guard owns(draft: draft, in: conversation) else {
            cancel()
            return .cancel
        }
        observeDestination(current)
        requiresReview = requiresReview || hasAttachments

        // A duplicate or trailing error cannot demote an already confirmed
        // transcript while the button is still held.
        if let earlyFinal {
            guard case .release = event else { return nil }
            return confirmed(earlyFinal)
        }

        switch event {
        case .release:
            guard isHeld else { return nil }
            // The permission flow may finish, but recording must not start
            // after the person who requested it has already let go.
            guard captureStarted else { cancel(); return .cancel }
            isHeld = false
            return .endAudio
        case let .partial(text, timing):
            guard captureStarted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            transcript.update(text, timing: timing, confirmed: false)
            expectedDraft = composedDraft
            return .preview(expectedDraft)
        case let .nextRequest(final, timing):
            guard captureStarted else { return nil }
            if let final { transcript.update(final, timing: timing, confirmed: true) }
            if final?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { requiresReview = true }
            let heard = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !heard.isEmpty {
                requiresReview = requiresReview || !transcript.allConfirmed
                earlierSpeech = DictationTranscript.join(earlierSpeech, heard)
            }
            transcript = DictationTranscript()
            expectedDraft = composedDraft
            return .preview(expectedDraft)
        case let .final(text, timing):
            guard captureStarted else { return nil }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return unfinished() }
            transcript.update(text, timing: timing, confirmed: true)
            return finishTranscript()
        case .emptyTail:
            guard captureStarted, !earlierSpeech.isEmpty, transcript.text.isEmpty else { return unfinished() }
            return finishTranscript()
        case .timedOut:
            return unfinished()
        case .failed(let reason):
            cancel()
            return .review(reason)
        }
    }

    private var composedDraft: String {
        let current = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationTranscript.join(prefix, DictationTranscript.join(earlierSpeech, current))
    }

    private mutating func finishTranscript() -> Action {
        guard !earlierSpeech.isEmpty || transcript.hasConfirmed else { return unfinished() }
        // The final might cover only the last phrase. Earlier provisional
        // words stay visible, but must not silently become a submitted action.
        requiresReview = requiresReview || (!transcript.text.isEmpty && !transcript.allConfirmed)
        let words = composedDraft
        if isHeld {
            earlyFinal = words
            expectedDraft = words
            return .preview(words)
        }
        return confirmed(words)
    }

    private mutating func confirmed(_ words: String) -> Action {
        defer { cancel() }
        return requiresReview || destination == .review ? .reviewFinal(words) : .submit(words)
    }

    private mutating func unfinished() -> Action {
        cancel()
        return .review("Dictation didn't finish. Check your question before sending.")
    }
}
