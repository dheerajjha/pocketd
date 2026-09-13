import Foundation

// MARK: - What the model may ask for

/// The verbs the reminders tool accepts.
///
/// `list` is the old `get_reminders` and does exactly what it always did. The
/// other two are why this tool stopped being called `get_`.
///
/// One tool with a verb rather than three tools, and the reason is measured
/// rather than aesthetic. Tool schemas are frozen into the client at model load
/// — rebuilding the set costs a reload of the weights, which is why the
/// per-question router in `CapabilityBudget` has never had a caller — so every
/// tool is charged against every prompt for as long as the model is resident.
/// Against the default 4,096-token window, a third of which may go on schemas,
/// and a tool-native template like Qwen3's that renders them twice, three read
/// tools cost 785 tokens of a 1,344 ceiling and three more write tools take the
/// total to 1,469. That does not fit, and the budget's response to not fitting
/// is to drop tools by priority — so the writes would have been registered,
/// charged for, and then silently discarded on the exact default configuration
/// most people run. Folding the verb in costs 581 characters where three
/// separate tools cost 948.
public enum ReminderAction: String, Sendable, Codable, CaseIterable {
    case list
    case create
    case complete
}

/// The verbs the calendar tool accepts. No `delete`, and no `complete` because
/// an event is not a to-do.
public enum CalendarAction: String, Sendable, Codable, CaseIterable {
    case list
    case create
}

/// A reminder on its way into EventKit.
public struct NewReminder: Sendable, Equatable {
    public var title: String
    public var due: Date?
    /// False when the phrase named a day and no clock time. `EKReminder` models
    /// this natively and turning it into midnight would invent a deadline.
    public var dueHasTime: Bool

    public init(title: String, due: Date? = nil, dueHasTime: Bool = false) {
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
    }
}

/// An event on its way into EventKit.
public struct NewEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date

    public init(title: String, start: Date, end: Date) {
        self.title = title
        self.start = start
        self.end = end
    }
}

/// How a write ended. Never a thrown error — see `PersonalDataLookup`.
public enum WriteResult: Sendable, Equatable {
    case written
    case unauthorised(PersonalDataAuthorization)
    case failed
}

// MARK: - The decisions

/// Everything the write half of the tools does, minus EventKit.
///
/// Same split as `PersonalDataTools`, for the same reason: the parts worth
/// being sure about — that a network caller causes no write at all, that a
/// repeating phrase is refused rather than flattened, that the same reminder
/// asked for twice is filed once — need neither a device nor a granted
/// permission to exercise.
public enum PersonalDataWrites {

    /// How long an event lasts when nobody said.
    ///
    /// An hour, because that is what every calendar app defaults to and because
    /// the alternative — refusing until the model supplies a duration — turns
    /// the commonest request ("put lunch with Sam in for Friday at 1") into a
    /// round trip. The value is echoed back in the confirmation, so a user who
    /// wanted ninety minutes can see that they did not get them.
    public static let defaultEventMinutes = 60

    /// The longest an event may be asked to run, in minutes.
    ///
    /// Guards against a model reading "a couple of days" as 2 and then as
    /// minutes, or emitting a duration with an extra digit. A week is well past
    /// anything anyone types and well short of the year-long event that a
    /// misplaced zero produces.
    public static let maximumEventMinutes = 60 * 24 * 7

    // MARK: Reminders

    /// - Parameter existing: The open reminders, for the duplicate check. Read
    ///   before writing and never otherwise — a create that skipped this would
    ///   still be correct, just noisier.
    /// - Parameter write: The actual EventKit save.
    public static func createReminder(
        title rawTitle: String?,
        when: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        origin: RequestOrigin = ToolContext.origin,
        existing: @Sendable () async -> PersonalDataLookup<ReminderRow>,
        write: @Sendable (NewReminder) async -> WriteResult
    ) async -> [String: any Sendable] {
        // First, before anything is resolved and long before EventKit is
        // touched: a caller that may not change things must cause no change.
        guard origin.mayWritePersonalData else {
            return ["text": ToolContext.writeRefusal(for: origin)]
        }
        guard let title = usableTitle(rawTitle) else {
            return ["text": "I need to know what the reminder should say."]
        }

        var due: Date?
        var dueHasTime = false
        if let phrase = when, !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch MomentPhrase.resolve(phrase, now: now, calendar: calendar) {
            case let .moment(date, hasTime):
                due = date
                dueHasTime = hasTime
            case .recurring:
                // Refused rather than quietly filed once. This app has a real
                // `Recurrence` type behind Scheduled tasks, so the honest answer
                // points at it instead of pretending.
                return ["text": "I can only set a reminder for one time. For something that repeats, set up a Scheduled task instead."]
            case .unresolved:
                // No guessed hour, ever. A reminder at a time nobody asked for
                // is worse than none, because the user stops holding it in
                // their head.
                return ["text": "I could not work out when \"\(phrase)\" is. Tell me a time like \"2am today\" or \"tomorrow at 3pm\"."]
            }
        }

