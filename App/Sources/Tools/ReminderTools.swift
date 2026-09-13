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
    let description = "List the user's reminders, add a new one, or tick one off."

    @ToolArguments
    struct Arguments {
        @ToolArgument("What to do: list, create or complete.")
        var action: ReminderAction

        @ToolArgument("For list: which reminders to list. Defaults to all open ones.")
        var filter: ReminderFilter?

        @ToolArgument("For create and complete: what the reminder says.")
        var title: String?

        @ToolArgument("For create: when it is due, in the user's own words, like '2am today' or 'tomorrow at 3pm'. Leave out for no due date.")
        var when: String?
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        switch arguments.action {
        case .list:
            // Defaulted rather than refused. `filter` cannot be required now
            // that one tool serves three verbs, and a model that omits it on a
            // list is asking the commonest question there is.
            return ToolOutput(await PersonalDataTools.reminderPayload(filter: arguments.filter ?? .all_open) { window in
                await EventAccess.shared.reminders(in: window)
            })

        case .create:
            return ToolOutput(await PersonalDataWrites.createReminder(
                title: arguments.title,
                when: arguments.when,
                existing: { await EventAccess.shared.reminders(in: DateWindow(start: nil, end: nil)) },
                write: { await EventAccess.shared.createReminder($0) }
            ))

        case .complete:
            return ToolOutput(await PersonalDataWrites.completeReminder(
                title: arguments.title,
                existing: { await EventAccess.shared.reminders(in: DateWindow(start: nil, end: nil)) },
                complete: { row in
                    // A row with no identifier never came from the store, so
                    // there is nothing to tick off. Reported as a failure
                    // rather than silently succeeding on nothing.
                    guard let identifier = row.identifier else { return .failed }
                    return await EventAccess.shared.completeReminder(identifier: identifier)
                }
            ))
        }
    }
}
