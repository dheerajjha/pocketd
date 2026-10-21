import Foundation

// The two detail pages that come from EventKit — Your day and Reminders — as
// values, with the grouping and the one-line summaries decided here.
//
// Read directly and never generated: a detail page is the screen somebody opens
// to check what a tile or the brief told them, so it must be the plain facts in
// the same words the tile used. The rows are built by the app's readers; every
// rule about which group a row lands in and what the grey line under the title
// says is a pure function here, where it can be tested on a machine with no
// calendar database.

// MARK: - Events

/// One event on the Your day page.
///
/// A parallel type to `BriefEvent` rather than a reuse of it, for the reason
/// that type gives in reverse: `BriefEvent` is written to disk every morning and
/// carries nothing it does not need, while this one lives only as long as the
/// page and carries the handles the page's two links need — the event to open
/// in Calendar and the place to get directions to.
public struct DayEvent: Sendable, Equatable, Identifiable {
    /// Unique per occurrence. A repeating event's occurrences share EventKit's
    /// identifier, so the start time is folded in; a list keyed on the
    /// identifier alone would draw Monday's standup in place of Tuesday's.
    public var id: String
    /// EventKit's `eventIdentifier`, for an `EKEventViewController`. Opaque;
    /// never shown and never sent anywhere.
    public var eventIdentifier: String?
    /// EventKit's `calendarItemIdentifier`, for
    /// `EKEventStore.calendarItem(withIdentifier:)`. The same caveats.
    public var calendarItemIdentifier: String?
    public var title: String
    public var location: String?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool

    /// Plain strings in, neutralised text out — the same boundary `BriefEvent`
    /// draws. A title and a location are written by whoever sent the invite,
    /// and this page puts them on a card and into the suggested question.
    public init(
        eventIdentifier: String?,
        calendarItemIdentifier: String? = nil,
        title: String,
        location: String? = nil,
        start: Date,
        end: Date,
        isAllDay: Bool = false
    ) {
        let place = location.map { Untrusted($0).sanitisedForPrompt() }
        self.eventIdentifier = eventIdentifier
        self.calendarItemIdentifier = calendarItemIdentifier
        self.title = Untrusted(title).sanitisedForPrompt()
        self.location = (place?.isEmpty ?? true) ? nil : place
        self.start = start
        self.end = max(end, start)
        self.isAllDay = isAllDay
        self.id = "\(eventIdentifier ?? self.title)@\(Int(start.timeIntervalSinceReferenceDate))"
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Whether the row offers "Directions".
    public var hasLocation: Bool { location != nil }

    /// Calendar, opened at this event's day and time.
    ///
    /// `calshow:` with seconds since 2001 is the one link iOS gives into the
    /// Calendar app, and it lands on the right occurrence of a repeating event
    /// — something opening by identifier cannot promise.
    public var calendarURL: URL {
        URL(string: "calshow:\(Int(start.timeIntervalSinceReferenceDate))")!
    }

    /// Maps, with directions to the event's place. Only ever opened by a tap
    /// on "Directions"; nothing is looked up before that.
    public var directionsURL: URL? {
        // `.urlQueryAllowed` leaves `&`, `=` and `+` alone, and "Smith & Co"
        // would end the query at the ampersand. The place is one value, so
        // only what is safe inside one value survives unescaped.
        let valueSafe = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        guard let location,
              let query = location.addingPercentEncoding(withAllowedCharacters: valueSafe),
              !query.isEmpty
        else { return nil }
        return URL(string: "maps://?daddr=\(query)")
    }

    /// The time on the right of the row: `1:00 PM`, or `All day`.
    public func timeText(calendar: Calendar = .current, locale: Locale = .current) -> String {
        isAllDay ? "All day" : Format.time(start, calendar: calendar, locale: locale)
    }

    /// The grey line under the title: `The Arches · 1h`, `45 min`, `All day`.
    public func detailText() -> String {
        let length = isAllDay ? "All day" : Format.duration(duration)
        guard let location else { return length }
        return "\(location) · \(length)"
    }

    /// In progress at `now`. An all-day event counts for the whole of its day.
    public func isHappening(at now: Date) -> Bool {
        start <= now && now < end
    }
}

/// The Your day page: NOW · LATER TODAY · TOMORROW.
public struct DayAgenda: Sendable, Equatable {

