import Foundation
import LocalLLMClient
import LocalLLMClientMacros
import PocketdKit

/// Reading and changing the user's reminders.
///
/// One tool with a verb rather than `get_reminders`, `create_reminder` and
/// `complete_reminder` — see `ReminderAction` for the measurement that forced
/// it. The short version: schemas are frozen into the client at model load and
/// charged against every prompt, and six single-purpose tools do not fit the
/// default 4,096-token window on a tool-native template.
///
/// Same split as before: the decisions live in `PersonalDataTools` and
/// `PersonalDataWrites`, only the EventKit calls are here.
@Tool("reminders")
struct RemindersTool {
    // Shorter than the built-in brain's, to pay for the longer `when` — see
    // `CalendarTool.description` for the arithmetic.
    let description = "List, add or tick off the user's reminders."

    @ToolArguments
    struct Arguments {
        // "What to do." and not "What to do: list, create or complete." — the
        // enum in the schema already carries those three words, and at 1,317
        // tokens of a 1,344 ceiling a redundant clause is a capability
        // somebody else does not get.
        @ToolArgument("What to do.")
        var action: ReminderAction

        // Defaulted rather than optional. `@ToolArguments` generates
        // `Arguments.ReminderFilter` for an optional enum — it strips the `?`
        // and then qualifies the bare name with the enclosing type, which does
        // not resolve — so `ReminderFilter?` does not compile at all.
        @ToolArgument("For list: which reminders to list.")
        var filter: ReminderFilter = .all_open

        @ToolArgument("For create and complete: what the reminder says.")
        var title: String?

        // The wording Apple's model was measured with — see `SystemRemindersTool`.
        // The old examples, '2am today' and 'tomorrow at 3pm', put a day on
        // times that had none: "6pm" filed for tomorrow, "at 2am" sent as "2am
        // today".
        @ToolArgument("For create: when it is due, in the user's exact words, like '6pm', 'tomorrow at 9', 'in 20 minutes' or 'every day at 7am'. Never add a day they did not say. Leave out for no due date.")
        var when: String?
    }

    /// The body is `ToolBodies.reminders`, shared with the built-in brain's
    /// wrapper so the two engines cannot answer the same question differently.
    func call(arguments: Arguments) async throws -> ToolOutput {
        ToolOutput(await ToolBodies.reminders(
            action: arguments.action,
            filter: arguments.filter,
            title: arguments.title,
            when: arguments.when
        ))
    }
}