        let candidate = NewReminder(title: title, due: due, dueHasTime: dueHasTime)

        if case let .rows(rows, _) = await existing(), let clash = duplicate(of: candidate, in: rows, calendar: calendar) {
            // Not an error and not a second reminder. The case this is for is a
            // model that calls the tool, does not recognise the result, and
            // calls it again — and the user finding the same thing twice in
            // their list. Reported as done because from where the user is
            // standing it is.
            return [
                "text": "That reminder is already on the list\(clash.due.map { " for \(describe($0, hasTime: clash.dueHasTime, calendar: calendar))" } ?? "").",
                "already_existed": true
            ]
        }

        switch await write(candidate) {
        case .written:
            // The resolved time is echoed back deliberately. No phrase parser
            // is right every time, and the cheapest defence against a wrong one
            // is for the answer to state what it actually set, so the user
            // catches it in the same breath.
            return [
                "text": confirmation(for: candidate, calendar: calendar),
                "created": true
            ]
        case let .unauthorised(authorization):
            return ["text": authorization.explanation(for: .reminders)]
        case .failed:
            return ["text": "I could not save that reminder."]
        }
    }

    /// Marks one open reminder done.
    ///
    /// Completing and not deleting, and that is the line for the whole feature.
    /// Ticking something off is recoverable — the reminder is still there, and
    /// the user can un-tick it — where deleting is not. An assistant driven by
    /// a 1.7B model, reading calendar titles a stranger wrote, should not be
    /// able to destroy anything it cannot put back.
    public static func completeReminder(
        title rawTitle: String?,
        origin: RequestOrigin = ToolContext.origin,
        existing: @Sendable () async -> PersonalDataLookup<ReminderRow>,
        complete: @Sendable (ReminderRow) async -> WriteResult
    ) async -> [String: any Sendable] {
        guard origin.mayWritePersonalData else {
            return ["text": ToolContext.writeRefusal(for: origin)]
        }
        guard let title = usableTitle(rawTitle) else {
            return ["text": "I need to know which reminder to tick off."]
        }

        let rows: [ReminderRow]
        switch await existing() {
        case let .rows(found, _): rows = found
        case let .unauthorized(authorization): return ["text": authorization.explanation(for: .reminders)]
        }

        let matches = rows.filter { matches(title, $0.title.attackerControlledValue()) }
        guard !matches.isEmpty else {
            return ["text": "I could not find an open reminder matching \"\(title)\"."]
        }
        guard matches.count == 1, let target = matches.first else {
            // Never a guess. Picking one of three reminders that all match is
            // the kind of wrong that is only discovered later, by which time
            // the user has thrown away the thing they still needed.
            return ["text": "\(matches.count) open reminders match \"\(title)\". Which one?"]
        }

        switch await complete(target) {
        case .written:
            return ["text": "Ticked off \"\(target.title.sanitisedForPrompt())\".", "completed": true]
        case let .unauthorised(authorization):
            return ["text": authorization.explanation(for: .reminders)]
        case .failed:
            return ["text": "I could not tick that off."]
        }
    }

    // MARK: Calendar

    public static func createEvent(
        title rawTitle: String?,
        start when: String?,
        durationMinutes: Int?,
        now: Date = Date(),
        calendar: Calendar = .current,
        origin: RequestOrigin = ToolContext.origin,
        write: @Sendable (NewEvent) async -> WriteResult
    ) async -> [String: any Sendable] {
        guard origin.mayWritePersonalData else {
            return ["text": ToolContext.writeRefusal(for: origin)]
        }
        guard let title = usableTitle(rawTitle) else {
            return ["text": "I need to know what the event is called."]
        }
        guard let phrase = when, !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Unlike a reminder, an event with no time is not a thing. A
            // reminder with no due date is perfectly ordinary; an event has to
            // happen somewhen.
            return ["text": "I need to know when \"\(title)\" starts."]
        }

        let start: Date
        switch MomentPhrase.resolve(phrase, now: now, calendar: calendar) {
        case let .moment(date, hasTime):
            guard hasTime else {
                // A day with no clock time would become an all-day event, which
                // is a different thing from what someone asking for "Friday"
                // usually means. Asked rather than assumed.
                return ["text": "What time on \(describe(date, hasTime: false, calendar: calendar)) does \"\(title)\" start?"]
            }
            start = date
        case .recurring:
            return ["text": "I can only add a single event. For something that repeats, add it in the Calendar app."]
        case .unresolved:
            return ["text": "I could not work out when \"\(phrase)\" is. Tell me a time like \"tomorrow at 3pm\"."]
        }

        let minutes = resolvedMinutes(durationMinutes)
        guard let end = calendar.date(byAdding: .minute, value: minutes, to: start) else {
            return ["text": "I could not work out when that event ends."]
        }

        switch await write(NewEvent(title: title, start: start, end: end)) {
        case .written:
            return [
                "text": "Added \"\(title)\" to your calendar for \(describe(start, hasTime: true, calendar: calendar))\(minutes == defaultEventMinutes ? "" : ", for \(minutes) minutes").",
                "created": true
            ]
        case let .unauthorised(authorization):
            return ["text": authorization.explanation(for: .calendar)]
        case .failed:
            return ["text": "I could not add that to your calendar."]
        }
    }

    // MARK: - Shared judgement

    /// A title the user would recognise, or nothing.
    ///
    /// A model that calls the tool with an empty string, a lone full stop or
    /// the word "null" has not understood the request, and filing a reminder
    /// called "null" is a worse outcome than asking again.
    static func usableTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let lowered = trimmed.lowercased()
        guard !["null", "none", "nil", "undefined", "n/a", "todo", "string"].contains(lowered) else { return nil }
        return trimmed
    }

    /// Whether an equivalent reminder is already open.
    ///
    /// Title compared case- and whitespace-insensitively, due date compared to
    /// the minute — two reminders a second apart are the same reminder asked
    /// for twice, and nobody sets two alarms 40 seconds apart on purpose.
    static func duplicate(of candidate: NewReminder, in rows: [ReminderRow], calendar: Calendar) -> ReminderRow? {
        rows.first { row in
            guard matches(candidate.title, row.title.attackerControlledValue()) else { return false }
            switch (candidate.due, row.due) {
            case (nil, nil): return true
            case let (mine?, theirs?): return calendar.isDate(mine, equalTo: theirs, toGranularity: .minute)
            default: return false
            }
        }
    }

    /// Loose title comparison, in one place so the duplicate check and the
    /// complete lookup cannot disagree about what "the same reminder" means.
    static func matches(_ left: String, _ right: String) -> Bool {
        normalise(left) == normalise(right)
    }

    static func normalise(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    static func resolvedMinutes(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultEventMinutes }
        return min(requested, maximumEventMinutes)
    }

    /// - Parameter calendar: The caller's, threaded through rather than left to
    ///   `PersonalDataFormat`'s `.current` defaults. In the app the two are the
    ///   same object and nothing changes; in a test they are not, and a
    ///   confirmation rendered in the machine's zone while the reminder was
    ///   filed in the calendar's would read as a different hour — which is the
    ///   exact class of bug this sentence exists to let the user catch.
    static func describe(_ date: Date, hasTime: Bool, calendar: Calendar) -> String {
        hasTime
            ? PersonalDataFormat.moment(date, timeZone: calendar.timeZone, calendar: calendar)
            : PersonalDataFormat.day(date, timeZone: calendar.timeZone, calendar: calendar)
    }

    static func confirmation(for reminder: NewReminder, calendar: Calendar) -> String {
        guard let due = reminder.due else {
            return "Reminder added: \"\(reminder.title)\", with no due date."
        }
        return "Reminder set: \"\(reminder.title)\" for \(describe(due, hasTime: reminder.dueHasTime, calendar: calendar))."
    }
}
