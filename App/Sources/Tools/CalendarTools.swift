import Foundation
import LocalLLMClient
import LocalLLMClientMacros
import PocketdKit

/// Reading and adding to the user's calendar.
///
/// No `delete` and no `edit`, deliberately. An assistant that can add is
/// useful and an assistant that can destroy is a liability — see
/// `PersonalDataWrites.completeReminder` for the same line drawn on the
/// reminders side, where ticking off is allowed precisely because it can be
/// undone.
@Tool("calendar")
struct CalendarTool {
    let description = "List events from the user's calendar, or add a new one."

    @ToolArguments
    struct Arguments {
        @ToolArgument("What to do.")
        var action: CalendarAction

        @ToolArgument("For list: which days to list. Defaults to today.")
        var range: CalendarRange?

        @ToolArgument("For create: what the event is called.")
        var title: String?

        @ToolArgument("For create: when it starts, in the user's own words, like 'tomorrow at 3pm'.")
        var start: String?

        @ToolArgument("For create: how many minutes it lasts. Defaults to 60.")
        var duration_minutes: Int?
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        switch arguments.action {
        case .list:
            return ToolOutput(await PersonalDataTools.calendarPayload(range: arguments.range ?? .today) { window in
                await EventAccess.shared.events(in: window)
            })

        case .create:
            return ToolOutput(await PersonalDataWrites.createEvent(
                title: arguments.title,
                start: arguments.start,
                durationMinutes: arguments.duration_minutes,
                write: { await EventAccess.shared.createEvent($0) }
            ))
        }
    }
}