    public enum Group: String, Sendable, Equatable, CaseIterable {
        case now, laterToday, tomorrow

        /// Sentence case; the view decides whether to set it in capitals.
        public var title: String {
            switch self {
            case .now: "Now"
            case .laterToday: "Later today"
            case .tomorrow: "Tomorrow"
            }
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var group: Group
        public var events: [DayEvent]
        public var id: Group { group }

        /// The first few rows, for "two rows per group, then Show N more".
        public func visible(limit: Int = DayAgenda.rowsPerGroup) -> [DayEvent] {
            Array(events.prefix(max(0, limit)))
        }

        /// How many "Show N more" would reveal.
        public func hiddenCount(limit: Int = DayAgenda.rowsPerGroup) -> Int {
            max(0, events.count - max(0, limit))
        }
    }

    /// Two rows per group before "Show N more": enough to see what is next
    /// without the page turning into the Calendar app.
    public static let rowsPerGroup = 2

    public var availability: TodaySnapshot.Availability
    /// Only the groups with something in them, in page order.
    public var sections: [Section]
    /// The grey sentence under the title, at most fourteen words.
    public var summary: String
    /// The one question above the composer.
    public var suggestion: String

    public var isEmpty: Bool { sections.isEmpty }

    public init(availability: TodaySnapshot.Availability, sections: [Section], summary: String, suggestion: String) {
        self.availability = availability
        self.sections = sections
        self.summary = summary
        self.suggestion = suggestion
    }

    /// Groups the events and writes the summary.
    ///
    /// - NOW: anything in progress, and today's all-day events — they are on
    ///   for the whole day, so "later" would be wrong and leaving them out
    ///   would hide a birthday.
    /// - LATER TODAY: today's timed events that have not started.
    /// - TOMORROW: everything that starts tomorrow, all-day first.
    ///
    /// What already finished today is not shown; the page is about what is
    /// left. It still counts for the summary, which is the one place that has
    /// to tell "nothing else today" from "nothing today".
    public static func make(
        events: [DayEvent],
        availability: TodaySnapshot.Availability,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> DayAgenda {
        guard availability.isReadable else {
            return DayAgenda(
                availability: availability,
                sections: [],
                summary: availability == .refused
                    ? "Calendar is off in Settings."
                    : "Connect your calendar to see your day here.",
                suggestion: "What's on tomorrow?"
            )
        }
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return DayAgenda(availability: availability, sections: [], summary: "", suggestion: "What's on tomorrow?")
        }

        let ordered = events.sorted(by: chronological)
        var happening: [DayEvent] = []
        var later: [DayEvent] = []
        var tomorrow: [DayEvent] = []
        for event in ordered {
            if event.isHappening(at: now) || (event.isAllDay && calendar.isDate(event.start, inSameDayAs: now)) {
                happening.append(event)
            } else if event.start > now, event.start < tomorrowStart {
                later.append(event)
            } else if calendar.isDate(event.start, inSameDayAs: tomorrowStart) {
                tomorrow.append(event)
            }
        }

        var sections: [Section] = []
        if !happening.isEmpty { sections.append(Section(group: .now, events: happening)) }
        if !later.isEmpty { sections.append(Section(group: .laterToday, events: later)) }
        if !tomorrow.isEmpty { sections.append(Section(group: .tomorrow, events: tomorrow)) }

        let today = ordered.filter { calendar.isDate($0.start, inSameDayAs: now) || $0.isHappening(at: now) }
        return DayAgenda(
            availability: availability,
            sections: sections,
            summary: summary(today: today, tomorrow: tomorrow, now: now, calendar: calendar, locale: locale),
            suggestion: later.first.map { "Anything due before \(BriefPrompt.clipped($0.title, limit: 32))?" }
                ?? "What's on tomorrow?"
        )
    }

