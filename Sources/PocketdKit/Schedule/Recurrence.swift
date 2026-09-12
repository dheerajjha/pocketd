import Foundation

// MARK: - Pieces a person would say out loud

/// A time of day as the two numbers on a clock face, never as an offset.
///
/// Storing `09:00` rather than an absolute `Date` is the whole of why a daily
/// task survives a flight. An instant is a fixed point on the world's timeline;
/// "nine in the morning" is a fact about where the user is standing, and it is
/// the second one people mean. The difference only shows up at a boundary —
/// board a plane in London with a 09:00 task stored as an instant and it fires
/// at 17:00 in Tokyo, having drifted by exactly the number of hours nobody
/// thought about when they wrote `Date`.
public struct TimeOfDay: Sendable, Codable, Equatable, Comparable {
    public let hour: Int
    public let minute: Int

    /// Clamped rather than failable, and the reason is the decoder below.
    ///
    /// A file on disk can hold `hour: 25` — written by a future build, a bad
    /// migration, or a user editing the container. `FireSequence` walks days
    /// looking for a time that matches, and a time that can never match makes
    /// that walk run to its horizon on every single evaluation, once per
    /// background refresh, forever. Clamping turns a corrupt value into a task
    /// that fires at a slightly wrong hour, which is recoverable; the
    /// alternative is a scheduler that quietly burns the background budget it
    /// is allowed.
    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    /// Written by hand only so that a decoded value goes through the clamp
    /// above. The synthesised decoder assigns the stored properties directly
    /// and would let `hour: 25` straight through.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hour: try container.decode(Int.self, forKey: .hour),
            minute: try container.decode(Int.self, forKey: .minute)
        )
    }
}

/// A day of the week, with `Calendar`'s numbering and not a private one.
///
/// The raw values are deliberately `Calendar.component(.weekday, from:)`'s —
/// 1 is Sunday — so that the conversion between this and Foundation is
/// `Weekday(rawValue:)` and not a table somebody has to keep correct. Every
/// other choice here (Monday = 0, ISO 8601's Monday = 1) needs arithmetic at
/// the boundary, and that arithmetic is off by one in roughly half the code
/// that has ever been written against it.
///
/// Note this is *not* the order weeks are displayed in: `Calendar.firstWeekday`
/// decides that and is Sunday in the US, Monday across most of Europe and
/// Saturday in much of the Gulf. Nothing here depends on display order.
public enum Weekday: Int, Sendable, Codable, CaseIterable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Monday to Friday. The "weekday" pattern, named rather than spelled out
    /// at each call site, because a set literal of five integers is where the
    /// Sunday-is-1 mistake actually gets made.
    public static let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// Saturday and Sunday.
    public static let weekend: Set<Weekday> = [.saturday, .sunday]
}

/// What "the 31st" means in a month that has no 31st.
///
/// There is no default answer to this that does not surprise somebody, so the
/// type asks. Apple's Calendar app skips; Reminders clamps; a user who picked
/// 31 from a menu usually meant "the end of the month" and a user who typed a
/// date on an invoice usually meant that exact date.
public enum ShortMonth: String, Sendable, Codable, CaseIterable {
    /// Fire on the last day the month does have — 28, 29 or 30.
    ///
    /// The default offered by `Recurrence.monthly`, because the failure mode of
    /// the other one is a scheduled task that silently does not run in February,
    /// April, June, September and November, and a scheduler that goes missing
    /// for five months of the year without saying so is worse than one that
    /// fires a day or three early.
    case lastDay
    /// Do not fire at all that month.
    case skip
}

// MARK: - The pattern

