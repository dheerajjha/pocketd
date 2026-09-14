import Foundation

// MARK: - What comes back

/// One event, reduced to values that can leave the actor that read it.
///
/// `EKEvent` is a reference type EventKit owns, mutates behind your back on a
/// store refresh, and does not mark `Sendable`. Handing one to a tool body
/// would be a data race the compiler cannot see through a completion handler,
/// so nothing but this struct crosses the boundary.
///
/// It lives here, and not beside `EKEventStore` in the app target, for the same
/// reason `PersonalDataAuthorization` does: what the model ends up reading is
/// decided by pure functions over these rows, and pure functions are worth
/// testing on a machine with no calendar database and no simulator.
public struct CalendarEventRow: Sendable, Equatable {
    /// Whatever the invite said.
    ///
    /// `Untrusted` rather than `String` because this is the one field on the
    /// row that someone other than the user writes. A meeting invite from a
    /// stranger, a subscribed holiday feed, an `.ics` attachment opened by
    /// accident — all of them land here verbatim, and all of them are read into
    /// the prompt on the next question about the day. Interpolating it is
    /// therefore handing a stranger a line in the conversation, and the type is
    /// what makes that a decision rather than a typo.
    public var title: Untrusted<String>
    public var start: Date
    public var end: Date
    /// Written by the same stranger, and worse: a location is free text that
    /// nothing validates, so it is the longest field on the row that an
    /// attacker fully controls.
    public var location: Untrusted<String>?
    public var isAllDay: Bool

    /// Plain strings in, wrapped text out. This initialiser is the boundary:
    /// everything that builds a row is reading EventKit, so there is no caller
    /// for whom the text is trusted and no argument for making them say so.
    public init(title: String, start: Date, end: Date, location: String? = nil, isAllDay: Bool = false) {
        self.title = Untrusted(title)
        self.start = start
        self.end = end
        self.location = location.map { Untrusted($0) }
        self.isAllDay = isAllDay
    }
}

/// One incomplete reminder, same reasoning.
public struct ReminderRow: Sendable, Equatable {
    /// Usually the user's own words, and that is exactly why it cannot be
    /// trusted as a type. A shared list is writable by everyone on it, and a
    /// reminder filed by someone else is indistinguishable here from one the
    /// user typed. The field cannot tell them apart, so it assumes the worse.
    public var title: Untrusted<String>
    public var due: Date?
    /// A reminder can be due on a *date* with no time of day. Printing 00:00
    /// for those tells the model something the user never said.
    public var dueHasTime: Bool
    /// EventKit's scale: 1 highest, 9 lowest, 0 meaning the user set none.
    public var priority: Int
    /// EventKit's own handle on this reminder, when the row came from EventKit.
    ///
    /// Carried so that ticking one off addresses the reminder the user meant
    /// rather than re-running the title search and hoping it lands on the same
    /// one. It is an opaque store identifier, not content: it says nothing
    /// about what the reminder is, which is why it can sit on a row whose title
    /// is `Untrusted`.
    ///
    /// Optional because the rows in tests and previews were never in a store.
    public var identifier: String?
    /// How often this one comes back, when EventKit says it does.
    ///
    /// Carried for the duplicate check rather than for the model, which never
    /// sees it: a daily "take the pills" and a one-off "take the pills" at the
    /// same hour are different reminders, and treating them as the same one
    /// would silently drop the repetition the user asked for.
    public var repeats: ReminderRepeat?

    public init(
        title: String,
        due: Date? = nil,
        dueHasTime: Bool = false,
        priority: Int = 0,
        identifier: String? = nil,
        repeats: ReminderRepeat? = nil
    ) {
        self.title = Untrusted(title)
        self.due = due
        self.dueHasTime = dueHasTime
        self.priority = priority
        self.identifier = identifier
        self.repeats = repeats
    }
}

/// Rows, or the reason there are none. Never an error.
///
/// A thrown error from a tool body propagates out of the inference library's
/// executor and ends the generation — the user watches the stream stop
/// mid-sentence with nothing to read. Every failure mode here is a value
/// instead.
public enum PersonalDataLookup<Row: Sendable>: Sendable {
    case rows([Row], truncated: Bool)
    case unauthorized(PersonalDataAuthorization)
}

// MARK: - The tool bodies

/// Everything the calendar and reminder tools do, minus EventKit.
///
/// The tools themselves are four lines each in the app target, and that split is
/// deliberate. The parts worth being sure about — that a network caller causes
/// no read at all, that a refused permission comes back as a sentence rather
/// than a thrown error, that a `Date` never reaches `JSONSerialization` — need
/// neither a device nor a granted permission to exercise, and were untestable
/// only because they were written on the far side of an `EKEventStore`. Here the
/// store arrives as a closure, so a test can hand over a spy and assert on what
/// it was *not* asked to do.
public enum PersonalDataTools {

