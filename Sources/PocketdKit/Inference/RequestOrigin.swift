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
    case network(host: String, port: UInt16)

    /// Whether personal data may be read for this caller. Only ever true for a
    /// human holding the phone.
    public var mayReachPersonalData: Bool { self == .onDeviceChat }
}

public extension RequestOrigin {
    var loggingDescription: String {
        switch self {
        case .onDeviceChat: "on-device"
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
