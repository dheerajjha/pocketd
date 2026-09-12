import Foundation

/// Turns a `Recurrence` into actual instants.
///
/// Every function takes `now` and a `Calendar` rather than reading `Date()` and
/// `.current`, for the same reason `PersonalDataRange` does: daylight saving,
/// time-zone moves, leap days and short months are all exercised against fixed
/// inputs on a machine with no clock worth trusting.
///
/// The algorithm is a *day walk*, and the separation it enforces is the point:
/// **which day** and **what time on it** are answered by different code. It
/// steps whole days with `Calendar.date(byAdding:.day,…)`, re-normalises each
/// step to midnight, asks the rule whether that day belongs to it, and only
/// then places the clock time inside the day with `fireInstant`.
///
/// Placement is where daylight saving actually bites, and `fireInstant` has the
/// note on it. The day step is a calendar operation for a quieter reason: it is
/// the one that keeps the walk's cursor meaningful. Measured, not assumed —
/// `addingTimeInterval(86_400)` here happens to produce the same answers,
/// because `Calendar.date(bySettingHour:of:)` re-derives the day from whatever
/// instant it is handed, so an hour of drift is absorbed. That is a property of
/// Foundation's implementation and not of this design, and the walk should not
/// be resting on it.
public enum FireSequence {

    /// How many days the walk will look at before giving up.
    ///
    /// Generous on purpose. The worst legitimate gap in the current rule set is
    /// `.monthly(day: 31, whenShort: .skip)`, which goes 59 days from 31
    /// January to 31 March; a horizon of a year and a bit leaves room for
    /// patterns that do not exist yet without ever letting a nonsense rule spin
    /// forever. Something has to bound it: a rule that can never match is
    /// reachable from a corrupt file, and this function runs on every
    /// background refresh.
    public static let dayHorizon = 400

    /// The earliest firing strictly after `instant`.
    ///
    /// Strictly after, so that settling a firing and then asking what is next
    /// cannot hand back the firing that was just settled.
    public static func next(after instant: Date, of recurrence: Recurrence, calendar: Calendar = .current) -> Date? {
        if case .once(let when) = recurrence {
            return when > instant ? when : nil
        }
        return walk(from: instant, of: recurrence, calendar: calendar, direction: .forward, inclusive: false)
    }

    /// The latest firing at or before `instant`.
    ///
    /// Inclusive at the top, and that asymmetry with `next` is deliberate: this
    /// is the function that answers "is something owed right now", and a task
    /// evaluated at exactly its firing instant is owed. Exclusive here would
    /// mean a midnight task evaluated at midnight reports yesterday's firing.
    public static func last(onOrBefore instant: Date, of recurrence: Recurrence, calendar: Calendar = .current) -> Date? {
        if case .once(let when) = recurrence {
            return when <= instant ? when : nil
        }
        return walk(from: instant, of: recurrence, calendar: calendar, direction: .backward, inclusive: true)
    }

    // MARK: - The walk

    private static func walk(
        from instant: Date,
        of recurrence: Recurrence,
        calendar: Calendar,
        direction: Calendar.SearchDirection,
        inclusive: Bool
    ) -> Date? {
        guard recurrence.isFireable, let time = recurrence.timeOfDay else { return nil }

        let step = direction == .forward ? 1 : -1
        var dayStart = calendar.startOfDay(for: instant)

        for _ in 0...dayHorizon {
            if recurrence.fires(onDayStarting: dayStart, calendar: calendar),
               let fire = fireInstant(on: dayStart, at: time, calendar: calendar) {
                let accepted = direction == .forward
                    ? (inclusive ? fire >= instant : fire > instant)
                    : (inclusive ? fire <= instant : fire < instant)
                if accepted { return fire }
            }
            guard let stepped = calendar.date(byAdding: .day, value: step, to: dayStart) else { return nil }
            // Re-normalised to midnight rather than carried forward. This is
            // not repairing a drift — `date(byAdding:.day)` keeps the wall
            // clock across a 23- or 25-hour day, which is exactly why it is
            // used instead of adding seconds. It is keeping the cursor
            // canonical: `Recurrence.fires(onDayStarting:)` reads `.weekday`
            // and `.day` off this value and is documented to take the start of
            // a day, and a loop whose cursor slowly becomes "some time on a
            // day" is one edit away from making that documentation false.
            dayStart = calendar.startOfDay(for: stepped)
        }
        return nil
    }

