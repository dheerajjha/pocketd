import Foundation

// MARK: - What the model is allowed to ask for

/// The only shapes of health question the tool accepts.
///
/// Four names, and deliberately not one tool per metric. Registering a tool
/// injects its schema into the system message of every prompt — 116 guard
/// tokens for this one on a plain chat template and 232 on a tool-native one,
/// measured rather than guessed — against a usable window of 4032 at the
/// default 4096 context. Five health tools would be most of a thousand tokens
/// spent before the user has typed anything. One tool with an enum costs one
/// schema, and a small model picks from four words far more reliably than it
/// picks between five similarly-named tools.
///
/// The raw values are what the model literally reads in the schema, so they are
/// snake_case like `CalendarRange`.
public enum HealthFocus: String, Sendable, Codable, CaseIterable {
    case activity
    case heart
    case sleep
    case workouts

    /// What a focus is made of. Grouped rather than split one metric per name:
    /// steps without active energy answers half of "how active have I been",
    /// and a second tool round to get the other half does not exist — the loop
    /// runs once, on purpose.
    public var metrics: [HealthMetric] {
        switch self {
        case .activity: [.steps, .active_energy, .exercise_minutes]
        case .heart: [.resting_heart_rate, .heart_rate_variability, .walking_heart_rate]
        // Respiratory rate is recorded while asleep and belongs with the night
        // it was measured on, not with the resting metrics it resembles.
        case .sleep: [.sleep, .respiratory_rate]
        case .workouts: []
        }
    }

    /// How far back the store is asked to look, in days.
    ///
    /// Three years for the quantity metrics, because that is where the long
    /// memory lives: HealthKit aggregates those into one bucket per day before
    /// they cross the process boundary, so a thousand buckets is a thousand
    /// doubles and the query cost is the daemon's, not ours. It is also the
    /// whole point of doing this on the device — a service that keeps ninety
    /// days cannot say "since May" in September, however large its model.
    ///
    /// Sleep gets six months instead, and the reason is volume rather than
    /// policy: sleep arrives as raw stage samples, twenty to sixty a night with
    /// a watch, and three years of those is tens of thousands of objects to
    /// build and marshal inside a chat turn. Six months still covers a 28-day
    /// baseline with five months of reach behind it, and `HealthSuperlative`
    /// says which of the two claims it is making, so the shorter reach is
    /// reported rather than papered over.
    ///
    /// Workouts are a list, not a series. Four weeks is what "recently" means.
    public var historyDays: Int {
        switch self {
        case .activity, .heart: 1096
        case .sleep: 180
        case .workouts: 28
        }
    }

    var noun: String {
        switch self {
        case .activity: "activity"
        case .heart: "heart"
        case .sleep: "sleep"
        case .workouts: "workout"
        }
    }
}

// MARK: - What comes back from the store

/// One workout, reduced to values that can leave the actor that read it.
public struct WorkoutRow: Sendable, Equatable {
    /// Already turned into words. `HKWorkoutActivityType` is an integer enum
    /// with no display name of its own, and the raw number means nothing to
    /// anybody.
    public var activity: String
    public var start: Date
    public var duration: TimeInterval
    /// Active energy, in kilocalories. Optional because a workout logged by
    /// hand has none, and inventing a zero would report a forty-minute run that
    /// burned nothing.
    public var energyKilocalories: Double?

    public init(activity: String, start: Date, duration: TimeInterval, energyKilocalories: Double? = nil) {
        self.activity = activity
        self.start = start
        self.duration = duration
        self.energyKilocalories = energyKilocalories
    }
}

/// Whether there is a Health store to talk to at all.
///
/// Note what is *not* in here: any notion of granted or denied. An app cannot
/// tell the difference for a read type — Apple's own words are that your app
/// does not know whether someone granted or denied permission to read data, and
/// `authorizationStatus(for:)` answers about writing. A case called `.denied`
/// would be a lie the whole UI would then repeat.
public enum HealthAvailability: Sendable, Equatable {
    case available
    /// `HKHealthStore.isHealthDataAvailable()` said no. True on some iPads and
    /// in some managed configurations.
    case noHealthData
    /// The authorization request itself could not be put to the user. Carries
    /// the reason so the sentence is not "something went wrong".
    case requestFailed(String)
}

