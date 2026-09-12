import Foundation

/// Why a run did not produce anything, as a closed set.
///
/// Deliberately not an error's own text. The natural thing to store here is
/// `error.localizedDescription`, and this app has already learned what that
/// costs once: a `URLError`'s description carries the signed CDN URL and the
/// whole resume blob, and it went straight on screen. A run record is shown in
/// a list, is kept for weeks, and — unlike a `URLError` — sits next to the
/// user's calendar. A closed set means the worst case is `.other`.
public enum RunFailure: String, Sendable, Codable, CaseIterable {
    /// A prompt task reached a context that can run a model, and there was no
    /// model loaded to run.
    case noModelLoaded
    /// The generation started and did not finish: the app was backgrounded
    /// mid-run, or the device governor pulled the GPU back for heat.
    case interrupted
    /// A promised run that was never collected before the next firing replaced
    /// it. Recorded rather than deleted so the list shows the gap.
    case lapsed
    case other
}

/// One thing that happened, or was meant to happen, at one firing.
///
/// The distinction the type is built around is between the **firing** — the
/// instant the schedule says — and **when it actually ran**, which on this app
/// can be hours later and in a different execution context, because a prompt
/// task cannot think in the background. Collapsing those two into one date
/// would make the history unreadable: "7:00 am" against a run that happened at
/// 9:40 when the user tapped the notification is a record of neither event.
public struct TaskRun: Sendable, Codable, Equatable, Identifiable {

    /// What happened.
    public enum Outcome: Sendable, Codable, Equatable {
        /// It ran and had something to say. The text is on `TaskRun.output`.
        case reported
        /// It ran, read fine, and there was nothing there. Not a failure, and
        /// kept distinct from one for the reason that runs through this
        /// codebase: an empty day and an unreadable calendar must never look
        /// the same in a list.
        case nothingToReport
        /// The data could not be read at all.
        case unauthorized(PersonalDataAuthorization)
        /// The user was told it was due, and the thinking has not happened yet
        /// because the firing landed somewhere a model cannot run. This is the
        /// normal, expected state of a prompt task between its notification and
        /// the tap that collects it — not an error.
        case awaitingForeground
        case failed(RunFailure)
    }

    public var id: UUID
    /// The scheduled instant this run settles.
    public var firing: Date
    /// When it actually happened. Equal to `firing` only by coincidence.
    public var ranAt: Date
    public var context: ExecutionContext
    public var outcome: Outcome

    /// The rendered result.
    ///
    /// Private, and reachable only through `output`, which hands back an
    /// `Untrusted<String>`. That is the whole reason this property is not
    /// public: the text is built from calendar titles and reminder names, which
    /// are written by whoever sent the invite or shares the list, and a stored
    /// run record is replayed into later prompts. A `String` field here would
    /// be one autocomplete away from being interpolated into one.
    ///
    /// `Untrusted` has no `Codable` conformance and is not given one here.
    /// Adding a retroactive one would decide, module-wide and by default, that
    /// untrusted text round-trips like any other value; keeping the conformance
    /// on the storage type instead means each persisted field states for itself
    /// what it is holding.
    private var body: String

    /// The result, wrapped so its provenance travels with it.
    ///
    /// `nil` for every outcome but `.reported` — there is no text for a run
    /// that found nothing or never happened, and returning an empty string
    /// would make "nothing to report" and "reported nothing" indistinguishable
    /// at the call site.
    public var output: Untrusted<String>? {
        guard case .reported = outcome else { return nil }
        return Untrusted(body)
    }

    private init(id: UUID, firing: Date, ranAt: Date, context: ExecutionContext, outcome: Outcome, body: String) {
        self.id = id
        self.firing = firing
        self.ranAt = ranAt
        self.context = context
        self.outcome = outcome
        self.body = body
    }

    /// It ran and produced text.
    ///
    /// The `Untrusted<String>` parameter is the point of the factory: there is
    /// no way to file a reported run from a bare `String`, so every caller has
    /// to say, in the diff, where the text came from.
    public static func reported(
        firing: Date,
        ranAt: Date = Date(),
        context: ExecutionContext,
        output: Untrusted<String>,
        id: UUID = UUID()
    ) -> TaskRun {
        TaskRun(id: id, firing: firing, ranAt: ranAt, context: context,
                outcome: .reported, body: output.attackerControlledValue())
    }

    public static func nothingToReport(
        firing: Date,
        ranAt: Date = Date(),
        context: ExecutionContext,
        id: UUID = UUID()
    ) -> TaskRun {
        TaskRun(id: id, firing: firing, ranAt: ranAt, context: context, outcome: .nothingToReport, body: "")
    }

