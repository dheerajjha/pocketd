import Foundation

// MARK: - The rule

/// A question about the user's day that the phone can answer without a model.
///
/// This is the half of scheduled tasks that actually works while the app is
/// closed. "Anything due today", "nothing on tomorrow", "what is overdue" are
/// all deterministic rules over rows EventKit hands back; answering them is a
/// sort and a template, which is a few milliseconds of CPU and no GPU at all.
/// That fits inside a `BGAppRefreshTask` with room to spare, and it means a
/// watcher's notification arrives with the answer already in it rather than
/// with an invitation to come and open the app.
///
/// Deliberately built from `CalendarRange` and `ReminderFilter` rather than from
/// new range types. Those two enums already encode the ranges this app is
/// willing to resolve, already have tested boundary behaviour in
/// `PersonalDataRange`, and already carry the empty-result sentences that are
/// the hardest part of this to get right. A second, parallel set of ranges for
/// scheduling would drift from them within a release.
public enum WatcherRule: Sendable, Codable, Equatable {
    case events(CalendarRange)
    case reminders(ReminderFilter)

    /// Which pile of personal data this reads. The app needs it to decide
    /// whether the task can run at all — a watcher over a calendar the user has
    /// since switched off must report that, not return an empty day.
    public var entity: PersonalDataEntity {
        switch self {
        case .events: .calendar
        case .reminders: .reminders
        }
    }

    /// The sentence for "it read fine and there was nothing there".
    ///
    /// Taken from the range rather than written again here, because the
    /// distinction these sentences carry — an empty result is not a failure —
    /// is the same distinction, and having two wordings for it is how one of
    /// them ends up ambiguous.
    public var emptyText: String {
        switch self {
        case .events(let range): range.emptyText
        case .reminders(let filter): filter.emptyText
        }
    }
}

// MARK: - What comes back

/// The rendered answer to a watcher, or the reason there isn't one.
///
/// Three cases and not two, for the reason that runs through this whole
/// codebase: "nothing today" and "I could not look" are different facts, and
/// collapsing them is how an app ends up cheerfully reporting a clear diary to
/// somebody whose calendar permission it lost three weeks ago.
public enum WatcherResult: Sendable, Equatable {
    case found(WatcherReport)
    /// Read fine, found nothing. Carries the sentence to show.
    case nothing(String)
    /// Could not read. Carries what iOS said and about what, so the caller can
    /// build the remedy sentence with `PersonalDataAuthorization.explanation`.
    case unreadable(PersonalDataAuthorization, PersonalDataEntity)
}

/// A watcher's answer, rendered.
///
/// Every string in here has already been through `sanitisedForPrompt()`. That
/// is not optional decoration: an event title is written by whoever sent the
/// invite, this text goes into a notification body and into a stored run
/// record, and the run record is read back into later prompts. Taking the
/// syntax out at the point of rendering is the only place it can be done once
/// for every consumer.
///
/// What it does not do is make the text trustworthy — see `PromptSanitiser` on
/// why prose is left exactly as written. That is why the run record stores it
/// as `Untrusted<String>` rather than as a `String`.
public struct WatcherReport: Sendable, Equatable {

    /// How many lines the rendering will show before it starts counting.
    ///
    /// Five, because the consumer is a notification banner. iOS shows roughly
    /// four lines of body text before truncating with no indication of how much
    /// was cut, so a list of twenty events becomes a list of four events and a
    /// lie of omission. Counting the rest explicitly is the honest version of
    /// the same trim.
    public static let lineLimit = 5

    /// "3 events today", "1 reminder overdue".
    public var headline: String
    /// One line per item, capped at `lineLimit`.
    public var lines: [String]
    /// How many items there were in total — a floor, not a count, when
    /// `readTruncated` is set.
    public var itemCount: Int
    /// Whether the read itself hit its row cap, so `itemCount` is "at least".
    public var readTruncated: Bool