    /// Cap on rows. Twenty is not arbitrary: a phone-sized model gets roughly
    /// 40–60 tokens per row of JSON, so twenty events is around a thousand
    /// tokens of context that the answer then has to fit alongside.
    public static let rowLimit = 20

    /// - Parameter read: The actual calendar read. Never called for an origin
    ///   that may not have the data — the refusal is decided before this
    ///   closure exists, which is the property `origin refusal` tests assert.
    public static func calendarPayload(
        range: CalendarRange,
        now: Date = Date(),
        origin: RequestOrigin = ToolContext.origin,
        read: @Sendable (DateInterval) async -> PersonalDataLookup<CalendarEventRow>
    ) async -> [String: any Sendable] {
        // First, before the range is even resolved, and long before EventKit is
        // touched: a network client asking this must cause no read of the
        // user's calendar at all. Not a filtered read, not an empty one — none.
        guard origin.mayReachPersonalData else {
            return ["text": ToolContext.refusal]
        }

        switch await read(PersonalDataRange.eventWindow(for: range, now: now)) {
        case .unauthorized(let authorization):
            // Not a throw. An error propagating out of a tool body ends the
            // generation, and the user sees the stream stop with nothing said.
            // Not an empty list either: a model handed one confabulates a
            // day's meetings rather than reporting a permission problem.
            return ["text": authorization.explanation(for: .calendar)]

        case .rows(let rows, let truncated):
            guard !rows.isEmpty else {
                return ["text": range.emptyText]
            }
            var data: [String: any Sendable] = ["events": rows.map(describe)]
            if truncated {
                data["note"] = "Only the first \(rowLimit) events are listed; there are more."
            }
            return data
        }
    }

    /// Same gate in the same position, for the same reason.
    public static func reminderPayload(
        filter: ReminderFilter,
        now: Date = Date(),
        origin: RequestOrigin = ToolContext.origin,
        read: @Sendable (DateWindow) async -> PersonalDataLookup<ReminderRow>
    ) async -> [String: any Sendable] {
        guard origin.mayReachPersonalData else {
            return ["text": ToolContext.refusal]
        }

        switch await read(PersonalDataRange.reminderWindow(for: filter, now: now)) {
        case .unauthorized(let authorization):
            return ["text": authorization.explanation(for: .reminders)]

        case .rows(let rows, let truncated):
            guard !rows.isEmpty else {
                return ["text": filter.emptyText]
            }
            var data: [String: any Sendable] = ["reminders": rows.map(describe)]
            if rows.contains(where: { $0.priority > 0 }) {
                // Once, at the top, not on every row. EventKit's scale is
                // RFC 5545's — 1 highest, 9 lowest — which is backwards from
                // everything a model has read about "priority 9", and it will
                // rank the list upside down without being told. Twenty copies
                // of that sentence would cost more context than the reminders.
                data["priority_scale"] = "1 is highest, 9 is lowest"
            }
            if truncated {
                data["note"] = "Only the first \(rowLimit) reminders are listed; there are more."
            }
            return data
        }
    }

    // MARK: - Rows on their way to the model

    /// Everything here is `String` or `Bool` on purpose.
    ///
    /// `ToolOutput` is handed straight to `JSONSerialization`, which throws on
    /// a `Date`, on `Data`, on `nil` and on a non-finite `Double`.
    /// LocalLLMClient swallows that throw and falls back to interpolating the
    /// dictionary, so the failure is not a crash or an error — it is the model
    /// quietly receiving `2025-09-11 13:00:00 +0000` in UTC, and telling the
    /// user their 2pm meeting is at one o'clock. Optionals are handled by
    /// leaving the key out, never by writing a null.
    static func describe(_ row: CalendarEventRow) -> [String: any Sendable] {
        // `sanitisedForPrompt` and not `attackerControlledValue` for the two
        // fields a stranger writes. JSON escaping is no defence here: it quotes
        // a double quote and leaves `<|im_start|>` exactly as it found it, so
        // an event title is a free line in the prompt unless something takes
        // the syntax out of it first. What the card shows is built from this
        // same dictionary, which is the other half of why it happens here —
        // the model and the user read one rendering, not two.
        var fields: [String: any Sendable] = [
            "title": row.title.sanitisedForPrompt(),
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
            fields["location"] = location.sanitisedForPrompt()
        }
        return fields
    }

    /// `String` and `Int` only — see the note above. In particular `due` is a
    /// literal `"no due date"` rather than a `null`: `JSONSerialization` throws
    /// on `nil`, and a missing key invites the model to guess a deadline.
    static func describe(_ row: ReminderRow) -> [String: any Sendable] {
        // Same reasoning as the event title above, and the same accessor.
        var fields: [String: any Sendable] = ["title": row.title.sanitisedForPrompt()]

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
