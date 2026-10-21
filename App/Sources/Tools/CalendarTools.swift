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
    // Shorter than the built-in brain's description, to pay for the longer
    // `start`. With the measured wording in `start` and `when`, the three
    // schemas came to 1,361 guard tokens on a tool-native template against a
    // 1,344 ceiling at the default 4,096 window — and the budget's answer to
    // that is to drop the health tool. The cuts here, in `duration_minutes`
    // and in the reminders tool's description bring it to 1,331, and change
    // nothing a model needs: the action enum already says list or create.
    let description = "List or add events in the user's calendar."

    @ToolArguments
    struct Arguments {
        @ToolArgument("What to do.")
        var action: CalendarAction

        // Defaulted, not optional — see `RemindersTool.Arguments.filter` for
        // what the macro does with an optional enum.
        @ToolArgument("For list: which days to list.")
        var range: CalendarRange = .today

        @ToolArgument("For create: what the event is called.")
        var title: String?

        // The wording Apple's model was measured with — see `SystemCalendarTool`.
        // The old example put a day on "add dinner with Priya at 8pm".
        @ToolArgument("For create: when it starts, in the user's exact words, like '3pm', 'Friday at 1pm' or 'tomorrow at 9'. Never add a day they did not say.")
        var start: String?

        // Believed only when the user's own words say how long, and an hour
        // otherwise, whatever the model writes here: `EventLength`. So the
        // default is the body's to apply, and not worth a schema token.
        @ToolArgument("For create: how many minutes it lasts.")
        var duration_minutes: Int?
    }

    /// The body is `ToolBodies.calendar`, shared with the built-in brain's
    /// wrapper so the two engines cannot answer the same question differently.
    func call(arguments: Arguments) async throws -> ToolOutput {
        ToolOutput(await ToolBodies.calendar(
            action: arguments.action,
            range: arguments.range,
            title: arguments.title,
            start: arguments.start,
            durationMinutes: arguments.duration_minutes
        ))
    }
}
