import Foundation

// MARK: - Rows

/// One event, flattened for the brief.
///
/// A parallel type to `CalendarEventRow` rather than a reuse of it, and the
/// reason is the one thing the brief does that a tool result does not: it is
/// **written to disk** and read back tomorrow. `CalendarEventRow.title` is
/// `Untrusted<String>`, which is deliberately not `Codable` — wrapping a value
/// so that nothing can interpolate it by accident and then handing it a
/// `Codable` conformance would give every call site an escape hatch spelled
/// `try container.encode(title)`.
///
/// So the untrusting happens at the boundary instead: `init(_ row:)` is the only
/// way the app can build one of these, and it takes the text through
/// `sanitisedForPrompt()` on the way in. What is stored is already neutralised,
/// which is also what makes it safe to mirror into a file a second process reads.
public struct BriefEvent: Sendable, Codable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Kept, unlike in `WatcherEvaluation.line`, because the consumer differs.
    /// That one renders into a notification banner with about sixty characters
    /// before iOS truncates it without saying so; this one feeds a tile and a
    /// prompt that can each decide for themselves whether there is room.
    public var location: String?

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
    }

    /// The boundary. Everything that builds a snapshot is reading EventKit, so
    /// there is no caller for whom the title is trusted and no argument for
    /// making them say so.
    public init(_ row: CalendarEventRow) {
        self.init(
            title: row.title.sanitisedForPrompt(),
            start: row.start,
            end: row.end,
            isAllDay: row.isAllDay,
            location: row.location?.sanitisedForPrompt()
        )
    }
}

/// One open reminder, flattened for the brief. Same argument as `BriefEvent`.
public struct BriefReminder: Sendable, Codable, Equatable {
    public var title: String
    /// Optional because a reminder need not have one. Which pile a dated
    /// reminder lands in — `dueToday` or `overdue` — is decided by whoever read
    /// EventKit against the clock, not here.
    public var due: Date?

    public init(title: String, due: Date? = nil) {
        self.title = title
        self.due = due
    }

    public init(_ row: ReminderRow) {
        self.init(title: row.title.sanitisedForPrompt(), due: row.due)
    }
}

// MARK: - The snapshot

/// Everything the Today tab knows about the day, gathered without a model.
///
/// The split this type enforces is the useful one. **Reading** the day is
/// deterministic, fast and always possible; **writing about** it needs a model
/// that may be absent, still downloading, or busy answering a chat turn. Tiles,
/// the fallback brief and the widget all run off this value alone, so a phone
/// with no brain in it still shows a real day rather than a spinner.
///
/// Every source carries its own `Availability` rather than being represented by
/// an empty array, and that is the distinction `WatcherResult` makes for the
/// same reason: "nothing on today" and "I was never allowed to look" are
/// different facts, and collapsing them is how an app cheerfully reports a clear
/// diary to somebody whose calendar permission it lost three weeks ago.
public struct TodaySnapshot: Sendable, Codable, Equatable {

    /// Whether a source of truth is actually speaking to us.
    ///
    /// Four cases and not a `Bool`, because the three ways of being unavailable
    /// need three different sentences on screen: `.off` is a switch the owner
    /// can flip, `.refused` is a trip to Settings, and `.unavailable` is a fact
    /// about the hardware that no amount of tapping will change.
    public enum Availability: String, Sendable, Codable, Equatable, CaseIterable {
        case connected, off, refused, unavailable

        /// Whether the brief may say anything at all about this source.
        ///
        /// The one question every caller actually asks, spelled as a property
        /// so that a future fifth case cannot be silently treated as connected
        /// by a `!= .off` written somewhere in a view.
        public var isReadable: Bool { self == .connected }

        /// Derived from the ability's own state machine rather than restated.
        ///
        /// `AbilityState` already holds the answer to "is this working" and has
        /// tests for every awkward corner of it — add-only calendar access,
        /// Health's permanently unconfirmable grant, a tool the engine declined
        /// to carry. A second mapping written from the raw authorization would
        /// disagree with the row the user is looking at on the You tab within a
        /// release.
        public static func of(_ state: AbilityState) -> Availability {
            switch state {
            case .unsupported:
                .unavailable
            case .offAndRefused, .offAndRestricted, .onAndRefused, .onAndRestricted:
                .refused
            // Add-only calendar access is a genuine grant to *write* and no
            // grant at all to read. The brief only ever reads, so from here it
            // is indistinguishable from a refusal — and calling it "off" would
            // invite the user to flip a switch that is already on.
            case .offAndAddOnly, .onAndAddOnly:
                .refused
            case .off, .offWithGrantStanding, .pending, .onAwaitingGrant:
                .off
            case .onButWithheld, .onButFailed:
                .off
            // Health never confirms a read grant. Treating `onButUnconfirmed`
            // as connected is the only workable answer: the alternative is a
            // Sleep tile permanently reading "Off" on every iPhone ever sold.
            case .on, .onButUnconfirmed:
                .connected
            }
        }
    }

    public var generatedAt: Date

    public var calendar: Availability
    public var reminders: Availability
    public var health: Availability

    /// What is left of today, then the first few of tomorrow.
    ///
    /// One array rather than two, because every consumer wants them in time
    /// order and none of them wants to merge two lists to get it. Which day an
    /// event belongs to is a question a `Calendar` answers from `start`, and
    /// answering it here would bake one time zone into a file read back
    /// tomorrow, possibly in another country.
    public var events: [BriefEvent]