/// Everything one read of the store produced. Never an error.
///
/// A thrown error from a tool body propagates out of the inference library's
/// executor and ends the generation — the user watches the stream stop
/// mid-sentence with nothing to read. Every failure here is a value instead,
/// exactly as in `PersonalDataLookup`.
public struct HealthReadout: Sendable {
    public var availability: HealthAvailability
    /// Daily buckets or discrete readings, per metric. A metric with no entry
    /// and a metric with an empty array mean the same thing and are reported
    /// the same way.
    public var samples: [HealthMetric: [HealthSample]]
    public var sleep: [SleepInterval]
    public var workouts: [WorkoutRow]
    /// Set when a query hit its own cap and there were more rows behind it.
    public var truncated: Bool

    public init(
        availability: HealthAvailability = .available,
        samples: [HealthMetric: [HealthSample]] = [:],
        sleep: [SleepInterval] = [],
        workouts: [WorkoutRow] = [],
        truncated: Bool = false
    ) {
        self.availability = availability
        self.samples = samples
        self.sleep = sleep
        self.workouts = workouts
        self.truncated = truncated
    }
}

// MARK: - The tool body

/// Everything the health tool does, minus HealthKit.
///
/// Same split as `PersonalDataTools`, for the same reason and one more. The
/// parts worth being sure about — that a network caller causes no read, that a
/// missing reading is never reported as a refusal, that a three-day history
/// produces an honest answer rather than a confident one — need neither a device
/// nor a Health database to exercise, and the package tests run on macOS where
/// there is no Health store to have one.
public enum HealthSummary {

    /// Cap on workout rows. Eight rather than twenty: a workout line is longer
    /// than a calendar line, and four weeks of workouts for someone who trains
    /// daily is twenty-eight rows the answer would then have to fit alongside.
    public static let rowLimit = 8

    /// Cap on the long-memory lines. Three is what fits in one clause of an
    /// answer, and the fourth-best thing about your week is not interesting.
    public static let notableLimit = 3

    /// The lengths a streak has to reach before it is worth a sentence. Two
    /// consecutive days is a coincidence.
    public static let minimumStreakDays = 3

    // MARK: Entry point

    /// - Parameter read: The actual Health read. Never called for an origin that
    ///   may not have the data — the refusal is decided before this closure
    ///   exists, which is the property the origin tests assert.
    public static func payload(
        focus: HealthFocus,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        origin: RequestOrigin = ToolContext.origin,
        read: @Sendable (HealthFocus, DateInterval) async -> HealthReadout
    ) async -> [String: any Sendable] {
        // First, before the window is even resolved, and long before HealthKit
        // is touched: a network client asking this must cause no read of the
        // user's health data at all. Not a filtered read, not an empty one —
        // none. Loopback is not privileged: the /chat page the phone serves
        // arrives as 127.0.0.1 and is a network client like any other.
        guard origin.mayReachPersonalData else {
            return ["text": ToolContext.refusal]
        }

        let readout = await read(focus, window(for: focus, now: now, calendar: calendar))

        switch readout.availability {
        case .noHealthData:
            return ["text": "Health data is not available on this device, so there is nothing to read."]
        case .requestFailed(let reason):
            return ["text": "Pocketd could not ask iOS for access to Health: \(reason)"]
        case .available:
            break
        }

        switch focus {
        case .workouts:
            return workoutPayload(readout, locale: locale, timeZone: timeZone, calendar: calendar)
        case .activity, .heart, .sleep:
            return seriesPayload(focus, readout, now: now, calendar: calendar, locale: locale, timeZone: timeZone)
        }
    }

