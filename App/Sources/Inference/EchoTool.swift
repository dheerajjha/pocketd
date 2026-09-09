import Foundation
import LocalLLMClient
import PocketdKit

/// A tool that does nothing, so that a failure means the loop is broken.
///
/// The real tools read EventKit, which needs a device, a permission prompt and
/// a calendar with something in it. When one of those fails, "the model did not
/// answer" has half a dozen possible causes and no way to tell them apart. This
/// one has no arguments to mis-parse, no permission to be denied and no
/// dependency to be missing, so if the model calls it and the answer comes back
/// with `pocketd_selftest_ok` in it, the substrate works: the template emitted a
/// call, the parser found it, our dispatch table matched it, the result
/// serialised, and the resume pass read it. Anything left after that is
/// EventKit's problem.
///
/// Not registered by default — see `AppModel`. Registering any tool costs every
/// prompt a preamble.
struct EchoTool: LLMTool {
    let name = "pocketd_selftest"
    let description = "Returns a fixed confirmation string. Call this when asked to test tool calling."

    /// No fields on purpose. `JSONDecoder` accepts `{}` and ignores anything
    /// else an over-eager model decides to send, so this tool cannot fail at
    /// the argument step — which is what makes a failure elsewhere meaningful.
    struct Arguments: Decodable, ToolSchemaGeneratable {
        static var argumentsSchema: LLMToolArgumentsSchema { [:] }
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        ToolOutput(data: [
            "status": "pocketd_selftest_ok",
            // Proves the task local survives the trip: `LlamaEngine.generate`
            // binds it, and this body — several `await`s and one library
            // AsyncStream later — reads it back. Every real tool's refusal
            // check rides on that being true.
            "asked_by": ToolContext.origin.loggingDescription,
            "may_reach_personal_data": ToolContext.origin.mayReachPersonalData
        ])
    }
}
