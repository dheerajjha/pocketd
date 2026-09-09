import Foundation
import LocalLLMClient
import LocalLLMClientMacros
import PocketdKit

/// Reads the user's open reminders, for the user only.
///
/// Completed reminders are never returned: the predicate is
/// `predicateForIncompleteReminders`, so "done last Tuesday" cannot appear in
/// an answer about what is outstanding.
@Tool("get_reminders")
struct RemindersTool {
    let description = "List the user's reminders (to-dos) that are not completed yet."

    @ToolArguments
    struct Arguments {
        @ToolArgument("Which reminders to list.")
        var filter: ReminderFilter
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        // Same gate as the calendar tool, in the same position: before the
        // filter is resolved and before EventKit exists. A network caller must
        // not be able to cause a read of the user's reminders by any path.
        guard ToolContext.origin.mayReachPersonalData else {
            return ToolOutput(["text": ToolContext.refusal])
        }

        let window = PersonalDataRange.reminderWindow(for: arguments.filter, now: Date())

        switch await EventAccess.shared.reminders(in: window) {
        case .unauthorized(let authorization):
            return ToolOutput(["text": authorization.explanation(for: .reminders)])

        case .rows(let rows, let truncated):
            guard !rows.isEmpty else {
                return ToolOutput(["text": arguments.filter.emptyText])
            }
            var data: [String: any Sendable] = ["reminders": rows.map(Self.describe)]
            if rows.contains(where: { $0.priority > 0 }) {
                // Once, at the top, not on every row. EventKit's scale is
                // RFC 5545's — 1 highest, 9 lowest — which is backwards from
                // everything a model has read about "priority 9", and it will
                // rank the list upside down without being told. Twenty copies
                // of that sentence would cost more context than the reminders.
                data["priority_scale"] = "1 is highest, 9 is lowest"
            }
            if truncated {
                data["note"] = "Only the first \(EventAccess.rowLimit) reminders are listed; there are more."
            }
            return ToolOutput(data)
        }
    }

    /// `String` and `Int` only — see the note in `CalendarTools`. In
    /// particular `due` is a literal `"no due date"` rather than a `null`:
    /// `JSONSerialization` throws on `nil`, and a missing key invites the model
    /// to guess a deadline.
    private static func describe(_ row: ReminderRow) -> [String: any Sendable] {
        var fields: [String: any Sendable] = ["title": row.title]

        if let due = row.due {
            fields["due"] = row.dueHasTime
                ? PersonalDataFormat.moment(due)
                : PersonalDataFormat.day(due)
        } else {
            fields["due"] = "no due date"
        }

        // Zero is EventKit's "the user set none", not a priority of zero, and
        // reporting it as one would have the model rank a plain reminder above
        // an urgent one.
        if row.priority > 0 {
            fields["priority"] = row.priority
        }
        return fields
    }
}
