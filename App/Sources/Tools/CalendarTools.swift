import Foundation
import LocalLLMClient
import LocalLLMClientMacros
import PocketdKit

/// Reads the user's calendar, for the user only.
///
/// The argument is a fixed set of range names rather than dates. A model this
/// size, asked for `start_date` and `end_date`, produces ISO strings that are
/// plausible and wrong — off by a week, in the wrong year, or not a date at
/// all — and there is no way to tell a wrong-but-valid date from a right one.
/// Four names cannot be wrong, and `Calendar` does the arithmetic with the
/// user's real time zone and first weekday. See `CalendarRange`.
///
/// The body is four lines because everything worth being sure about — the
/// origin gate, the permission sentence, the shape of a row — is in
/// `PersonalDataTools`, where it can be tested without a device, a granted
/// permission or a calendar with anything in it. What is left here is the part
/// that genuinely needs EventKit.
@Tool("get_calendar_events")
struct CalendarEventsTool {
    let description = "List the user's calendar events (meetings, appointments) for a range of days."

    @ToolArguments
    struct Arguments {
        /// The schema the model sees carries
        /// `CalendarRange.allCases.map { $0.rawValue }` — the macro writes that
        /// expression into the generated schema literally, so the accepted
        /// values and the tested ones are the same list by construction.
        @ToolArgument("Which days to list.")
        var range: CalendarRange
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        // `origin` is left to its default, which reads `ToolContext.origin` at
        // this call. The origin arrives by task local because tools are frozen
        // into the client at construction and cannot be swapped per request.
        ToolOutput(await PersonalDataTools.calendarPayload(range: arguments.range) { window in
            await EventAccess.shared.events(in: window)
        })
    }
}
