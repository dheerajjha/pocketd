import Foundation

/// A short-lived six-digit code that trades itself for the API key.
///
/// The key is 35 characters of random lowercase. Reading it off a phone and
/// typing it into a laptop is the worst moment in the product, and AirDrop only
/// helps if the laptop is a Mac. So the phone shows six digits, the laptop opens
/// the page the phone is already serving, and the key crosses the network the
/// user is already trusting with their prompts.
///
/// The code is the thing that is guessable, so it expires and it is rate
/// limited. Six digits with five attempts is a one-in-two-hundred-thousand
/// chance for an attacker who is already on the network.
public actor PairingSession {
    /// Why the last code left the screen, when nothing replaced it.
    ///
    /// The phone has to say something different in each case — "paired" is
    /// good news, "too many wrong tries" is a warning — and none of them can
    /// be read off the counters. `failureCount` is the session's running total
    /// and carries over to the next code on purpose (it is a record of who
    /// tried), so a screen that keyed "that code is dead" on it went on saying
    /// so under the fresh, working code the person had just asked for.
    public enum Ending: Sendable, Equatable {
        /// A device completed the handshake with it.
        case paired
        /// Five wrong codes in a row burned it.
        case tooManyTries
        /// Someone tried it after it had run out of time.
        case expired
    }

    public struct Snapshot: Sendable, Equatable {
        public var code: String?
        public var expires: Date?
        public var attemptsRemaining: Int
        public var lastFailureAddress: String?
        public var failureCount: Int
        /// When a laptop last completed the handshake. The phone stops printing
        /// the key on screen until this is set, because until then nobody has
        /// asked for it and it has no business being readable over someone's
        /// shoulder.
        public var pairedAt: Date?
        /// Set when a code ends on its own; cleared the moment a new one opens.
        public var ending: Ending?

        public var isOpen: Bool { code != nil }
        public var hasPaired: Bool { pairedAt != nil }

        /// Whether the code on screen still works at `now`. A code past its
        /// expiry is still *open* until someone tries it — the actor has no
        /// timer — so a screen asking "can a laptop use this?" must ask this.
        public func isLive(at now: Date) -> Bool {
            guard code != nil, let expires else { return false }
            return now < expires && attemptsRemaining > 0
        }

        public init(
            code: String? = nil,
            expires: Date? = nil,
            attemptsRemaining: Int = 0,
            lastFailureAddress: String? = nil,
            failureCount: Int = 0,
            pairedAt: Date? = nil,
            ending: Ending? = nil
        ) {
            self.code = code
            self.expires = expires
            self.attemptsRemaining = attemptsRemaining
            self.lastFailureAddress = lastFailureAddress
            self.failureCount = failureCount
            self.pairedAt = pairedAt
            self.ending = ending
        }
    }

    public static let lifetime: TimeInterval = 600
    public static let maxAttempts = 5

    private var state = Snapshot()
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private let now: @Sendable () -> Date

    /// UserDefaults is thread-safe but not marked Sendable, so it cannot cross
    /// into an actor without this. Same wrapper as ServerConfigurationStore.
    public struct PairedAtStore: @unchecked Sendable {
        let defaults: UserDefaults?
        static let key = "pocketd.pairedAt"

        public init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

        func read() -> Date? { defaults?.object(forKey: Self.key) as? Date }
        func write(_ date: Date) { defaults?.set(date, forKey: Self.key) }
    }

    private let store: PairedAtStore

    /// `defaults` persists only the fact that pairing has happened at least
    /// once — never the code, which is short-lived and guessable by design.
    /// Without it the Connected section, with the key and every client snippet,
    /// disappeared on relaunch and could only be recovered by pairing a device
    /// again.
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        store: PairedAtStore = PairedAtStore()
    ) {
        self.now = now
        self.store = store
        if let stamp = store.read() { state.pairedAt = stamp }
    }

    /// Opens a fresh code, replacing whatever was there.
    ///
    /// Always allowed — after a pairing, after a burned code, over a live one.
    /// A second laptop, a browser whose stored key was cleared, or the same
    /// laptop after the key was replaced all need a new code, and the phone is
    /// the only place one can come from. The guess limit is per code, which is
    /// why only the person holding the phone can ask for another.
    @discardableResult
    public func open() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        // pairedAt carries over. Rebuilding the whole snapshot dropped it,
        // so asking for a second code hid the API key and every client
        // snippet — and the button that did it lived inside the section it
        // hid. close() had always preserved it; open() had not.
        state = Snapshot(
            code: code,
            expires: now().addingTimeInterval(Self.lifetime),
            attemptsRemaining: Self.maxAttempts,
            lastFailureAddress: state.lastFailureAddress,
            failureCount: state.failureCount,
            pairedAt: state.pairedAt,
            ending: nil
        )
        broadcast()
        return code
    }

    public enum Outcome: Sendable, Equatable {
        case paired
        case wrongCode(attemptsRemaining: Int)
        case expired
    }

    public func redeem(_ candidate: String, from address: String?) -> Outcome {
        guard let code = state.code, let expires = state.expires else { return .expired }
        guard now() < expires, state.attemptsRemaining > 0 else {
            close(because: .expired)
            return .expired
        }
        guard candidate == code else {
            state.attemptsRemaining -= 1
            state.failureCount += 1
            state.lastFailureAddress = address
            let remaining = state.attemptsRemaining
            if remaining == 0 {
                // Burn the code rather than leaving a dead one on screen; the
                // UI reads `ending` to explain why.
                state.code = nil
                state.expires = nil
                state.ending = .tooManyTries
            }
            broadcast()
            return remaining == 0 ? .expired : .wrongCode(attemptsRemaining: remaining)
        }
        let when = now()
        state.pairedAt = when
        store.write(when)
        close(because: .paired)
        return .paired
    }

    /// Takes the code off screen. Called when the server stops, so a code is
    /// never left open for a listener that is not there.
    public func close() {
        close(because: nil)
    }

    private func close(because ending: Ending?) {
        state = Snapshot(
            lastFailureAddress: state.lastFailureAddress,
            failureCount: state.failureCount,
            pairedAt: state.pairedAt,
            ending: ending
        )
        broadcast()
    }

    public func snapshot() -> Snapshot { state }

    public func stream() -> AsyncStream<Snapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func broadcast() {
        for continuation in observers.values { continuation.yield(state) }
    }
}