    /// What the store is asked for, in the user's own calendar.
    ///
    /// The end is the start of tomorrow rather than `now`, so that today's
    /// partial figures are read: whether a partial day may be *reported* is a
    /// separate decision, made per metric in `mostRecentComparableDay`, and
    /// truncating the query here would take it away from that.
    public static func window(for focus: HealthFocus, now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        // Calendar arithmetic, not a multiplication: three years of days is not
        // 1096 × 86,400 seconds in any zone that observes daylight saving, and
        // the error compounds — six hours over three years, which moves the
        // first bucket onto the wrong day.
        let start = HealthArithmetic.startOfDay(today, offsetBy: -focus.historyDays, calendar: calendar)
        let end = HealthArithmetic.startOfDay(today, offsetBy: 1, calendar: calendar)
        return DateInterval(start: start, end: end)
    }

    // MARK: Series

    private static func seriesPayload(
        _ focus: HealthFocus,
        _ readout: HealthReadout,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [String: any Sendable] {
        var readings: [String] = []
        var notable: [String] = []
        var missing: [String] = []

        for metric in focus.metrics {
            let days = metric == .sleep
                ? HealthArithmetic.nightlyTotals(readout.sleep, calendar: calendar)
                : HealthArithmetic.daily(readout.samples[metric] ?? [], metric: metric, calendar: calendar)

            guard let latest = HealthArithmetic.mostRecentComparableDay(
                in: days, metric: metric, now: now, calendar: calendar
            ) else {
                if days.isEmpty {
                    missing.append(metric.label)
                } else {
                    // A third state again, and a real one: someone on their
                    // first day with the app has steps, but only today's, and
                    // today is still going up. Filing that under "no data" would
                    // be the same conflation this whole file exists to avoid.
                    readings.append("\(metric.label): only today's figures exist so far, and a day still being added to cannot be measured against whole ones.")
                }
                continue
            }

            // The incomplete-day rule cannot stop at the reading line. `latest`
            // is the last day that is finished; anything after it is today's
            // partial figure, and a streak or a record judged against a
            // morning's worth of steps is either broken by a number still going
            // up or set by one. A phone always has some steps for today, so
            // without this the 10,000-step and 30-minute streaks never fire at
            // all in real use — they are only ever compared against 9am.
            let history = days.filter { $0.day <= latest.day }

            readings.append(reading(
                metric: metric, latest: latest, days: history, now: now,
                calendar: calendar, locale: locale, timeZone: timeZone
            ))
            notable.append(contentsOf: longMemory(
                metric: metric, days: history, now: now,
                calendar: calendar, locale: locale, timeZone: timeZone
            ))
        }

        guard !readings.isEmpty else {
            // Nothing at all came back. This is the sentence the whole feature
            // has to get right, and the one every health app gets wrong: iOS
            // reports a read the user refused and a read with nothing behind it
            // identically, byte for byte, so any wording that picks one is a
            // guess presented as a fact. Both possibilities, named, and the
            // screen that settles it.
            return ["text": ambiguity(for: focus)]
        }

        var data: [String: any Sendable] = ["readings": readings]
        if !notable.isEmpty {
            data["notable"] = Array(notable.prefix(notableLimit))
        }
        if !missing.isEmpty {
            data["no_data"] = missing.joined(separator: ", ")
            // Once, at the top, not on every missing metric — the same economy
            // as the reminder tool's priority scale. It is three sentences and
            // it would otherwise be repeated per metric.
            data["note"] = ambiguityNote
        }
        return data
    }

    /// One metric, one line, arithmetic already done.
    ///
    /// A finished clause rather than a bag of numbers, because the model's job
    /// here is to select and connect, not to divide. Handed `mean` and `value`
    /// separately a 1.7B model will compute the percentage itself, and it will
    /// get it wrong often enough to matter — this is the exact class of claim
    /// that sounds authoritative and is unverifiable by the reader.
    static func reading(
        metric: HealthMetric,
        latest: DailyValue,
        days: [DailyValue],
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let value = HealthFormat.value(latest.value, metric: metric, locale: locale)
        // How old the figure is decides how it is dated. `PersonalDataFormat.day`
        // prints no year, so a reading from last June and one from the June
        // before look identical, and both look like this week to a model that is
        // told nothing else.
        let age = HealthArithmetic.dayGap(from: latest.day, to: now, calendar: calendar)
        let stale = age > HealthArithmetic.currentWithinDays
        let on = HealthFormat.day(latest.day, includingYear: stale, locale: locale, timeZone: timeZone, calendar: calendar)

        let line: String
        if let baseline = HealthArithmetic.baseline(of: days, endingBefore: latest.day, calendar: calendar) {
            let comparison = HealthArithmetic.compare(value: latest.value, on: latest.day, metric: metric, to: baseline)
            let mean = HealthFormat.value(baseline.mean, metric: metric, locale: locale)

            if let delta = comparison.percentDelta, abs(delta) >= 0.5 {
                let magnitude = HealthFormat.percent(abs(delta), locale: locale)
                let sense = delta > 0 ? "above" : "below"
                line = "\(metric.label) \(value) on \(on) — \(magnitude) \(sense) your \(baseline.windowDays)-day average of \(mean), \(comparison.band.phrase)."
            } else {
                // Under half a percent, "0% above" is noise dressed as a finding,
                // and a zero mean has no percentage at all.
                line = "\(metric.label) \(value) on \(on), against a \(baseline.windowDays)-day average of \(mean) — \(comparison.band.phrase)."
            }
        } else {
            let carrying = HealthArithmetic.daysCarryingData(
                in: days, endingBefore: latest.day, calendar: calendar
            ).count
            // The honest answer, and specific about why: a user with a new phone
            // is owed "not yet" and a number, not a percentage computed from
            // three days.
            line = "\(metric.label) \(value) on \(on). Only \(carrying) of the previous \(HealthArithmetic.baselineWindowDays) days carry \(metric.noun) data, and a usual range needs \(HealthArithmetic.minimumBaselineDays), so there is nothing to compare this against yet."
        }

        guard stale else { return line }
        // Said outright rather than left to the date. A dated line is only
        // unambiguous to a reader who checks the date against today, and the
        // reader here is a 1.7B model that will otherwise narrate the freshest
        // figure it was handed as "last night".
        return "\(line) That reading is \(age) days old — it is the newest whole day of \(metric.noun) data on this iPhone, and it does not describe today."
    }

    /// The claims a ninety-day retention window cannot make.
    ///
    /// Every sentence below is present tense about the last day in `days`, and
    /// carries no date of its own: "Highest sleep since May 2025." and "5 nights
    /// in a row over 8 hours." are both heard as *last night*. That is true
    /// while the series reaches the present and false the moment it stops — a
    /// user who left their watch on the charger in June is told in September
    /// that they are on a streak. So the whole block is gated on the last day
    /// still being current, rather than each line being taught to date itself:
    /// a record set three months ago is trivia, and the dated reading line above
    /// it already says everything true that is left to say.
    static func longMemory(
        metric: HealthMetric,
        days: [DailyValue],
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [String] {
        var lines: [String] = []

        guard let latest = days.last else { return lines }
        let age = HealthArithmetic.dayGap(from: latest.day, to: now, calendar: calendar)
        guard age >= 0, age <= HealthArithmetic.currentWithinDays else { return lines }

        if let superlative = HealthArithmetic.superlative(in: days, direction: metric.direction, calendar: calendar) {
            let superlativeWord = metric.direction == .lowerIsBetter ? "Lowest" : "Highest"
            switch superlative {
            case let .bestSince(day, _):
                lines.append("\(superlativeWord) \(metric.subjectNoun) since \(HealthFormat.monthAndYear(day, locale: locale, timeZone: timeZone, calendar: calendar)).")
            case let .bestInReach(spanDays, dayCount):
                // Not "ever". The series reaches back this far and no further,
                // and the difference between those two claims is the difference
                // between a true statement and a flattering one.
                //
                // The count and the reach are both named because they are not
                // the same number and the sentence used to quote the reach as
                // though it were the count — "in the 40 days of step data on
                // this iPhone" over two readings a month apart.
                lines.append("\(superlativeWord) \(metric.subjectNoun) in all \(dayCount) days of \(metric.noun) data on this iPhone, which reach back \(spanDays) days.")
            }
        }

        if let threshold = streakThreshold(for: metric),
           let streak = HealthArithmetic.streak(in: days, asOf: now, calendar: calendar, where: { $0 >= threshold.value }),
           streak.length >= minimumStreakDays {
            lines.append("\(streak.length) \(threshold.dayNoun)\(streak.length == 1 ? "" : "s") in a row \(threshold.clause).")
        }

        return lines
    }

    /// The round numbers a streak is counted against.
    ///
    /// Conventional figures rather than the user's own baseline, and that is the
    /// deliberate choice: by construction roughly half of anyone's days sit above
    /// their own mean, so runs of three or more happen every couple of weeks and
    /// a "streak" against a baseline is a statement about arithmetic rather than
    /// about the user. Eight hours, ten thousand steps and thirty minutes are
    /// numbers people already hold themselves to. They are not advice, and
    /// nothing here suggests a target — the line only ever reports what happened.
    ///
    /// Active energy, resting heart rate and HRV get no streak: there is no
    /// figure for those that means the same thing to two different people.
    static func streakThreshold(for metric: HealthMetric) -> (value: Double, dayNoun: String, clause: String)? {
        switch metric {
        case .sleep: (8 * 3600, "night", "over 8 hours")
        case .steps: (10_000, "day", "over 10,000 steps")
        case .exercise_minutes: (30, "day", "with 30 minutes or more of exercise")
        case .active_energy, .resting_heart_rate, .heart_rate_variability,
             .walking_heart_rate, .respiratory_rate: nil
        }
    }

    // MARK: Workouts

    private static func workoutPayload(
        _ readout: HealthReadout,
        locale: Locale,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> [String: any Sendable] {
        let rows = readout.workouts
            .sorted { $0.start > $1.start }  // most recent first, which is what "recently" means
            .prefix(rowLimit)
            .map { row -> String in
                let when = PersonalDataFormat.moment(row.start, locale: locale, timeZone: timeZone, calendar: calendar)
                let minutes = HealthFormat.duration(row.duration)
                guard let energy = row.energyKilocalories, energy > 0 else {
                    return "\(row.activity), \(when) — \(minutes)."
                }
                return "\(row.activity), \(when) — \(minutes), \(HealthFormat.value(energy, metric: .active_energy, locale: locale))."
            }

        guard !rows.isEmpty else {
            return ["text": ambiguity(for: .workouts)]
        }

        var data: [String: any Sendable] = ["workouts": Array(rows)]
        if readout.workouts.count > rowLimit || readout.truncated {
            data["note"] = "Only the \(rowLimit) most recent workouts are listed; there are more."
        }
        return data
    }

    // MARK: The third state

    /// The sentence for "nothing came back", written to be true either way.
    ///
    /// No UI and no tool result in this app may say the user denied a read. It
    /// cannot be known: `authorizationStatus(for:)` reports write access, and a
    /// refused read returns the same empty result as a type nobody has ever
    /// recorded. Claiming a denial sends a user who simply has no watch to a
    /// settings screen where nothing is wrong, and claiming "no data" to a user
    /// who refused hides the switch that would fix it.
    static func ambiguity(for focus: HealthFocus) -> String {
        "No \(focus.noun) data came back from Health. \(ambiguityNote)"
    }

    static let ambiguityNote = "That can mean nothing has been recorded, or that Pocketd was not allowed to read it — iOS deliberately does not tell an app which, so neither can be ruled out. Health permissions are under Settings > Privacy & Security > Health > Pocketd."
}

// MARK: - Numbers on their way to the model

/// Turns measurements into strings before they go anywhere near a tool result.
///
/// Everything a tool returns is handed to `JSONSerialization`, which throws on a
/// `Date` and on a non-finite `Double`. LocalLLMClient catches that and falls
/// back to interpolating the dictionary, so the failure is silent: the model
/// quietly reads a UTC timestamp, or `inf`, and repeats it. Formatting here, in
/// the user's locale and zone, is the only way the model sees a number the user
/// would recognise.
public enum HealthFormat {

    public static func value(_ value: Double, metric: HealthMetric, locale: Locale = .current) -> String {
        guard value.isFinite else { return "unavailable" }
        switch metric {
        case .sleep:
            return duration(value)
        case .steps:
            // No unit word. Every line that carries this number is already
            // labelled "Steps", and "Steps 8,000 steps" is a stutter the model
            // repeats verbatim.
            return number(value, digits: metric.fractionDigits, locale: locale)
        case .active_energy:
            return "\(number(value, digits: metric.fractionDigits, locale: locale)) kcal"
        case .exercise_minutes:
            return "\(number(value, digits: metric.fractionDigits, locale: locale)) min"
        case .resting_heart_rate:
            return "\(number(value, digits: metric.fractionDigits, locale: locale)) bpm"
        case .heart_rate_variability:
            return "\(number(value, digits: metric.fractionDigits, locale: locale)) ms"
        case .walking_heart_rate:
            return "\(number(value, digits: metric.fractionDigits, locale: locale)) bpm"
        case .respiratory_rate:
            // One decimal, unlike everything else here: a breathing rate moves
            // between 13 and 17, and rounding to whole breaths throws away most
            // of the signal the comparison is built on.
            return "\(number(value, digits: 1, locale: locale)) breaths/min"
        }
    }

    /// Hours and minutes, never a decimal count of hours. "7.75 hours" is a
    /// number nobody says out loud, and a model handed one will convert it in
    /// the answer and get 7 hours 45 minutes wrong about as often as right.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 m" }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) m" }
        if remainder == 0 { return "\(hours) h" }
        return "\(hours) h \(remainder) m"
    }

    public static func percent(_ value: Double, locale: Locale = .current) -> String {
        // Whole percents. A tenth of a percent implies a precision that a mean
        // of sixteen noisy days does not have.
        "\(number(value, digits: 0, locale: locale))%"
    }

    /// `Thu, Sep 11`, or `Thu, Jun 12, 2025` when the day is old enough that a
    /// reader would otherwise assume this week.
    ///
    /// Delegates for the ordinary case rather than reimplementing it, so a
    /// health line and a calendar line never start writing dates two different
    /// ways. `PersonalDataFormat.day` deliberately omits the year — for a
    /// reminder due on Thursday that is right — and this adds it back only where
    /// its absence would let a months-old reading pass for a current one.
    public static func day(
        _ date: Date,
        includingYear: Bool,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        guard includingYear else {
            return PersonalDataFormat.day(date, locale: locale, timeZone: timeZone, calendar: calendar)
        }
        return date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
                .weekday(.abbreviated)
                .day()
                .month(.abbreviated)
                .year()
        )
    }

    /// `May 2025`. The year is spelled out here, unlike in `PersonalDataFormat`,
    /// because the whole claim a superlative makes is about distance in time and
    /// "since May" is ambiguous the moment the reach passes a year.
    public static func monthAndYear(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
                .month(.wide)
                .year()
        )
    }

    /// A number the model can only read one way.
    ///
    /// Deliberately not locale-formatted, and the `locale` argument is ignored
    /// rather than removed so callers keep passing the one they use for dates —
    /// month names read better localised and a model handles them fine.
    /// Grouped digits do not: on a German phone `.locale(locale)` renders 12000
    /// steps as "12.000", and a 1.7B model reads that as twelve about as often
    /// as as twelve thousand. French inserts U+202F inside the number, and
    /// Arabic emits Arabic-Indic digits beside the ASCII ones this file's
    /// duration formatter produces — two numeral systems in one sentence.
    ///
    /// This is the same hazard `duration` already documents for decimal hours
    /// ("7.75 hours is a number nobody says out loud"). It was solved there and
    /// reintroduced here, in the one payload where a misread number is a wrong
    /// answer about somebody's body.
    static func number(_ value: Double, digits: Int, locale: Locale) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(digits))
                .grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
    }
}
