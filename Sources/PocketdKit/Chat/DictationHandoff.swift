import Foundation

/// Releasing the mic is permission to send; only the recognizer can supply the
/// words to send. Either event can arrive first. Partials only belong in the
/// draft, and only while this turn still owns that draft.
public struct DictationHandoff: Sendable {
    /// A drag reports many changes, and its release can precede even the first
    /// redraw. Keep the session returned on touch-down, not the one on screen
    /// at touch-up. A tap on a page-initiated mic can adopt that session too.
    public struct Press: Sendable {
        public private(set) var isDown = false
        private var session: UUID?

        public init() {}

        public mutating func begin(_ startOrJoin: () -> UUID?) {
            guard !isDown else { return }
            isDown = true
            session = startOrJoin()
        }

        public mutating func end() -> UUID? {
            defer { self = Self() }
            return session
        }
    }

    public enum Event: Sendable {
        case partial(String), final(String), release, timedOut, failed(String)
    }

    public enum Action: Equatable, Sendable {
        case preview(String), endAudio, submit(String), review(String), cancel
    }

    public private(set) var id: UUID?
    public private(set) var isHeld = false
    private var conversation: UUID?
    private var expectedDraft = ""
    private var earlyFinal: String?
    private var captureStarted = false

    public init() {}

    public mutating func begin(draft: String, in conversation: UUID) -> UUID {
        let id = UUID()
        self.id = id
        self.conversation = conversation
        isHeld = true
        expectedDraft = draft
        earlyFinal = nil
        captureStarted = false
        return id
    }

    /// Called after the permission awaits, immediately before opening the mic.
    public mutating func beginCapture(for id: UUID, draft: String, in conversation: UUID) -> Bool {
        guard self.id == id, isHeld, !captureStarted, owns(draft: draft, in: conversation) else { return false }
        captureStarted = true
        return true
    }

    public mutating func cancel() { self = Self() }

    public func owns(draft: String, in conversation: UUID) -> Bool {
        self.conversation == conversation && expectedDraft == draft
    }

    public mutating func receive(_ event: Event, for id: UUID, draft: String, in conversation: UUID) -> Action? {
        guard self.id == id else { return nil }
        guard owns(draft: draft, in: conversation) else {
            cancel()
            return .cancel
        }

        // A duplicate or trailing error cannot demote an already confirmed
        // transcript while the button is still held.
        if let earlyFinal {
            guard case .release = event else { return nil }
            cancel()
            return .submit(earlyFinal)
        }

        switch event {
        case .release:
            guard isHeld else { return nil }
            // The permission flow may finish, but recording must not start
            // after the person who requested it has already let go.
            guard captureStarted else { cancel(); return .cancel }
            isHeld = false
            return .endAudio
        case .partial(let text):
            guard captureStarted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            expectedDraft = text
            return .preview(text)
        case .final(let text):
            guard captureStarted else { return nil }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return unfinished() }
            if isHeld {
                earlyFinal = words
                expectedDraft = words
                return .preview(words)
            }
            cancel()
            return .submit(words)
        case .timedOut:
            return unfinished()
        case .failed(let reason):
            cancel()
            return .review(reason)
        }
    }

    private mutating func unfinished() -> Action {
        cancel()
        return .review("Dictation didn't finish. Check your question before sending.")
    }
}