    /// Puts a clock time inside a given day.
    ///
    /// `date(bySettingHour:…)` rather than building `DateComponents` and calling
    /// `date(from:)`, because of the two hours a year that do not exist.
    ///
    /// - `matchingPolicy: .nextTime` decides what a 01:30 task does on the
    ///   morning a zone jumps 01:00 → 02:00: it fires at the next time that
    ///   does exist, which is 02:00. The alternative, `.strict`, returns
    ///   nothing and the task silently skips a day once a year.
    /// - `repeatedTimePolicy: .first` decides what it does on the morning the
    ///   zone falls back and 01:30 happens twice. Once, on the first one. A
    ///   task that fires twice is the failure users actually report, because a
    ///   notification arriving an hour after the identical one is obviously
    ///   broken in a way that a slightly-late one is not.
    static func fireInstant(on dayStart: Date, at time: TimeOfDay, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: dayStart,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

// MARK: - What is owed

/// Whether a task has a firing outstanding, and when the next one lands.
///
/// The shape matters more than the arithmetic. A phone is off, in a drawer, or
/// refused a background slot for nine hours at a time; the question a scheduler
/// has to answer is not "did the moment pass" but "what do I owe this person
/// now". Missed firings therefore **collapse**: three mornings of a daily task
/// produce one run and one notification, not three. Nobody has ever wanted the
/// other behaviour, and iOS will happily deliver all three at once.
public struct Dueness: Sendable, Equatable {

    /// The firing that is owed — the most recent one that has not been settled
    /// — or `nil` when nothing is.
    public var owed: Date?

    /// How many firings before `owed` were skipped and folded into it.
    ///
    /// Reported rather than hidden so the UI can say "last run 3 days ago,
    /// 2 runs missed" instead of pretending the schedule was kept. Saturates at
    /// `missedCap`: counting them means walking the sequence, and a task left
    /// alone for a year is not worth 365 calendar operations on a background
    /// wake-up to tell the user a number they will read as "lots".
    public var missed: Int

    /// The first firing strictly after `now`. This is the date the app hands to
    /// `UNCalendarNotificationTrigger`.
    public var next: Date?

    /// Saturation point for `missed`. See above.
    public static let missedCap = 99

    public static let idle = Dueness(owed: nil, missed: 0, next: nil)

    public init(owed: Date?, missed: Int, next: Date?) {
        self.owed = owed
        self.missed = missed
        self.next = next
    }

    public var isDue: Bool { owed != nil }

    /// - Parameter settledThrough: The latest firing already dealt with. A task
    ///   sets this to its creation date, which is what stops a daily 09:00 task
    ///   created at 14:00 from firing immediately for a morning that had
    ///   already gone before it existed.
    public static func of(
        _ recurrence: Recurrence,
        settledThrough: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Dueness {
        let next = FireSequence.next(after: now, of: recurrence, calendar: calendar)

        guard let owed = FireSequence.last(onOrBefore: now, of: recurrence, calendar: calendar),
              owed > settledThrough
        else {
            return Dueness(owed: nil, missed: 0, next: next)
        }

        var missed = 0
        var cursor = settledThrough
        while missed < missedCap,
              let fire = FireSequence.next(after: cursor, of: recurrence, calendar: calendar),
              fire < owed {
            missed += 1
            cursor = fire
        }
        return Dueness(owed: owed, missed: missed, next: next)
    }
}
