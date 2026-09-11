import Foundation

/// Where events go, if anywhere.
///
/// A protocol rather than a direct Mixpanel call for two reasons, and the
/// second is the one that matters. The first is ordinary: the SDK stays out of
/// PocketdKit, which is built and tested without an app bundle on a Linux
/// runner in seconds, and that property is worth keeping.
///
/// The second is that it makes "sends nothing" a type rather than a promise.
/// `NoAnalytics` cannot transmit — not because it is configured not to, but
/// because it has no code that could. Every test in this package runs against
/// it, so a test suite can never accidentally talk to a real project, and the
/// app's opted-out state is the same object rather than a flag checked at
/// thirteen call sites.
public protocol AnalyticsSink: Sendable {
    func record(_ event: AnalyticsEvent)
    /// Stop, and forget. Called when someone refuses: the implementation must
    /// drop anything queued and discard the identifier, not merely stop
    /// adding to the queue.
    func stopAndForget()
}

/// The default, and what every test sees.
public struct NoAnalytics: AnalyticsSink {
    public init() {}
    public func record(_ event: AnalyticsEvent) {}
    public func stopAndForget() {}
}

/// Remembers what it was asked to send, so tests can assert on the taxonomy
/// rather than on whether a function was called.
public final class RecordingAnalytics: AnalyticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AnalyticsEvent] = []
    private var _stopped = false

    public init() {}

    public var events: [AnalyticsEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    public var wasStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    public func record(_ event: AnalyticsEvent) {
        lock.lock(); defer { lock.unlock() }
        // Mirrors the real sink: a stopped sink records nothing. A test that
        // passes because the recorder kept accepting events after opt-out
        // would be testing the opposite of the thing we care about.
        guard !_stopped else { return }
        _events.append(event)
    }

    public func stopAndForget() {
        lock.lock(); defer { lock.unlock() }
        _stopped = true
        _events.removeAll()
    }
}

/// What the app is allowed to have decided about analytics.
///
/// Three states, not a Bool, because "has not been asked yet" is not the same
/// as "said no" and the difference decides whether anything may be sent. A Bool
/// defaulting to false conflates them, and a Bool defaulting to true sends
/// before the person has seen the sentence explaining it.
public enum AnalyticsConsent: String, Sendable, CaseIterable {
    case undecided
    case granted
    case refused

    /// Only one of the three permits transmission.
    public var permitsSending: Bool { self == .granted }
}