    public static func unauthorized(
        _ authorization: PersonalDataAuthorization,
        firing: Date,
        ranAt: Date = Date(),
        context: ExecutionContext,
        id: UUID = UUID()
    ) -> TaskRun {
        TaskRun(id: id, firing: firing, ranAt: ranAt, context: context,
                outcome: .unauthorized(authorization), body: "")
    }

    /// Notified, not yet thought about. See `Outcome.awaitingForeground`.
    public static func awaitingForeground(
        firing: Date,
        ranAt: Date = Date(),
        context: ExecutionContext,
        id: UUID = UUID()
    ) -> TaskRun {
        TaskRun(id: id, firing: firing, ranAt: ranAt, context: context,
                outcome: .awaitingForeground, body: "")
    }

    public static func failed(
        _ failure: RunFailure,
        firing: Date,
        ranAt: Date = Date(),
        context: ExecutionContext,
        id: UUID = UUID()
    ) -> TaskRun {
        TaskRun(id: id, firing: firing, ranAt: ranAt, context: context, outcome: .failed(failure), body: "")
    }

    /// Whether this run is a promise still outstanding.
    public var isAwaitingForeground: Bool {
        if case .awaitingForeground = outcome { return true }
        return false
    }
}

// MARK: - The wire form of an outcome

/// Hand-written because `PersonalDataAuthorization` is not `Codable`, and that
/// is the right way round.
///
/// It could have been given a conformance where it is declared. It should not
/// be: that type is the app's in-memory reading of `EKAuthorizationStatus`, a
/// thing iOS re-answers on every launch and that no part of this app treats as
/// durable. A synthesised conformance would quietly bless it as storable
/// everywhere, and the next person to persist one would be storing a permission
/// decision that the user may have reversed in Settings ten seconds later.
///
/// Here there is exactly one reason to write it down — a run record has to say
/// why it produced nothing, weeks after the fact — and the mapping is spelled
/// out so it is stable. Raw `Int` cases would have bound the file format to
/// declaration order; the strings below survive a reordering, and the
/// exhaustive switch means a new authorization case breaks this build rather
/// than silently encoding as something else.
extension TaskRun.Outcome {
    private enum CodingKeys: String, CodingKey { case kind, detail }

    private enum Kind: String, Codable {
        case reported, nothingToReport, unauthorized, awaitingForeground, failed
    }

    private static func token(for authorization: PersonalDataAuthorization) -> String {
        switch authorization {
        case .granted: "granted"
        case .notDetermined: "not_determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .writeOnly: "write_only"
        }
    }

    private static func authorization(from token: String) -> PersonalDataAuthorization? {
        PersonalDataAuthorization.allCases.first { Self.token(for: $0) == token }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .reported:
            self = .reported
        case .nothingToReport:
            self = .nothingToReport
        case .awaitingForeground:
            self = .awaitingForeground
        case .unauthorized:
            let token = try container.decode(String.self, forKey: .detail)
            guard let authorization = Self.authorization(from: token) else {
                // Thrown rather than defaulted, and `LossyRun` turns the throw
                // into one dropped history row. Defaulting to `.denied` would
                // put a sentence on screen — "turn it on in Settings" — that a
                // future build knows to be wrong.
                throw DecodingError.dataCorruptedError(
                    forKey: .detail, in: container, debugDescription: "unknown authorization \(token)"
                )
            }
            self = .unauthorized(authorization)
        case .failed:
            self = .failed(try container.decode(RunFailure.self, forKey: .detail))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reported:
            try container.encode(Kind.reported, forKey: .kind)
        case .nothingToReport:
            try container.encode(Kind.nothingToReport, forKey: .kind)
        case .awaitingForeground:
            try container.encode(Kind.awaitingForeground, forKey: .kind)
        case .unauthorized(let authorization):
            try container.encode(Kind.unauthorized, forKey: .kind)
            try container.encode(Self.token(for: authorization), forKey: .detail)
        case .failed(let failure):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(failure, forKey: .detail)
        }
    }
}

/// Decodes a `TaskRun`, or nothing, without taking the task down with it.
///
/// The same trade `LossyCard` makes for answer cards, for the same measured
/// reason. `ScheduledTaskStore.all()` skips a file it cannot decode, so one run
/// record written by a future build — a new `Outcome` case, a new
/// `ExecutionContext` — would delete the user's *task* from the list, schedule
/// and all. The task is the part that cannot be recreated; a run record is
/// history of something that already happened. So it is the run that gets
/// dropped.
struct LossyRun: Decodable {
    let run: TaskRun?

    init(from decoder: any Decoder) throws {
        run = try? TaskRun(from: decoder)
    }
}
