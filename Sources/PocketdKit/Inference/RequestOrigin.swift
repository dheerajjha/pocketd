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

    /// Whether personal data may be *changed* for this caller.
    ///
    /// A separate question from `mayReachPersonalData`, and a stricter answer:
    /// only the chat tab. Its own exhaustive switch rather than
    /// `hasSomeoneWatching` spelled differently, for the reason the comment
    /// above gives — the next person adding a case has to answer this one too,
    /// and an alias would answer it for them.
    ///
    /// A scheduled run reads and does not write, which is the interesting half
    /// of this. It is not a grudging restriction on a caller we half-trust; it
    /// falls out of two facts that happen to point the same way.
    ///
    /// The first is that it loses almost nothing. A scheduled task already ends
    /// in a notification — reminding the user IS the feature — so a run that
    /// also filed a reminder would mostly be telling them the same thing twice.
    ///
    /// The second is that it is the one origin where nobody is watching AND the
    /// context contains text this app does not trust. `CalendarEventRow.title`
    /// is `Untrusted` because a meeting invite is written by a stranger, and a
    /// 7am briefing reads the calendar by design. Reading more calendar in
    /// response to an injected line is harmless; *writing* because of one is
    /// not, and at 7am there is no one to notice. The chat tab has the same
    /// attacker-controlled text in play and a person looking at the screen who
    /// can see the card and undo it, which is the whole difference.
    ///
    /// Deleting is not on the far side of this gate for anybody: see
    /// `PersonalDataWrites` for why the tools can add and tick off but not
    /// destroy.
    public var mayWritePersonalData: Bool {
        switch self {
        case .onDeviceChat: true
        case .scheduledTask, .network: false
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

    /// What a write tool returns to a caller that may not change anything.
    ///
    /// Two sentences rather than one because the two refusals it covers have
    /// different remedies and a model handed one generic line invents the
    /// wrong one. A network client should be told to use the phone; a
    /// scheduled run should be told to say the thing rather than do it, since
    /// saying it is what a scheduled task is for.
    public static func writeRefusal(for origin: RequestOrigin) -> String {
        switch origin {
        case .network:
            "Changing calendars and reminders is not available to network clients. Ask on the iPhone itself."
        case .scheduledTask:
            "A scheduled run can read but cannot change anything. Say what needs doing and the person can act on it."
        case .onDeviceChat:
            // Unreachable through the gate, and a value rather than a
            // precondition: a tool body that got here anyway must still return
            // a sentence, because throwing ends the generation mid-stream.
            "That change could not be made."
        }
    }
}
