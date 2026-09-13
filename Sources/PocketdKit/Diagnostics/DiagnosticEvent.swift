import Foundation

/// One thing worth knowing when the app misbehaves on a real phone.
///
/// A closed enum, and that is the entire security design of this file rather
/// than a stylistic preference. This log exists to be copied out of Settings
/// and pasted into a chat with someone helping to debug — which means every
/// byte it can hold is a byte that leaves the device. An open
/// `log(_ message: String)` would make that safe only by everyone remembering,
/// at every call site forever, not to interpolate the thing they are looking
/// at. They would not remember: the call sites that matter are the tool bodies,
/// and the variable in scope there is the reminder's title.
///
/// So no case takes a title, a prompt, a model output, a message body, a file
/// path, a host name or a free-form string of any kind. What a case may carry
/// is a number, a `Bool`, a date, a value from a closed vocabulary declared in
/// this package, or an identifier the *app* minted — a model id from the
/// catalogue, a tool name from a registration. `DiagnosticRedactionTests`
/// asserts this by rendering every case and looking for the content it must
/// never be able to hold.
///
/// The other half of "do not spam it" is that these are events, not traces.
/// Nothing here fires per token, per frame or per HTTP request; `RequestLog`
/// already does the last of those and is a different feature with a different
/// audience.
public enum DiagnosticEvent: Sendable, Equatable {

    // MARK: - The model

    /// A load finished, one way or the other. `milliseconds` is what the user
    /// experienced as the spinner, which is the number that makes "it feels
    /// slow" actionable.
    case modelLoad(id: String, contextTokens: Int, outcome: Outcome, milliseconds: Int)
    /// Weights left RAM. The reason matters more than the fact: a background
    /// offload is the design working, and a jetsam is the phone disagreeing.
    case modelOffloaded(reason: OffloadReason)

    // MARK: - Why the tools are or are not there

    /// `ToolGate.Decision`, flattened to its case name.
    ///
    /// The first question to ask when the assistant says it cannot do
    /// something it should be able to do, and it is invisible from the outside:
    /// a model the gate refuses is handed no tools at all and simply talks like
    /// a chatbot about it.
    case toolGate(decision: String, modelID: String?)
    /// What the budget admitted, what it dropped, and what it cost.
    ///
    /// The second question, and the one this app is most likely to get wrong,
    /// because the ceiling is a third of a window that defaults to 4,096 and
    /// a tool-native chat template pays for every schema twice. A capability
    /// that is switched on, gated in, and then dropped here is indistinguishable
    /// to the user from one that is broken.
    case toolPlan(admitted: [String], dropped: [String], tokens: Int, ceiling: Int, fit: String)
    /// A tool actually ran. Never the arguments and never the result — only
    /// which tool, how it ended, and how long it took.
    case toolCall(name: String, outcome: ToolOutcome, milliseconds: Int)

    // MARK: - iOS saying no

    /// Where a permission stands, in this package's vocabulary rather than
    /// EventKit's or HealthKit's.
    case permission(entity: String, status: String)

    // MARK: - Generations and schedules

    /// How a generation ended. `stop` is a closed vocabulary — see `Stop`.
    case generation(promptTokens: Int, outputTokens: Int, milliseconds: Int, stop: Stop)
    /// A scheduled task fired.
    ///
    /// Carries the first eight characters of the id and nothing else. Not the
    /// title, which the user wrote; not the prompt, which is the whole point of
    /// the feature; not the output, which is the model's reading of their
    /// calendar. The id is enough to tell two tasks apart across a log.
    case scheduleRun(taskPrefix: String, outcome: String, milliseconds: Int)

    // MARK: - The server

    case serverStarted(port: UInt16)
    case serverStopped
    /// A client connected. No host, no address: on a LAN that is a
    /// device fingerprint, and the useful fact is only that something arrived.
    case clientConnected(isOnDevice: Bool)

    // MARK: - Trouble

    /// Something failed in a way worth reporting. `code` is a short stable
    /// identifier chosen at the call site — never an `error.localizedDescription`,
    /// which on iOS regularly interpolates a file path or a URL.
    case failure(area: Area, code: String)
    /// iOS asked for memory back.
    case memoryWarning

    // MARK: - Closed vocabularies

    public enum Outcome: String, Sendable, Equatable {
        case ok, failed, cancelled
    }

    public enum OffloadReason: String, Sendable, Equatable {
        case background, idle, userRequested, memoryPressure, modelSwitch
    }

    public enum ToolOutcome: String, Sendable, Equatable {
        case ok
        /// The tool ran and had nothing to report — not an error, and the
        /// distinction is the one users misread as a bug.
        case empty
        /// `RequestOrigin` refused it: a network caller reaching for personal
        /// data, or for a write.
        case refusedByOrigin
        /// iOS refused it.
        case unauthorised
        /// The model called it with arguments that could not be used.
        case badArguments
        case failed
    }

    public enum Stop: String, Sendable, Equatable {
        case completed
        case cancelled
        /// The prompt did not fit. The single most useful stop reason in this
        /// app, because it is the one the tool budget can cause.
        case contextExhausted
        case failed
    }

    public enum Area: String, Sendable, Equatable {
        case model, tools, eventKit, healthKit, schedule, server, storage, widgets
    }
}
