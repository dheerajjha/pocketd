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
        // First, before the range is even resolved, and long before EventKit is
        // touched: a network client asking this must cause no read of the
        // user's calendar at all. Not a filtered read, not an empty one — none.
        // The origin arrives by task local because tools are frozen into the
        // client at construction and cannot be swapped per request.
        guard ToolContext.origin.mayReachPersonalData else {
            return ToolOutput(["text": ToolContext.refusal])
        }

        let window = PersonalDataRange.eventWindow(for: arguments.range, now: Date())

        switch await EventAccess.shared.events(in: window) {
        case .unauthorized(let authorization):
            // Not a throw. An error propagating out of a tool body ends the
            // generation, and the user sees the stream stop with nothing said.
            // Not an empty list either: a model handed one confabulates a
            // day's meetings rather than reporting a permission problem.
            return ToolOutput(["text": authorization.explanation(for: .calendar)])

        case .rows(let rows, let truncated):
            guard !rows.isEmpty else {
                return ToolOutput(["text": arguments.range.emptyText])
            }
            var data: [String: any Sendable] = ["events": rows.map(Self.describe)]
            if truncated {
                data["note"] = "Only the first \(EventAccess.rowLimit) events are listed; there are more."
            }
            return ToolOutput(data)
        }
    }

    /// Everything here is `String` or `Bool` on purpose.
    ///
    /// `ToolOutput` is handed straight to `JSONSerialization`, which throws on
    /// a `Date`, on `Data`, on `nil` and on a non-finite `Double`.
    /// LocalLLMClient swallows that throw and falls back to interpolating the
    /// dictionary, so the failure is not a crash or an error — it is the model
    /// quietly receiving `2025-09-11 13:00:00 +0000` in UTC, and telling the
    /// user their 2pm meeting is at one o'clock. Optionals are handled by
    /// leaving the key out, never by writing a null.
    private static func describe(_ row: CalendarEventRow) -> [String: any Sendable] {
        var fields: [String: any Sendable] = [
            "title": row.title,
            "all_day": row.isAllDay
        ]
        if row.isAllDay {
            // An all-day event has no meaningful clock time; EventKit stores
            // midnight to 23:59:59 and printing that invents a schedule.
            fields["start"] = PersonalDataFormat.day(row.start)
            fields["end"] = PersonalDataFormat.day(row.end)
        } else {
            fields["start"] = PersonalDataFormat.moment(row.start)
            fields["end"] = PersonalDataFormat.moment(row.end)
        }
        if let location = row.location {
            fields["location"] = location
        }
        return fields
    }
}