    public init(headline: String, lines: [String], itemCount: Int, readTruncated: Bool) {
        self.headline = headline
        self.lines = lines
        self.itemCount = itemCount
        self.readTruncated = readTruncated
    }

    /// How many items exist beyond the lines shown.
    public var overflow: Int { max(0, itemCount - lines.count) }

    /// The whole thing as one block of text: what goes in the notification and
    /// what gets stored on the run record.
    public var text: String {
        var parts = [headline]
        parts.append(contentsOf: lines)
        if overflow > 0 {
            parts.append("…and \(overflow) more.")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Evaluation

/// Runs a watcher rule against the device's data.
///
/// The reads arrive as closures, exactly as they do in `PersonalDataTools`, and
/// for the same two reasons. EventKit does not belong in a package that has to
/// build on Linux; and a test can hand over a spy and assert on what the rule
/// did *not* ask for — an events rule must never touch the reminder store,
/// which is a property nothing about the code's shape would otherwise guarantee.
///
/// Note what is absent: there is no engine parameter, no async model call, no
/// way to reach inference from here at all. That absence is the honest half of
/// the watcher/prompt split. A watcher is a function of rows and a clock, so it
/// can run in a background refresh; a prompt task has no evaluation function in
/// this package whatsoever, so it structurally cannot be run somewhere a model
/// is unavailable. The type system makes the confusion impossible rather than
/// a comment asking people not to make it.
public enum WatcherEvaluation {

    public static func run(
        _ rule: WatcherRule,
        now: Date = Date(),
        calendar: Calendar = .current,
        readEvents: @Sendable (DateInterval) async -> PersonalDataLookup<CalendarEventRow>,
        readReminders: @Sendable (DateWindow) async -> PersonalDataLookup<ReminderRow>
    ) async -> WatcherResult {
        switch rule {
        case .events(let range):
            let window = PersonalDataRange.eventWindow(for: range, now: now, calendar: calendar)
            switch await readEvents(window) {
            case .unauthorized(let authorization):
                return .unreadable(authorization, .calendar)
            case .rows(let rows, let truncated):
                guard !rows.isEmpty else { return .nothing(range.emptyText) }
                return .found(report(events: rows, range: range, truncated: truncated, calendar: calendar))
            }

        case .reminders(let filter):
            let window = PersonalDataRange.reminderWindow(for: filter, now: now, calendar: calendar)
            switch await readReminders(window) {
            case .unauthorized(let authorization):
                return .unreadable(authorization, .reminders)
            case .rows(let rows, let truncated):
                guard !rows.isEmpty else { return .nothing(filter.emptyText) }
                return .found(report(reminders: rows, filter: filter, truncated: truncated, calendar: calendar))
            }
        }
    }

    // MARK: - Templates

    static func report(
        events rows: [CalendarEventRow],
        range: CalendarRange,
        truncated: Bool,
        calendar: Calendar
    ) -> WatcherReport {
        // Time order, then title, so a day read aloud is in the order it
        // happens. `Untrusted` is `Comparable` precisely so the tie-break does
        // not have to unwrap the text — ordering discloses nothing.
        let ordered = rows.sorted {
            $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start
        }
        return WatcherReport(
            headline: headline(count: rows.count, noun: "event", phrase: phrase(range), truncated: truncated),
            lines: ordered.prefix(WatcherReport.lineLimit).map { line(for: $0, calendar: calendar) },
            itemCount: rows.count,
            readTruncated: truncated
        )
    }

    static func report(
        reminders rows: [ReminderRow],
        filter: ReminderFilter,
        truncated: Bool,
        calendar: Calendar
    ) -> WatcherReport {
        let ordered = rows.sorted { left, right in
            // Undated reminders sort last: most people's lists are mostly
            // undated, and floating them to the top buries the three things
            // that actually have a deadline today.
            let leftDue = left.due ?? .distantFuture
            let rightDue = right.due ?? .distantFuture
            if leftDue != rightDue { return leftDue < rightDue }
            // EventKit's priority scale is RFC 5545's: 1 is highest, 9 lowest,
            // and 0 means the user set none. Sorting on the raw number puts
            // "no priority" above "urgent", so 0 is moved past the bottom.
            let leftPriority = left.priority == 0 ? 10 : left.priority
            let rightPriority = right.priority == 0 ? 10 : right.priority
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return left.title < right.title
        }
        return WatcherReport(
            headline: headline(count: rows.count, noun: "reminder", phrase: phrase(filter), truncated: truncated),
            lines: ordered.prefix(WatcherReport.lineLimit).map { line(for: $0, calendar: calendar) },
            itemCount: rows.count,
            readTruncated: truncated
        )
    }

    /// "3 events today". With `truncated`, "20+ events this week" — the count
    /// is a floor once the read hit its own row cap, and printing it as an
    /// exact number would be the one part of this sentence that is false.
    static func headline(count: Int, noun: String, phrase: String, truncated: Bool) -> String {
        let plural = count == 1 ? noun : noun + "s"
        return truncated ? "\(count)+ \(plural) \(phrase)" : "\(count) \(plural) \(phrase)"
    }

    /// One event.
    ///
    /// Title only — the location is deliberately left out. It is the longest
    /// field on the row that a stranger fully controls, it is free text nothing
    /// validates, and a notification banner has room for about sixty characters
    /// before it truncates. Dropping it costs a detail the user can see by
    /// opening the event and removes the biggest surface in the row.
    static func line(for row: CalendarEventRow, calendar: Calendar) -> String {
        // The zone comes off the same `Calendar` that resolved the range, and
        // not from `.current`. Those are the same object in the app and
        // different ones in a test — but they are also different at 00:30 on
        // the night a user lands abroad, and a report whose window was computed
        // in one zone and rendered in another is off by the whole offset while
        // looking entirely plausible. The locale is deliberately left as
        // `.current`: that is the user's language, which no schedule decides.
        let when = row.isAllDay
            ? PersonalDataFormat.day(row.start, timeZone: calendar.timeZone, calendar: calendar)
            : PersonalDataFormat.moment(row.start, timeZone: calendar.timeZone, calendar: calendar)
        let what = row.title.sanitisedForPrompt()
        return row.isAllDay ? "\(when) — all day — \(what)" : "\(when) — \(what)"
    }

    /// One reminder. `"no due date"` spelled out rather than left off, because
    /// a line with nothing after the dash reads like a rendering bug.
    static func line(for row: ReminderRow, calendar: Calendar) -> String {
        let what = row.title.sanitisedForPrompt()
        guard let due = row.due else { return "\(what) — no due date" }
        // A reminder can be due on a date with no time of day; printing 00:00
        // for those tells the user something they never set.
        let when = row.dueHasTime
            ? PersonalDataFormat.moment(due, timeZone: calendar.timeZone, calendar: calendar)
            : PersonalDataFormat.day(due, timeZone: calendar.timeZone, calendar: calendar)
        return "\(what) — due \(when)"
    }

    /// The phrase that finishes a headline.
    ///
    /// Switched over here rather than added to `CalendarRange` itself: these
    /// words only make sense inside this one sentence shape, and the range
    /// already carries the wording that has to stay consistent everywhere,
    /// which is `emptyText`. The exhaustive switch still ties the two together —
    /// a new range case breaks this build rather than silently rendering an
    /// empty phrase.
    static func phrase(_ range: CalendarRange) -> String {
        switch range {
        case .today: "today"
        case .tomorrow: "tomorrow"
        case .this_week: "this week"
        case .next_week: "next week"
        }
    }

    static func phrase(_ filter: ReminderFilter) -> String {
        switch filter {
        case .overdue: "overdue"
        case .today: "due today"
        case .tomorrow: "due tomorrow"
        case .this_week: "due this week"
        case .all_open: "still open"
        }
    }
}
