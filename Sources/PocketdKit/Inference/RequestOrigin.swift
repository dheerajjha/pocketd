import Foundation

/// Who is asking.
///
/// This exists because device tools — calendar, reminders — must never run for
/// a network caller, and the primitive one would naturally reach for to decide
/// that is forgeable. FlyingFox's `remoteIPAddress` returns `X-Forwarded-For`
/// before it consults the socket, which is right behind a proxy you run and
/// wrong for a phone on a LAN: anyone could claim to be `127.0.0.1`.
///
/// Derived only from the accepted connection's peer, which the caller cannot
/// set.
public enum RequestOrigin: Sendable, Equatable {
    /// The app's own Chat tab, calling the engine directly in-process.
    ///
    /// Note this is NOT the /chat page the phone serves — that page is a
    /// network client like curl, indistinguishable at the route layer, and must
    /// not be privileged just because we wrote it.
    case onDeviceChat
    /// Work the user set up earlier, running now without them.
    ///
    /// Its own case, and NOT `.onDeviceChat`, which is the whole point. The
    /// tempting shortcut is to have a scheduled run claim to be the chat tab
    /// so that the personal-data tools answer it. That works, and it quietly
    /// redefines this type: `.onDeviceChat` means "a human is holding this
    /// phone", and forging it turns the question into "did the caller assert
    /// it?" — which is exactly the property this enum exists to not have,
    /// since the reason it is derived from the accepted socket is that
    /// anything self-reported is forgeable.
    ///
    /// A scheduled task DOES get personal data, and that is a deliberate
    /// decision rather than an inherited one: the user wrote the prompt, on
    /// this device, and asked for it to run at a time they chose. But it is a
    /// different caller from a person typing, it is logged differently, and
    /// the day something needs to treat them differently — a narrower tool
    /// set, a rate limit, an audit line — the distinction already exists
    /// instead of having to be reconstructed from a lie.
    case scheduledTask(id: UUID)
    case network(host: String, port: UInt16)

    /// Whether personal data may be read for this caller.
    ///
    /// An exhaustive switch, deliberately, where this used to be
    /// `self == .onDeviceChat`. That equality compiled cleanly when a case was
    /// added and silently answered false for it — fail-closed, so safe, but
    /// the feature simply would not work and nothing would say why. A switch
    /// makes the next person adding a case answer the question.
    public var mayReachPersonalData: Bool {
        switch self {
        case .onDeviceChat, .scheduledTask: true
        case .network: false
        }
    }

    /// True only when a person is actually present to read the answer.
    ///
    /// Not the same question as `mayReachPersonalData`, and the difference is
    /// the reason `.scheduledTask` is not folded into `.onDeviceChat`. Anything
    /// that wants to ask for confirmation, show a permission prompt, or assume
    /// someone is looking at the screen must ask THIS.
    public var hasSomeoneWatching: Bool {
        switch self {
        case .onDeviceChat: true
        case .scheduledTask, .network: false
        }
    }
}

public extension RequestOrigin {
    var loggingDescription: String {
        switch self {
        case .onDeviceChat: "on-device"
        // Short, because this lands in a request log the user reads. The id
        // is enough to tell two scheduled tasks apart without turning the row
        // into a UUID.
        case let .scheduledTask(id): "scheduled \(id.uuidString.prefix(8))"
        case let .network(host, _): host
        }
    }
}

/// Carries the origin to tool bodies.
///
/// Tools are frozen at client construction — the inference library stores them
/// in a `let` and builds its chat parameters once — so a per-request tool array
/// is impossible without reloading multiple gigabytes of weights. The origin
/// therefore has to travel out of band, and a task local is the only channel
/// that reaches a tool's `call()` without widening every signature between.
public enum ToolContext {
    @TaskLocal public static var origin: RequestOrigin = .network(host: "unknown", port: 0)

    /// What a tool returns to a caller that may not have it. Phrased as a
    /// sentence because the model repeats it to the user verbatim.
    public static let refusal = "Personal data is not available to network clients. Ask on the iPhone itself."
}