    /// `3 events left today. You're free after 5:15 PM.`
    ///
    /// Counted from timed events only: an all-day birthday is not something
    /// one is free after.
    static func summary(
        today: [DayEvent],
        tomorrow: [DayEvent],
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let left = today.filter { !$0.isAllDay && $0.end > now }
        if let lastEnd = left.map(\.end).max() {
            let count = Format.counted(left.count, "event", locale: locale)
            guard calendar.isDate(lastEnd, inSameDayAs: now) else {
                return "\(count) left today. The last one runs past midnight."
            }
            return "\(count) left today. You're free after \(Format.time(lastEnd, calendar: calendar, locale: locale))."
        }
        let opening = today.isEmpty ? "Nothing on your calendar today." : "Nothing else today."
        guard let first = tomorrow.first(where: { !$0.isAllDay }) else { return opening }
        return "\(opening) Tomorrow starts at \(Format.time(first.start, calendar: calendar, locale: locale))."
    }

    static func chronological(_ left: DayEvent, _ right: DayEvent) -> Bool {
        if left.start != right.start { return left.start < right.start }
        if left.isAllDay != right.isAllDay { return left.isAllDay }
        return left.title < right.title
    }
}

// MARK: - Reminders

/// One open reminder on the Reminders page.
public struct DayReminder: Sendable, Equatable, Identifiable {
    /// EventKit's `calendarItemIdentifier`: what the tick circle completes.
    /// Opaque; never shown and never sent to a model.
    public var id: String
    public var title: String
    public var due: Date?
    /// A date with no time of day stays a date. "Water the plants" due on
    /// Thursday is not due at midnight on Thursday.
    public var dueHasTime: Bool
    /// EventKit's scale: 1 highest, 9 lowest, 0 for none.
    public var priority: Int

    public init(id: String, title: String, due: Date? = nil, dueHasTime: Bool = false, priority: Int = 0) {
        self.id = id
        self.title = Untrusted(title).sanitisedForPrompt()
        self.due = due
        self.dueHasTime = dueHasTime
        self.priority = priority
    }

    /// `!` for a high priority, nothing otherwise.
    ///
    /// Never "P1", and never EventKit's number: its scale runs backwards from
    /// what anybody expects ("priority 9" is the *lowest*), and the page needs
    /// one mark that means "this one matters", not a ranking to decode. High is
    /// 1–4 on that scale, which is what the Reminders app files under "!!!".
    public var priorityMark: String? {
        (1...4).contains(priority) ? "!" : nil
    }

    /// Late by the clock: a time that has passed, or a date before today.
    public func isOverdue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let due else { return false }
        return dueHasTime ? due < now : due < calendar.startOfDay(for: now)
    }

    /// The text on the right of the row.
    ///
    /// The time for anything due today (`5:00 PM`), otherwise the day:
    /// `Yesterday`, `Tomorrow`, `Monday`, `Fri 2 Oct`. Nil with no due date, so
    /// the row simply has nothing there.
    public func dueText(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let due else { return nil }
        if dueHasTime, calendar.isDate(due, inSameDayAs: now) {
            return Format.time(due, calendar: calendar, locale: locale)
        }
        return Format.day(due, relativeTo: now, calendar: calendar, locale: locale)
    }

    /// The brief's flattened version, so the page and the tile are counted by
    /// the same `DueSplit` rule.
    public var briefReminder: BriefReminder {
        BriefReminder(title: title, due: due, dueHasTime: dueHasTime)
    }
}

/// The Reminders page: OVERDUE · TODAY · LATER.
public struct ReminderAgenda: Sendable, Equatable {

    public enum Group: String, Sendable, Equatable, CaseIterable {
        case overdue, today, later

        public var title: String {
            switch self {
            case .overdue: "Overdue"
            case .today: "Today"
            case .later: "Later"
            }
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var group: Group
        public var reminders: [DayReminder]
        public var id: Group { group }
    }

    public var availability: TodaySnapshot.Availability
    public var sections: [Section]
    public var summary: String
    /// Always the same chip on this page: the thing people come here to do
    /// next is add one.
    public var suggestion: String { "Remind me to…" }

    public var isEmpty: Bool { sections.isEmpty }

    public init(availability: TodaySnapshot.Availability, sections: [Section], summary: String) {
        self.availability = availability
        self.sections = sections
        self.summary = summary
    }