    public var dueToday: [BriefReminder]
    public var overdue: [BriefReminder]

    public var sleepLastNight: TimeInterval?
    public var sleepUsual: TimeInterval?
    public var stepsToday: Double?
    public var stepsUsual: Double?
    public var restingHeartRate: Double?
    public var restingHeartRateUsual: Double?

    public init(
        generatedAt: Date,
        calendar: Availability = .off,
        reminders: Availability = .off,
        health: Availability = .off,
        events: [BriefEvent] = [],
        dueToday: [BriefReminder] = [],
        overdue: [BriefReminder] = [],
        sleepLastNight: TimeInterval? = nil,
        sleepUsual: TimeInterval? = nil,
        stepsToday: Double? = nil,
        stepsUsual: Double? = nil,
        restingHeartRate: Double? = nil,
        restingHeartRateUsual: Double? = nil
    ) {
        self.generatedAt = generatedAt
        self.calendar = calendar
        self.reminders = reminders
        self.health = health
        self.events = events
        self.dueToday = dueToday
        self.overdue = overdue
        self.sleepLastNight = sleepLastNight
        self.sleepUsual = sleepUsual
        self.stepsToday = stepsToday
        self.stepsUsual = stepsUsual
        self.restingHeartRate = restingHeartRate
        self.restingHeartRateUsual = restingHeartRateUsual
    }

    /// Nothing connected and nothing known.
    ///
    /// The epoch rather than `Date()`, deliberately: a `static let` is evaluated
    /// once, so a "now" captured here would be the moment of first access and
    /// would then age silently for the rest of the process. `isForToday` reads
    /// this field, and a placeholder that claims to have been generated at
    /// launch is a placeholder that stops the first real brief being written.
    public static let empty = TodaySnapshot(generatedAt: Date(timeIntervalSince1970: 0))

    // MARK: - Derived

    /// The next thing that has not started yet.
    ///
    /// A function of `now` rather than a stored field, and that is not a style
    /// choice: a snapshot is built once and read for the rest of the morning, so
    /// a stored `nextEvent` would still be pointing at the 09:30 standup at half
    /// past eleven. Computing it keeps one source of truth — `events` — and lets
    /// the tile be right on every redraw without a refresh.
    ///
    /// All-day events are skipped. Their `start` is midnight, so one of them is
    /// "next" for nobody and would shadow the meeting the user actually has to
    /// be at. It stays in `events`, where a timeline can still draw it.
    public func nextEvent(now: Date) -> BriefEvent? {
        events
            .filter { !$0.isAllDay && $0.start > now }
            // Tie broken on the title so that two events at the same minute
            // pick the same one on every call. A tile that alternates between
            // two names on consecutive redraws looks broken and is.
            .min { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
    }

    /// Whether any source can be read at all. The Today tab uses it to choose
    /// between writing a brief and inviting the user to connect something.
    public var hasAnythingConnected: Bool {
        calendar.isReadable || reminders.isReadable || health.isReadable
    }
}

// MARK: - Persistence

extension TodaySnapshot {
    private enum CodingKeys: String, CodingKey {
        case generatedAt, calendar, reminders, health, events, dueToday, overdue
        case sleepLastNight, sleepUsual, stepsToday, stepsUsual
        case restingHeartRate, restingHeartRateUsual
    }

    /// Written by hand for one reason: a field added in a later release must not
    /// make every brief already on disk undecodable.
    ///
    /// The same argument `ChatMessage` and `ScheduledTask` make, at a much lower
    /// stake — a brief is regenerated every morning, so losing one is a shrug
    /// rather than the loss of a transcript. It is still worth an initialiser,
    /// because `DailyBriefStore.read` returns nil for a file it cannot decode:
    /// the synthesised version would blank the Today tab on the morning a field
    /// ships, for everyone, until the first refresh landed.
    ///
    /// An unrecognised `Availability` decodes as `.off` rather than throwing,
    /// and that is the safe direction. `.off` shows nothing; guessing
    /// `.connected` would have the brief describe data this build cannot read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func availability(_ key: CodingKeys) -> Availability {
            (try? container.decodeIfPresent(Availability.self, forKey: key)) ?? .off
        }
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        calendar = availability(.calendar)
        reminders = availability(.reminders)
        health = availability(.health)
        events = try container.decodeIfPresent([BriefEvent].self, forKey: .events) ?? []
        dueToday = try container.decodeIfPresent([BriefReminder].self, forKey: .dueToday) ?? []
        overdue = try container.decodeIfPresent([BriefReminder].self, forKey: .overdue) ?? []
        sleepLastNight = try container.decodeIfPresent(TimeInterval.self, forKey: .sleepLastNight)
        sleepUsual = try container.decodeIfPresent(TimeInterval.self, forKey: .sleepUsual)
        stepsToday = try container.decodeIfPresent(Double.self, forKey: .stepsToday)
        stepsUsual = try container.decodeIfPresent(Double.self, forKey: .stepsUsual)
        restingHeartRate = try container.decodeIfPresent(Double.self, forKey: .restingHeartRate)
        restingHeartRateUsual = try container.decodeIfPresent(Double.self, forKey: .restingHeartRateUsual)
    }
}