/// When a task fires, expressed so that the answer is recomputed against the
/// user's calendar every time rather than baked into an instant.
///
/// Every case below is a *rule*, not a date. `FireSequence` turns a rule plus a
/// `Calendar` into instants, and it does that with `Calendar` and
/// `DateComponents` throughout — never by adding 86,400 to anything. Two
/// concrete failures motivate that, and both are covered by
/// `ScheduleRecurrenceTests`:
///
/// - **Daylight saving.** The day a zone springs forward is 23 hours long and
///   the day it falls back is 25. A daily 09:00 task advanced by 86,400 seconds
///   lands at 08:00 or 10:00 and stays there for six months.
/// - **The user moving.** `Calendar.current` carries the device's zone, so a
///   rule re-evaluated after a flight gives 09:00 where the user now is. An
///   instant cannot do that; it has already decided.
public enum Recurrence: Sendable, Codable, Equatable {
    /// One firing, at a fixed instant, and then never again.
    ///
    /// The only case that legitimately holds a `Date`: "at 3pm tomorrow" is a
    /// promise about a specific moment, and the user is not going to be
    /// somewhere else for it in a way that should move it.
    case once(Date)

    case daily(at: TimeOfDay)

    /// The given days, every week. An empty set never fires — see `isFireable`.
    case weekly(days: Set<Weekday>, at: TimeOfDay)

    /// The same date each month, with an explicit answer for the months that do
    /// not have it.
    case monthly(day: Int, at: TimeOfDay, whenShort: ShortMonth)

    /// Monday to Friday, which is the pattern people actually ask for and the
    /// one a set literal gets wrong.
    public static func weekdays(at time: TimeOfDay) -> Recurrence {
        .weekly(days: Weekday.workdays, at: time)
    }

    /// `.lastDay` by default; see `ShortMonth`.
    public static func monthly(day: Int, at time: TimeOfDay) -> Recurrence {
        .monthly(day: day, at: time, whenShort: .lastDay)
    }

    /// The clock time this fires at, if it has one. `.once` carries an instant
    /// instead, which is why the day walk in `FireSequence` skips it.
    public var timeOfDay: TimeOfDay? {
        switch self {
        case .once: nil
        case .daily(let time): time
        case .weekly(_, let time): time
        case .monthly(_, let time, _): time
        }
    }

    /// Whether this rule can ever produce a firing.
    ///
    /// Exists so the UI can refuse to save a task that would sit in the list
    /// looking scheduled and never run. `.weekly` with no days selected is the
    /// case that occurs in practice — a picker starts empty — and it is
    /// indistinguishable, once saved, from a task whose next firing is simply
    /// far away.
    public var isFireable: Bool {
        switch self {
        case .once: true
        case .daily: true
        case .weekly(let days, _): !days.isEmpty
        // `whenShort` does not enter into it: a `.skip` rule for day 30 or 31
        // still fires in the months that do have one. Only a day outside
        // 1...31 could never match, and the initialiser cannot reject that
        // because a decoder can produce it.
        case .monthly(let day, _, _): (1...31).contains(day)
        }
    }

    /// Whether a day belongs to this pattern. Pure, and the only part of the
    /// rule a `Calendar` day-walk has to ask about.
    ///
    /// - Parameter dayStart: Midnight of the day in question, in `calendar`'s
    ///   zone. Midnight rather than an arbitrary instant because on a zone that
    ///   jumps at midnight there is no 00:00, and `startOfDay` is the only API
    ///   that knows it.
    func fires(onDayStarting dayStart: Date, calendar: Calendar) -> Bool {
        switch self {
        case .once:
            // Handled as an instant, not as a day. Reaching here would mean the
            // day walk was asked about a case that has no time of day.
            return false

        case .daily:
            return true

        case .weekly(let days, _):
            guard let weekday = Weekday(rawValue: calendar.component(.weekday, from: dayStart)) else { return false }
            return days.contains(weekday)

        case .monthly(let day, _, let whenShort):
            let dayOfMonth = calendar.component(.day, from: dayStart)
            // `range(of:in:for:)` rather than a table of month lengths: it is
            // right about February in a leap year, and right about the
            // non-Gregorian calendars a user's device can be set to, where
            // months are not 28-31 days at all.
            guard let span = calendar.range(of: .day, in: .month, for: dayStart) else { return false }
            let lastDayOfMonth = span.upperBound - 1
            switch whenShort {
            case .lastDay:
                return dayOfMonth == min(day, lastDayOfMonth)
            case .skip:
                return day <= lastDayOfMonth && dayOfMonth == day
            }
        }
    }
}