    /// The counts the tile shows, from the same rows the page shows.
    public var overdueCount: Int { sections.first { $0.group == .overdue }?.reminders.count ?? 0 }
    public var todayCount: Int { sections.first { $0.group == .today }?.reminders.count ?? 0 }

    /// Groups the open reminders by the clock.
    ///
    /// - OVERDUE: late by `DueSplit`'s rule, most overdue first.
    /// - TODAY: still to come today, timed ones in order, then date-only.
    /// - LATER: everything after today, soonest first, and the undated ones
    ///   last — most lists are mostly undated, and floating them up would bury
    ///   the three things that have a deadline.
    public static func make(
        reminders: [DayReminder],
        availability: TodaySnapshot.Availability,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> ReminderAgenda {
        guard availability.isReadable else {
            return ReminderAgenda(
                availability: availability,
                sections: [],
                summary: availability == .refused
                    ? "Reminders are off in Settings."
                    : "Connect your reminders to see what's due."
            )
        }
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        var overdue: [DayReminder] = []
        var today: [DayReminder] = []
        var later: [DayReminder] = []
        for reminder in reminders {
            if reminder.isOverdue(now: now, calendar: calendar) {
                overdue.append(reminder)
            } else if let due = reminder.due, due < tomorrowStart {
                today.append(reminder)
            } else {
                later.append(reminder)
            }
        }
        overdue.sort { DueSplit.mostOverdueFirst($0.briefReminder, $1.briefReminder) }
        today.sort { DueSplit.soonestFirst($0.briefReminder, $1.briefReminder) }
        later.sort { DueSplit.mostOverdueFirst($0.briefReminder, $1.briefReminder) }

        var sections: [Section] = []
        if !overdue.isEmpty { sections.append(Section(group: .overdue, reminders: overdue)) }
        if !today.isEmpty { sections.append(Section(group: .today, reminders: today)) }
        if !later.isEmpty { sections.append(Section(group: .later, reminders: later)) }

        return ReminderAgenda(
            availability: availability,
            sections: sections,
            summary: summary(overdue: overdue, today: today, later: later, now: now, calendar: calendar, locale: locale)
        )
    }

    /// `1 overdue and 1 due today.` — and the shapes around it.
    static func summary(
        overdue: [DayReminder],
        today: [DayReminder],
        later: [DayReminder],
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let late = Format.count(overdue.count, locale: locale)
        let due = Format.count(today.count, locale: locale)
        switch (overdue.isEmpty, today.isEmpty) {
        case (false, false):
            return "\(late) overdue and \(due) due today."
        case (false, true):
            return "\(late) overdue. Nothing else due today."
        case (true, false):
            if let first = today.first, first.dueHasTime, let time = first.due {
                return "\(due) due today, the first at \(Format.time(time, calendar: calendar, locale: locale))."
            }
            return "\(due) due today."
        case (true, true):
            guard !later.isEmpty else { return "Your list is clear." }
            return "Nothing due today. \(Format.count(later.count, locale: locale)) more on your list."
        }
    }
}

/// A reminder ticked off from the Reminders page, and the way to put it back.
///
/// Its own value rather than a `PersonalDataWrite`, and the difference is the
/// whole point: undoing a write *removes* something this app created, while
/// undoing a tick must only un-tick. Routing a completion through the write
/// ledger's undo would delete the user's reminder. The window is shared with
/// `WriteUndo` so every Undo in the app lasts the same five minutes.
public struct ReminderCompletion: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The reminder's `calendarItemIdentifier`.
    public let reminderID: String
    public let title: String
    public let completedAt: Date

    public init(id: UUID = UUID(), reminderID: String, title: String, completedAt: Date = Date()) {
        self.id = id
        self.reminderID = reminderID
        self.title = title
        self.completedAt = completedAt
    }

    /// The toast: `Ticked off “Submit expenses”.` Curly quotes, as every
    /// title quoted on screen.
    public var sentence: String { "Ticked off \u{201C}\(title)\u{201D}." }

    /// After Undo: `“Submit expenses” is back on your list.`
    public var undoneSentence: String { "\u{201C}\(title)\u{201D} is back on your list." }

    public func canUndo(now: Date = Date()) -> Bool {
        now.timeIntervalSince(completedAt) < WriteUndo.window
    }
}
