import Foundation
import LocalLLMClient
import LocalLLMClientMacros
import PocketdKit

/// Reads the user's open reminders, for the user only.
///
/// Completed reminders are never returned: the predicate is
/// `predicateForIncompleteReminders`, so "done last Tuesday" cannot appear in
/// an answer about what is outstanding.
///
/// Same split as `CalendarEventsTool` — the decisions live in
/// `PersonalDataTools`, only the EventKit call is here.
@Tool("get_reminders")
struct RemindersTool {
    let description = "List the user's reminders (to-dos) that are not completed yet."

    @ToolArguments
    struct Arguments {
        @ToolArgument("Which reminders to list.")
        var filter: ReminderFilter
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        ToolOutput(await PersonalDataTools.reminderPayload(filter: arguments.filter) { window in
            await EventAccess.shared.reminders(in: window)
        })
    }
}
