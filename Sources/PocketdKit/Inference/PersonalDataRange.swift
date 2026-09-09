import Foundation

// MARK: - What the model is allowed to ask for

/// The only shapes of calendar question the tool accepts.
///
/// Deliberately not a free-form date. A 1–3B model asked for an ISO string
/// emits `2025-13-01`, `next monday`, or a date in the year 0002 often enough
/// that it has to be planned for, and every malformed value has to be either
/// rejected — which the model reads as a failure and retries, burning a whole
/// extra prefill — or guessed at. Four fixed values cannot be malformed. The
/// arithmetic happens here instead, where a calendar, a time zone and the
/// user's first weekday are all available and none of them are the model's
/// problem.
///
/// The raw values are the `enum` the model literally sees in the tool schema,
/// so they are snake_case, which is what every tool-trained chat template uses.
public enum CalendarRange: String, Sendable, Codable, CaseIterable {
    case today
    case tomorrow
    case this_week
    case next_week

    /// What the tool says when the range resolved fine and simply held nothing.
    ///
    /// This must never be confusable with a permission failure. A model handed
    /// an empty list with no explanation will cheerfully invent a meeting; a
    /// model handed "No events today." says so.
    public var emptyText: String {
        switch self {
        case .today: "No events today."
        case .tomorrow: "No events tomorrow."
        case .this_week: "No events this week."
        case .next_week: "No events next week."
        }
    }
}

/// The only shapes of reminder question the tool accepts. Same reasoning.
public enum ReminderFilter: String, Sendable, Codable, CaseIterable {
    case overdue
    case today
    case tomorrow
    case this_week
    case all_open

    public var emptyText: String {
        switch self {
        case .overdue: "Nothing is overdue."
        case .today: "No reminders are due today."
        case .tomorrow: "No reminders are due tomorrow."
        case .this_week: "No reminders are due this week."
        case .all_open: "No open reminders."
        }
    }
}

// MARK: - Windows

/// A half-open window `[start, end)`, either end optionally unbounded.
///
/// Shaped to match EventKit's
/// `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)`,
/// which takes two optional dates and means something specific by `nil`:
/// both `nil` is the only combination that also returns reminders with no due
/// date at all.
public struct DateWindow: Sendable, Equatable {
    public var start: Date?
    public var end: Date?

    public init(start: Date?, end: Date?) {
        self.start = start
        self.end = end
    }

    public var isUnbounded: Bool { start == nil && end == nil }

    /// Half-open on purpose: midnight belongs to the day it opens, not the one
    /// it closes, so "today" and "tomorrow" cannot both claim the same event.
    public func contains(_ date: Date) -> Bool {
        if let start, date < start { return false }
        if let end, date >= end { return false }
        return true
    }
}

/// Turns a range name into actual dates.
///
/// Every function takes `now` and a `Calendar` rather than reading
/// `Date()`/`.current`, which is the whole reason this can be tested off a
/// device: week boundaries, first-weekday handling and daylight saving are all
/// exercised against fixed inputs.
public enum PersonalDataRange {

    /// Events always want a bounded interval —
    /// `predicateForEvents(withStart:end:calendars:)` has no optional ends.
    ///
    /// A week here is the user's *calendar* week, not "the next seven days":
    /// it starts on `calendar.firstWeekday`, which is Sunday in the US, Monday
    /// across most of Europe, and Saturday in much of the Gulf. `this_week`
    /// therefore includes days that have already gone — asked on a Thursday it
    /// still reports Monday's meetings. That is the literal meaning of the
    /// word, and truncating it at `now` would make "what did I have this week"
    /// unanswerable while saving nothing.
    ///
    /// The interval is meant half-open, `[start, end)`, but `DateInterval` is
    /// not: Foundation's `contains` answers true for `end`, so consecutive
    /// windows both claim the closing midnight. Callers bucket on
    /// `startDate < window.end` rather than `contains`.
    public static func eventWindow(for range: CalendarRange, now: Date, calendar: Calendar = .current) -> DateInterval {
        switch range {
        case .today:
            day(containing: now, calendar: calendar)
        case .tomorrow:
            day(containing: calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400),
                calendar: calendar)
        case .this_week:
            week(containing: now, calendar: calendar)
        case .next_week:
            week(containing: calendar.date(byAdding: .weekOfYear, value: 1, to: now) ?? now.addingTimeInterval(7 * 86_400),
                 calendar: calendar)
        }
    }

    /// Reminders want optional ends, because two of the five filters have one.
    public static func reminderWindow(for filter: ReminderFilter, now: Date, calendar: Calendar = .current) -> DateWindow {
        switch filter {
        case .overdue:
            // Open at the bottom: a reminder from last year is still overdue.
            // Note the wrinkle this inherits from EventKit — a reminder due on
            // a date with no time of day resolves to midnight, so it reads as
            // overdue from 00:01 on the day it is due. The returned due date
            // string makes that visible to the user rather than hiding it.
            DateWindow(start: nil, end: now)
        case .today:
            Self.bounded(eventWindow(for: .today, now: now, calendar: calendar))
        case .tomorrow:
            Self.bounded(eventWindow(for: .tomorrow, now: now, calendar: calendar))
        case .this_week:
            Self.bounded(eventWindow(for: .this_week, now: now, calendar: calendar))
        case .all_open:
            // Both ends nil is not "no filter" to EventKit — it is the only
            // way to also get the reminders that have no due date, which are
            // most of them for most people.
            DateWindow(start: nil, end: nil)
        }
    }

    // MARK: - Pieces

    /// Midnight to midnight, in the calendar's own time zone.
    ///
    /// `startOfDay` rather than subtracting a time interval: on a
    /// spring-forward day in a zone that jumps at midnight there is no 00:00,
    /// and this is the only API that knows that.
    static func day(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// The calendar week containing `date`, honouring `calendar.firstWeekday`.
    static func week(containing date: Date, calendar: Calendar) -> DateInterval {
        if let interval = calendar.dateInterval(of: .weekOfYear, for: date) {
            return interval
        }
        // Only reachable if the calendar cannot express weeks at all. Falling
        // back to the single day is wrong but bounded; returning nothing would
        // make the tool look broken.
        return day(containing: date, calendar: calendar)
    }

    private static func bounded(_ interval: DateInterval) -> DateWindow {
        DateWindow(start: interval.start, end: interval.end)
    }
}

// MARK: - Dates on their way to the model

/// Turns dates into strings before they go anywhere near a tool result.
///
/// `ToolOutput` is handed to `JSONSerialization`, which throws on a `Date`.
/// LocalLLMClient catches that and silently falls back to Swift's
/// `"\(value)"` description — so a `Date` that slips through does not crash,
/// it quietly reaches the model as `2025-09-11 13:00:00 +0000`, in UTC, with no
/// weekday. Formatting here, in the user's locale and zone, is the only way the
/// model ever sees the time the user would recognise.
public enum PersonalDataFormat {

    /// A moment with a time of day, e.g. `Thu 11 Sep, 14:30`.
    ///
    /// The year is left out deliberately: it is four characters and a comma on
    /// every single row, and no range this tool accepts can span a year in a
    /// way the weekday does not already disambiguate.
    public static func moment(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
                .weekday(.abbreviated)
                .day()
                .month(.abbreviated)
                .hour()
                .minute()
        )
    }

    /// A whole day with no time of day, e.g. `Thu 11 Sep`. Used for all-day
    /// events and for reminders due on a date rather than at a time — printing
    /// `00:00` for those tells the model a lie it will repeat.
    public static func day(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
                .weekday(.abbreviated)
                .day()
                .month(.abbreviated)
        )
    }
}
