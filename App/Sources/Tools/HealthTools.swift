import Foundation
import LocalLLMClient
import LocalLLMClientMacros
import PocketdKit

/// Reads the user's health data, for the user only.
///
/// One tool, not five, and the arithmetic in this repo is what decides that.
/// Registering a tool injects its schema into the system message of every
/// prompt. Measured through `ContextGuard.toolOverhead` against this exact
/// generated schema, this one costs 116 guard tokens on a plain chat template
/// and 232 on a tool-native one — the schema is rendered by the template and
/// appended again by the library's instruction processor, so a Qwen3-style model
/// pays for it twice. The usable window at the default 4096 context is 4032.
/// Five health tools would be most of a thousand tokens spent before the user
/// has typed a word, on every question, including the ones about pasta. A single
/// tool with a five-value enum is one schema, and a small model picks from five
/// words far more reliably than it picks between five similarly-named tools.
///
/// The argument is a fixed set of focus names rather than a metric name or a
/// date range, for the same reason `CalendarRange` is: a 1–3B model asked for
/// free-form text produces something plausible and wrong often enough that it
/// has to be planned for, and a closed set of names cannot be malformed. Which days to
/// look at, how long a baseline is, and which day is the last complete one are
/// all decided in `HealthSummary`, where a calendar and a time zone are
/// available and none of them are the model's problem.
///
/// The body is four lines because everything worth being sure about — the
/// origin gate, the mean and the delta, the sentence for data that did not
/// arrive — is in `HealthSummary`, where it can be tested without a device, a
/// Health database or years of recorded days. What is left here is the part that
/// genuinely needs HealthKit.
@Tool("get_health_summary")
struct HealthSummaryTool {
    /// Names what the model gets back, not what the tool reads. "Compared
    /// against the user's own baseline" is the instruction that stops it
    /// inventing a comparison of its own, which is the failure this tool exists
    /// to remove: the arithmetic is already done and correct by the time the
    /// model sees it.
    let description = "Read the user's health data from this iPhone, already compared against their own long-term baseline."

    @ToolArguments
    struct Arguments {
        /// The schema the model sees carries
        /// `HealthFocus.allCases.map { $0.rawValue }` — the macro writes that
        /// expression into the generated schema literally, so the accepted
        /// values and the tested ones are the same list by construction.
        @ToolArgument("Which part of the user's health to look at.")
        var focus: HealthFocus
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        // `origin` is left to its default, which reads `ToolContext.origin` at
        // this call. The origin arrives by task local because tools are frozen
        // into the client at construction and cannot be swapped per request.
        ToolOutput(await HealthSummary.payload(focus: arguments.focus) { focus, window in
            await HealthAccess.shared.readout(for: focus, in: window)
        })
    }
}
