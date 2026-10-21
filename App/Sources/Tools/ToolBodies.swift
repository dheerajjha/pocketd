import Foundation
import PocketdKit

/// The calendar, reminders and health tools, as plain functions any engine can
/// call.
///
/// The bodies used to live inside the `@Tool` structs' `call(arguments:)`,
/// where the only way in was the macro's generated `Arguments` type — fine for
/// llama.cpp's loop, and a locked door for anything else. The built-in brain
/// wraps the same three tools in FoundationModels' `Tool`, and two copies of a
/// tool body are two places for the origin gate, the "not connected" sentence
/// and the row cap to drift apart. So the body lives here once, and both the
/// `@Tool` structs and the FoundationModels wrappers are three-line adapters
/// onto it.
///
/// Every function returns the payload dictionary the model reads — strings,
/// numbers and lists only, the shape `ToolOutput` serialises — and never
/// throws: an error leaving a tool body ends the generation mid-sentence.
/// `json(_:)` renders one as compact text for an engine that wants a string.
///
/// `origin` defaults to the task-local `ToolContext.origin`, which itself
/// defaults to a network caller — so an engine that forgets to say who is
/// asking gets a refusal, not somebody's calendar. The phone's own chat passes
/// `.onDeviceChat`.
enum ToolBodies {

    // MARK: - Calendar

    /// `calendar`: list a range of days, or add an event.
    ///
    /// `userText` is the person's latest message, which decides whether the
    /// model's `durationMinutes` is believed at all (`EventLength`). It defaults
    /// to the task local `LlamaEngine` binds around a whole generation; the
    /// built-in brain passes it.
    static func calendar(
        action: CalendarAction,
        range: CalendarRange = .today,
        title: String? = nil,
        start: String? = nil,
        durationMinutes: Int? = nil,
        userText: String? = ToolContext.userText,
        origin: RequestOrigin = ToolContext.origin
    ) async -> [String: any Sendable] {
        switch action {
        case .list:
            return await PersonalDataTools.calendarPayload(range: range, origin: origin) { window in
                await EventAccess.shared.events(in: window)
            }
        case .create:
            return await PersonalDataWrites.createEvent(
                title: title,
                start: start,
                durationMinutes: durationMinutes,
                userText: userText,
                origin: origin,
                write: { await EventAccess.shared.createEvent($0) }
            )
        }
    }

    // MARK: - Reminders

    /// `reminders`: list, add, or tick one off by title.
    static func reminders(
        action: ReminderAction,
        filter: ReminderFilter = .all_open,
        title: String? = nil,
        when: String? = nil,
        origin: RequestOrigin = ToolContext.origin
    ) async -> [String: any Sendable] {
        switch action {
        case .list:
            // Defaulted rather than refused. `filter` cannot be required now
            // that one tool serves three verbs, and a model that omits it on a
            // list is asking the commonest question there is.
            return await PersonalDataTools.reminderPayload(filter: filter, origin: origin) { window in
                await EventAccess.shared.reminders(in: window)
            }
        case .create:
            return await PersonalDataWrites.createReminder(
                title: title,
                when: when,
                origin: origin,
                existing: { await EventAccess.shared.reminders(in: DateWindow(start: nil, end: nil)) },
                write: { await EventAccess.shared.createReminder($0) }
            )
        case .complete:
            return await PersonalDataWrites.completeReminder(
                title: title,
                origin: origin,
                existing: { await EventAccess.shared.reminders(in: DateWindow(start: nil, end: nil)) },
                complete: { row in
                    // A row with no identifier never came from the store, so
                    // there is nothing to tick off. Reported as a failure
                    // rather than silently succeeding on nothing.
                    guard let identifier = row.identifier else { return .failed }
                    return await EventAccess.shared.completeReminder(identifier: identifier)
                }
            )
        }
    }

    // MARK: - Health

    /// `get_health_summary`: one focus, already compared with the person's own
    /// baseline.
    static func health(
        focus: HealthFocus,
        origin: RequestOrigin = ToolContext.origin
    ) async -> [String: any Sendable] {
        await HealthSummary.payload(focus: focus, origin: origin) { focus, window in
            await HealthAccess.shared.readout(for: focus, in: window)
        }
    }

    // MARK: - As text

    /// The payload as compact JSON, keys sorted so the same answer is the same
    /// bytes.
    ///
    /// Every value a tool body produces is a string, a number, a `Bool` or a
    /// list of those, which `JSONSerialization` takes as it is. Anything it
    /// would refuse falls back to the payload's `text`, and then to a sentence
    /// — a tool result is never an empty string.
    static func json(_ payload: [String: any Sendable]) -> String {
        let object = payload.mapValues { $0 as Any }
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return payload["text"] as? String ?? "Nothing came back."
    }
}
