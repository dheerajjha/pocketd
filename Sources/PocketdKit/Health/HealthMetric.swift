import Foundation

// MARK: - Vocabulary

/// The unit a number was recorded in.
///
/// Carried on the sample rather than inferred from the metric because the
/// conversion happens on the far side of an `HKQuantity`, where picking
/// `HKUnit.secondUnit(with: .milli)` instead of `.second()` for HRV is a
/// one-character mistake that produces a number a thousand times too large and
/// no error at all. A baseline built from those is wrong and confident. Bucketing
/// drops samples whose unit does not match their metric, which turns that silent
/// error into a visible "not enough data yet".
public enum HealthUnit: String, Sendable, Codable, CaseIterable {
    case count
    case kilocalorie
    case minute
    case kilometer
    case kilogram
    case beatsPerMinute = "bpm"
    case breathsPerMinute = "breaths/min"
    case millisecond = "ms"
    /// Sleep and mindful sessions, which arrive as intervals rather than as a
    /// recorded quantity.
    case second
    /// Blood oxygen, in the magnitude HealthKit keeps it in: `HKUnit.percent()`
    /// measures a value between 0 and 1, so a saturation of 98% arrives as 0.98.
    /// This is the one unit here whose HealthKit spelling means something other
    /// than it looks like, and naming the magnitude rather than the sign is what
    /// keeps the hundredfold in one place — `HealthFormat`, beside the sign it
    /// prints.
    case fractionOfOne
    /// VO2 max. HealthKit normalises the compound unit to `mL/min·kg` whichever
    /// order it is assembled in, and everybody else writes the mass first, so
    /// the two spellings have to be held apart rather than assumed equal.
    case millilitersPerKilogramMinute = "mL/kg·min"

    /// How HealthKit spells this unit in `HKUnit.unitString`.
    ///
    /// Kept here, in the half of the app that has no HealthKit in it, so that
    /// the tag on a sample can be worked out from the unit a value was *read*
    /// with rather than copied from the metric it was read *for*. Copying is
    /// what makes the mismatch check in `daily` vacuous: both sides then come
    /// from the same `switch`, and a change to the read unit changes the number
    /// and the label together, which is precisely the silent rescaling this is
    /// supposed to catch.
    public var hkUnitString: String {
        switch self {
        case .count: "count"
        case .kilocalorie: "kcal"
        case .minute: "min"
        case .kilometer: "km"
        case .kilogram: "kg"
        // One unit to HealthKit, two names here. A pulse and a breathing rate
        // are both counts per minute; the two names exist so a rendered line
        // reads correctly, not because the magnitudes differ.
        case .beatsPerMinute, .breathsPerMinute: "count/min"
        case .millisecond: "ms"
        case .second: "s"
        case .fractionOfOne: "%"
        case .millilitersPerKilogramMinute: "mL/min·kg"
        }
    }

    /// The unit a value read in `hkUnitString` is actually in.
    ///
    /// `preferred` breaks the `count/min` tie and nothing else: it is consulted
    /// only when it already agrees with the string HealthKit itself printed, so
    /// it can choose between two names for one magnitude but can never talk the
    /// answer into a magnitude the reading did not have. Ask for HRV in seconds
    /// and this returns `.second` however firmly the caller preferred
    /// `.millisecond` — which is what makes the mismatch reachable.
    public static func named(_ hkUnitString: String, preferring preferred: HealthUnit) -> HealthUnit? {
        if preferred.hkUnitString == hkUnitString { return preferred }
        return allCases.first { $0.hkUnitString == hkUnitString }
    }
}

/// How a day's worth of a metric is made from the samples inside it.
public enum HealthAggregation: Sendable, Equatable {
    /// Steps at 09:00 and steps at 17:00 are different steps.
    case sum
    /// Two resting heart rates on one day are two readings of one thing, and
    /// adding them would report a pulse of 140.
    case mean
}

/// Which way "better" points, used only to decide whether an extreme is worth
/// mentioning. A record-low resting heart rate is news; a record-high one is a
/// thing to say carefully or not at all, and this app does not diagnose.
public enum HealthDirection: Sendable, Equatable {
    case higherIsBetter
    case lowerIsBetter
    /// No extreme is ever announced. For a vital with a normal band on both
    /// sides, "lowest respiratory rate since May" is neither good news nor bad
    /// news, and a summary that presents it as either is making a clinical
    /// claim it is not entitled to make.
    case neither
}

/// One thing the summary knows how to reason about.
///
/// Raw values are snake_case because they are what the model reads in the
/// payload, and every tool-trained chat template writes its keys that way.
public enum HealthMetric: String, Sendable, Codable, CaseIterable {
    case steps
    case active_energy
    case exercise_minutes
    case distance
    case stand_hours
    case resting_heart_rate
    case heart_rate_variability
    case walking_heart_rate
    case heart_rate
    case blood_oxygen
    case respiratory_rate
    case sleep
    case mindful_minutes
    case body_mass
    case vo2_max

    public var label: String {
        switch self {
        case .steps: "Steps"
        case .active_energy: "Active energy"
        case .exercise_minutes: "Exercise"
        case .distance: "Distance"
        case .stand_hours: "Stand hours"
        case .resting_heart_rate: "Resting heart rate"
        case .heart_rate_variability: "Heart rate variability"
        case .walking_heart_rate: "Walking heart rate"
        case .heart_rate: "Heart rate"
        case .blood_oxygen: "Blood oxygen"
        case .respiratory_rate: "Respiratory rate"
        case .sleep: "Sleep"
        case .mindful_minutes: "Mindful minutes"
        // Health's own word for `bodyMass`, and the one anybody says out loud.
        case .body_mass: "Weight"
        case .vo2_max: "VO2 max"
        }
    }

    /// Lower case, for the middle of a sentence.
    public var noun: String {
        switch self {
        case .steps: "step"
        case .active_energy: "active energy"
        case .exercise_minutes: "exercise"
        case .distance: "distance"
        case .stand_hours: "stand hour"
        case .resting_heart_rate: "resting heart rate"
        case .heart_rate_variability: "heart rate variability"
        case .walking_heart_rate: "walking heart rate"
        case .heart_rate: "heart rate"
        case .blood_oxygen: "blood oxygen"
        case .respiratory_rate: "respiratory rate"
        case .sleep: "sleep"
        case .mindful_minutes: "mindfulness"
        case .body_mass: "weight"
        case .vo2_max: "VO2 max"
        }
    }

    /// The same noun standing on its own, as the thing a clause is about.
    ///
    /// `noun` is attributive — "step data", "a day of step data" — and reads
    /// wrong the moment it carries a sentence by itself: "Highest step since
    /// August 2025." The two forms part company for the metrics that are counted
    /// rather than measured, and the switch is exhaustive so a metric added later
    /// has to answer the question rather than inherit the wrong answer. The
    /// payload hands the model finished clauses to select and connect, never ones
    /// to repair.
    public var subjectNoun: String {
        switch self {
        case .steps: "steps"
        case .stand_hours: "stand hours"
        case .mindful_minutes: "mindful minutes"
        case .active_energy, .exercise_minutes, .distance, .resting_heart_rate,
             .heart_rate_variability, .walking_heart_rate, .heart_rate, .blood_oxygen,
             .respiratory_rate, .sleep, .body_mass, .vo2_max: noun
        }
    }

    public var unit: HealthUnit {
        switch self {
        case .steps: .count
        case .active_energy: .kilocalorie
        case .exercise_minutes: .minute
        // Kilometres and kilograms for everybody, not the region the phone is
        // set to, for the reason `HealthFormat.number` refuses locale grouping:
        // this payload is read by a 1.7B model before any of it reaches a
        // person, and one unit everywhere is one fewer thing for it to get
        // wrong. The unit word is printed beside every figure either way.
        case .distance: .kilometer
        case .stand_hours: .count
        case .resting_heart_rate: .beatsPerMinute
        case .heart_rate_variability: .millisecond
        case .walking_heart_rate: .beatsPerMinute
        case .heart_rate: .beatsPerMinute
        case .blood_oxygen: .fractionOfOne
        case .respiratory_rate: .breathsPerMinute
        case .sleep: .second
        case .mindful_minutes: .second
        case .body_mass: .kilogram
        case .vo2_max: .millilitersPerKilogramMinute
        }
    }

    public var aggregation: HealthAggregation {
        switch self {
        case .steps, .active_energy, .exercise_minutes, .distance, .stand_hours,
             .sleep, .mindful_minutes: .sum
        case .resting_heart_rate, .heart_rate_variability, .walking_heart_rate,
             .heart_rate, .blood_oxygen, .respiratory_rate, .body_mass, .vo2_max: .mean
        }
    }

    public var direction: HealthDirection {
        switch self {
        case .resting_heart_rate, .walking_heart_rate: .lowerIsBetter
        // Two more with no better end, for two different reasons. A raw heart
        // rate is 52 asleep and 150 up a staircase, so a day's mean of it moves
        // with what the day contained rather than with the user — which is the
        // signal `resting_heart_rate` isolates and this one averages away. And
        // there is no weight that is better than another weight. `direction`
        // feeds nothing but the superlative, so the value here is the whole
        // difference between reporting a number and telling somebody it is
        // their best weight since May.
        case .respiratory_rate, .heart_rate, .body_mass: .neither
        case .steps, .active_energy, .exercise_minutes, .distance, .stand_hours,
             .heart_rate_variability, .blood_oxygen, .sleep, .mindful_minutes,
             .vo2_max: .higherIsBetter
        }
    }

    /// Whether today's figure is still being added to.
    ///
    /// Steps at 10:00 are a fraction of a day compared against a mean of whole
    /// ones, which reports the user 60% below their baseline every single
    /// morning. Metrics that accumulate are therefore read from the last day
    /// that is over, and the payload names that day so the user can see which
    /// one it is.
    ///
    /// Sleep accumulates within a night, but a night is attributed to the
    /// morning it ended (see `nightlyTotals`), so by the time anyone asks it is
    /// finished. Asked at four in the morning it is not, which is the one hole
    /// in this and is not worth a second mechanism.
    ///
    /// A mindful session is the same shape of thing and gets no such exception:
    /// it is attributed to the day it began on, and nothing stops another one
    /// happening before that day is over.
    public var accumulatesAcrossTheDay: Bool {
        switch self {
        case .steps, .active_energy, .exercise_minutes, .distance, .stand_hours,
             .mindful_minutes: true
        case .resting_heart_rate, .heart_rate_variability, .walking_heart_rate,
             .heart_rate, .blood_oxygen, .respiratory_rate, .sleep, .body_mass,
             .vo2_max: false
        }
    }

    /// Digits after the point when the number is shown.
    ///
    /// One decimal for the five that move by less than a whole unit at a time: a
    /// breathing rate lives between 13 and 17, a blood oxygen reading between 95
    /// and 100, a VO2 max shifts by a point or two a season, a weight by a few
    /// hundred grams, and a day's walking by a few hundred metres. Rounding any
    /// of those to whole units throws away most of the signal the comparison is
    /// built on. None goes to two, which would claim a precision that a mean of
    /// sixteen noisy days does not have.
    var fractionDigits: Int {
        switch self {
        case .steps, .active_energy, .exercise_minutes, .stand_hours,
             .resting_heart_rate, .heart_rate_variability, .walking_heart_rate,
             .heart_rate, .sleep, .mindful_minutes: 0
        case .distance, .blood_oxygen, .respiratory_rate, .body_mass, .vo2_max: 1
        }
    }
}

// MARK: - Samples

/// One number Health recorded, with nothing HealthKit owns attached to it.
///
/// `HKQuantitySample` is a reference type the store hands out and refreshes
/// behind your back, and it is not `Sendable`. Nothing but this crosses out of
/// the actor that read it, for the same reason `CalendarEventRow` exists.
public struct HealthSample: Sendable, Equatable {
    public var value: Double
    public var unit: HealthUnit
    /// The instant the sample is attributed to. For a daily statistics bucket
    /// this is the bucket's start; for a discrete reading it is when it was
    /// taken.
    public var date: Date

    public init(value: Double, unit: HealthUnit, date: Date) {
        self.value = value
        self.unit = unit
        self.date = date
    }
}

/// One stretch of sleep, as Health records it — in stages, from possibly more
/// than one source at once.
public struct SleepInterval: Sendable, Equatable {
    public var start: Date
    public var end: Date
    /// `false` for in-bed-but-awake and for the awake stage. Time in bed is not
    /// sleep and reporting it as sleep flatters the user by an hour a night.
    public var asleep: Bool

    public init(start: Date, end: Date, asleep: Bool) {
        self.start = start
        self.end = end
        self.asleep = asleep
    }
}

/// One calendar day's worth of a metric.
public struct DailyValue: Sendable, Equatable {
    /// Midnight in the user's calendar, which is what makes two of these
    /// comparable across a daylight saving change.
    public var day: Date
    public var value: Double

    public init(day: Date, value: Double) {
        self.day = day
        self.value = value
    }
}

// MARK: - Baselines

/// What normal looks like for one metric, measured rather than assumed.
public struct HealthBaseline: Sendable, Equatable {
    public var mean: Double
    /// Sample standard deviation, Bessel-corrected. These days are a sample of
    /// the user's days rather than all of them, and the population formula
    /// understates the spread — which biases every judgement toward calling an
    /// ordinary day unusual.
    public var standardDeviation: Double
    /// Days that actually carried a value. Not the window length: a window of
    /// 28 days with 16 readings in it is what most people's Health database
    /// looks like.
    public var dayCount: Int
    public var windowDays: Int

    public init(mean: Double, standardDeviation: Double, dayCount: Int, windowDays: Int) {
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.dayCount = dayCount
        self.windowDays = windowDays
    }

    /// Whether the spread is too small to divide by.
    ///
    /// A user whose resting heart rate reads 60 every day for a month has a
    /// standard deviation of zero, and a z-score against it is either infinite
    /// or NaN. `JSONSerialization` throws on both, which LocalLLMClient
    /// swallows — so the failure is not a crash, it is the whole tool result
    /// silently degrading to interpolated text. The relative floor catches the
    /// near-degenerate case too, where the spread is real but a rounding
    /// artefact and z-scores come out in the hundreds.
    public var spreadIsDegenerate: Bool {
        standardDeviation <= max(1e-9, abs(mean) * 0.001)
    }
}

/// Where one day sits against the usual, in words the user would recognise.
public enum BaselineBand: Sendable, Equatable {
    case wellBelow
    case below
    case usual
    case above
    case wellAbove

    /// Written to be true of the number rather than of the user. "Well above
    /// your usual range" is a fact about a series; "unusually high" is close to
    /// a clinical claim, which this app is not entitled to make.
    public var phrase: String {
        switch self {
        case .wellBelow: "well below your usual range"
        case .below: "below your usual range"
        case .usual: "in your usual range"
        case .above: "above your usual range"
        case .wellAbove: "well above your usual range"
        }
    }
}

/// One day, its baseline, and the arithmetic between them.
public struct HealthComparison: Sendable, Equatable {
    public var metric: HealthMetric
    public var day: Date
    public var value: Double
    public var baseline: HealthBaseline
    /// `nil` when the baseline has no usable spread — never a non-finite
    /// `Double`, which cannot be serialised and cannot be reasoned about.
    public var zScore: Double?
    /// Signed, in percent. `nil` when the mean is zero, where the ratio has no
    /// meaning and the honest answer is to leave the clause out.
    public var percentDelta: Double?
    public var band: BaselineBand
}

// MARK: - Long memory

/// How far back you have to go to find a day this good.
///
/// The distinction between the two cases is the whole honesty of the feature.
/// `bestSince` is a claim about the user's history; `bestInReach` is a claim
/// about the data on the phone, and says so, because a series that only reaches
/// back four months cannot know what happened in the spring.
public enum HealthSuperlative: Sendable, Equatable {
    case bestSince(day: Date, gapDays: Int)
    /// `spanDays` is how far back the series reaches; `dayCount` is how many of
    /// those days actually carry a reading. Both, because they are routinely
    /// nothing like each other — a tracker worn for a week in July and again
    /// this week spans forty days and holds twelve — and a sentence built from
    /// the span alone asserts a history the phone does not have.
    case bestInReach(spanDays: Int, dayCount: Int)
}

/// Consecutive days that all did something.
public struct HealthStreak: Sendable, Equatable {
    public var length: Int
    public var endingOn: Date

    public init(length: Int, endingOn: Date) {
        self.length = length
        self.endingOn = endingOn
    }
}

// MARK: - The arithmetic

/// Everything the health summary knows how to work out, with no HealthKit in
/// sight.
///
/// This is the part that makes a health assistant feel intelligent, and almost
/// none of it is inference: "resting heart rate 71, usually 80 — 11% below your
/// baseline" is a mean and a division. Doing it here rather than asking the
/// model for it is not only cheaper, it is the only way to be right: a 1.7B
/// model asked to average twenty-eight numbers produces a plausible one.
///
/// Every date decision goes through `Calendar`. Days are not 86,400 seconds —
/// a spring-forward day is 23 hours and an autumn one is 25 — and the repo
/// already has tests proving that for calendar windows. Bucketing samples by
/// `startOfDay` is the same problem with the same answer.
public enum HealthArithmetic {

    // MARK: Windows, and why they are these lengths

    /// The baseline window, in days.
    ///
    /// Twenty-eight and not thirty, because twenty-eight is four whole weeks and
    /// therefore contains exactly four of every weekday. Steps and active energy
    /// are strongly weekly — a commute on weekdays, a long walk on Sunday — so a
    /// thirty-day window with five Mondays and four Tuesdays moves the mean by
    /// the shape of the window rather than by anything the user did. Four weeks
    /// is also short enough to follow a real change in someone's life, a new job
    /// or an illness, inside a month rather than a season.
    public static let baselineWindowDays = 28

    /// Days that must actually carry a reading before a baseline is quoted.
    ///
    /// Fourteen, because the standard error on a mean is sd/√n: at 14 days it is
    /// 27% of a standard deviation, at 7 it is 38%, and at 3 it is 58% — by
    /// which point the "baseline" differs from the reading being compared to it
    /// by less than its own noise, and every percentage printed against it is
    /// arithmetic theatre. Fourteen is also two whole weeks, which keeps the
    /// weekday balance the window length was chosen for.
    public static let minimumBaselineDays = 14

    /// How far back an extreme has to reach before it is worth saying.
    ///
    /// "Best since Tuesday" is a description of ordinary variation dressed up as
    /// news. A month is the shortest gap at which "best since" says something the
    /// user did not already know.
    public static let superlativeMinimumGapDays = 30

    /// The longest a single unbroken run of sleep may be before it is treated as
    /// a corrupt record rather than a night.
    ///
    /// A day, because the rule that gives a night its day — it is attributed to
    /// the morning it ended on — stops meaning anything once the run covers more
    /// than one morning.
    public static let maximumNightSeconds: TimeInterval = 24 * 3600

    /// How many days old the most recent day may be while the summary still
    /// speaks about it in the present tense.
    ///
    /// One, and it has to be one rather than zero: an accumulating metric is
    /// read from the last day that is *over* (see `mostRecentComparableDay`), so
    /// the freshest possible steps figure is already yesterday's. Beyond that,
    /// a gap means the phone has no record of yesterday, and "you are on a
    /// five-day streak" is then a claim about days nobody measured.
    public static let currentWithinDays = 1

    // MARK: Bucketing

    /// Samples into calendar days.
    ///
    /// Grouped on `calendar.startOfDay`, which is the only API that knows a day
    /// in a zone that shifts at midnight may have no 00:00 at all. Two samples
    /// 24 hours apart are on the same day when the clocks went back, and on
    /// different days when they went forward; subtracting time intervals gets
    /// both wrong.
    ///
    /// Samples carrying the wrong unit for their metric are dropped rather than
    /// converted. A silent conversion is how HRV in seconds becomes a baseline a
    /// thousand times too large; dropping leaves too few days for a baseline,
    /// which the summary reports honestly.
    public static func daily(
        _ samples: [HealthSample],
        metric: HealthMetric,
        calendar: Calendar
    ) -> [DailyValue] {
        var totals: [Date: (sum: Double, count: Int)] = [:]
        for sample in samples where sample.unit == metric.unit && sample.value.isFinite {
            let day = calendar.startOfDay(for: sample.date)
            let running = totals[day] ?? (0, 0)
            totals[day] = (running.sum + sample.value, running.count + 1)
        }

        return totals
            .map { day, running in
                switch metric.aggregation {
                case .sum: DailyValue(day: day, value: running.sum)
                case .mean: DailyValue(day: day, value: running.sum / Double(running.count))
                }
            }
            .sorted { $0.day < $1.day }
    }

    /// Sleep intervals into the mornings they ended on.
    ///
    /// A night that runs 23:30 Monday to 07:00 Tuesday is attributed to Tuesday,
    /// whole. That is what "I slept seven hours last night" means when it is said
    /// in the morning, and it is what the Health app shows. The cost of the rule
    /// is that an afternoon nap lands on the same day as that morning's sleep and
    /// is added to it — which is also what Health does, and is a truer answer to
    /// "how much did I sleep" than discarding it.
    ///
    /// Overlapping intervals are unioned before anything is summed. Health
    /// routinely holds two sources for one night — a watch writing stages and an
    /// app writing time in bed — and adding those gives fourteen-hour nights.
    /// This is the single most common way a sleep figure goes wrong.
    ///
    /// A merged run longer than `maximumNightSeconds` is discarded rather than
    /// clamped. HealthKit does not validate durations, and one source writing a
    /// single 72-hour "asleep" record chains three ordinary nights into one
    /// implausible figure — reported, it becomes "Sleep 79 h, 1,029% above your
    /// average" with a superlative on top. Clamping it to a day would report 24
    /// hours of sleep, which is no better; dropping it costs the nights the bad
    /// record swallowed and leaves the rest of the series to speak for itself.
    public static func nightlyTotals(
        _ intervals: [SleepInterval],
        calendar: Calendar
    ) -> [DailyValue] {
        let asleep = merge(intervals.filter { $0.asleep && $0.end > $0.start })
            .filter { $0.end.timeIntervalSince($0.start) <= maximumNightSeconds }
        var totals: [Date: Double] = [:]
        for interval in asleep {
            let morning = calendar.startOfDay(for: interval.end)
            totals[morning, default: 0] += interval.end.timeIntervalSince(interval.start)
        }
        return totals
            .map { DailyValue(day: $0.key, value: $0.value) }
            .sorted { $0.day < $1.day }
    }

    /// Unions overlapping and touching intervals, so no second is counted twice.
    static func merge(_ intervals: [SleepInterval]) -> [SleepInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [SleepInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                // Extend rather than append. `max` matters: a short stage sample
                // wholly inside a long in-bed one must not shorten it.
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    // MARK: Baseline

    /// The mean and spread of the `windowDays` days before `day`.
    ///
    /// `day` itself is excluded, and that is not a detail. A day included in its
    /// own baseline drags the baseline toward itself: with 28 days, a day at
    /// twice the mean lifts its own comparison figure by about 3.5% and quietly
    /// understates exactly the day the user asked about.
    ///
    /// Returns `nil` rather than a thin baseline. A mean of three numbers is a
    /// number, and printing a percentage against it is the confident answer this
    /// is meant not to give.
    public static func baseline(
        of days: [DailyValue],
        endingBefore day: Date,
        windowDays: Int = baselineWindowDays,
        minimumDays: Int = minimumBaselineDays,
        calendar: Calendar
    ) -> HealthBaseline? {
        let window = daysCarryingData(in: days, endingBefore: day, windowDays: windowDays, calendar: calendar)
        guard window.count >= minimumDays else { return nil }

        let values = window.map(\.value)
        let mean = values.reduce(0, +) / Double(values.count)
        // Bessel: these are a sample of the user's days, not every day they have
        // ever lived. n is at least `minimumDays`, so the divisor cannot be zero.
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return HealthBaseline(
            mean: mean,
            standardDeviation: variance.squareRoot(),
            dayCount: values.count,
            windowDays: windowDays
        )
    }

    /// The days inside the baseline window that actually carry a reading.
    ///
    /// Exposed because the sentence explaining a missing baseline quotes this
    /// count, and a second copy of the window arithmetic would be free to drift
    /// from the one that made the decision.
    public static func daysCarryingData(
        in days: [DailyValue],
        endingBefore day: Date,
        windowDays: Int = baselineWindowDays,
        calendar: Calendar
    ) -> [DailyValue] {
        let start = startOfDay(day, offsetBy: -windowDays, calendar: calendar)
        return days.filter { $0.day >= start && $0.day < day }
    }

    /// Where a value sits against a baseline.
    ///
    /// The thresholds are one and two standard deviations, which for a roughly
    /// normal metric put about 68% of days inside "usual" and about 5% outside
    /// two — one day in twenty, or once a fortnight. That is the right rate for a
    /// phrase that claims something remarkable; a tighter band makes every
    /// Tuesday remarkable and the user stops reading.
    ///
    /// When the spread is degenerate the z-score is abandoned rather than faked,
    /// and the percentage does the banding on 10% and 25% — deliberately looser,
    /// because without a spread there is no evidence about what is normal
    /// variation for this person and the summary should be harder to impress.
    public static func compare(
        value: Double,
        on day: Date,
        metric: HealthMetric,
        to baseline: HealthBaseline
    ) -> HealthComparison {
        let percentDelta: Double? = baseline.mean == 0
            ? nil
            : ((value - baseline.mean) / abs(baseline.mean)) * 100

        if baseline.spreadIsDegenerate {
            let band: BaselineBand
            switch percentDelta {
            case .none: band = .usual
            case .some(let delta) where abs(delta) < 10: band = .usual
            case .some(let delta) where abs(delta) < 25: band = delta > 0 ? .above : .below
            case .some(let delta): band = delta > 0 ? .wellAbove : .wellBelow
            }
            return HealthComparison(
                metric: metric, day: day, value: value, baseline: baseline,
                zScore: nil, percentDelta: percentDelta.flatMap(finite), band: band
            )
        }

        let z = (value - baseline.mean) / baseline.standardDeviation
        let band: BaselineBand
        switch abs(z) {
        case ..<1: band = .usual
        case ..<2: band = z > 0 ? .above : .below
        default: band = z > 0 ? .wellAbove : .wellBelow
        }
        return HealthComparison(
            metric: metric, day: day, value: value, baseline: baseline,
            zScore: finite(z), percentDelta: percentDelta.flatMap(finite), band: band
        )
    }

    /// Nothing non-finite may leave this file. `JSONSerialization` throws on an
    /// infinity or a NaN, and LocalLLMClient answers that throw by interpolating
    /// the dictionary instead — so one bad division degrades the entire tool
    /// result to `key: value` text with no error anywhere.
    private static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    // MARK: Superlatives

    /// How long it has been since a day as good as the last one.
    ///
    /// This is the claim a ninety-day server retention window physically cannot
    /// make, and the reason it is worth doing on the device: the scan runs over
    /// whatever the phone holds, which is everything the user has ever recorded.
    ///
    /// Returns `nil` when the last day is not an extreme, when the previous
    /// better day is too recent to be interesting, or when the series itself is
    /// too short to be evidence of anything.
    public static func superlative(
        in days: [DailyValue],
        direction: HealthDirection,
        minimumGapDays: Int = superlativeMinimumGapDays,
        calendar: Calendar
    ) -> HealthSuperlative? {
        guard let latest = days.last, days.count > 1 else { return nil }
        let earlier = days.dropLast()

        let atLeastAsGood: (DailyValue) -> Bool
        switch direction {
        case .higherIsBetter: atLeastAsGood = { $0.value >= latest.value }
        case .lowerIsBetter: atLeastAsGood = { $0.value <= latest.value }
        case .neither: return nil
        }

        if let previous = earlier.last(where: atLeastAsGood) {
            let gap = dayGap(from: previous.day, to: latest.day, calendar: calendar)
            guard gap >= minimumGapDays else { return nil }
            return .bestSince(day: previous.day, gapDays: gap)
        }

        // Nothing in the series beats it, so the honest claim is bounded by how
        // far the series reaches — not "your best ever" unless the phone can see
        // that far. Bounded by how *much* it holds as well: a span says nothing
        // about density, and the two entries a lapsed tracker leaves behind span
        // a month with nothing in between.
        guard let first = earlier.first else { return nil }
        let span = dayGap(from: first.day, to: latest.day, calendar: calendar)
        guard span >= minimumGapDays else { return nil }
        return .bestInReach(spanDays: span, dayCount: days.count)
    }

    // MARK: Days

    /// The start of the day `days` away from this one.
    ///
    /// The re-normalisation is the whole point, and it is the one thing every
    /// day calculation in this file has to do. `date(byAdding: .day,)` keeps the
    /// time of day it was given, and in a zone whose clocks go forward *at
    /// midnight* — Santiago, Havana, Beirut, São Paulo, Tehran, some 35 million
    /// people between them — the start of that day is 01:00, because 00:00 never
    /// happened. Step back from it and you land on 01:00 of an ordinary day,
    /// which is not that day's start and never again equals a bucket key. The
    /// hour is then carried along by every later step, so one transition
    /// silently truncates the rest of the walk.
    ///
    /// London, which every daylight-saving test in this repo used before this
    /// one, shifts at 01:00 and therefore always has a midnight — which is
    /// exactly why the drift was invisible there.
    public static func startOfDay(_ date: Date, offsetBy days: Int, calendar: Calendar) -> Date {
        guard let moved = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) else {
            return date
        }
        return calendar.startOfDay(for: moved)
    }

    /// Whole days between two midnights, by calendar rather than by division.
    ///
    /// Two days that straddle a clock change are 23 or 25 hours apart, so
    /// `timeIntervalSince / 86_400` rounds to the wrong integer roughly twice a
    /// year and reports a 30-day gap as 29 — which is the difference between
    /// saying something and staying quiet.
    ///
    /// Counted between middays rather than between the two day starts, and that
    /// is not tidiness. `dateComponents([.day],)` counts whole days from the
    /// *time of day* it starts at: on a day whose midnight was skipped the start
    /// is 01:00, no whole day fits between it and the next day's 00:00, and the
    /// count comes back one short — the staleness note, the currency gate and a
    /// superlative's reach all quietly slip by a day. Midday exists on every
    /// date in every zone and moves with the offset, so both ends carry the same
    /// wall clock and the calendar is left to do the counting.
    public static func dayGap(from: Date, to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day], from: midday(of: from, calendar: calendar), to: midday(of: to, calendar: calendar)
        ).day ?? 0
    }

    /// Built from components rather than searched for, so there is no matching
    /// policy to reason about on the days this exists to survive.
    private static func midday(of date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        components.hour = 12
        return calendar.date(from: components) ?? date
    }

    // MARK: Streaks

    /// Consecutive days ending at the most recent one, all satisfying `predicate`.
    ///
    /// A missing day breaks the streak. Health is full of gaps — a watch left on
    /// the charger, a phone in a coat — and treating a gap as a pass turns "five
    /// nights over eight hours" into a claim about two nights and three absences.
    /// The streak reports only what the data can prove.
    ///
    /// `asOf` is required, and it is the whole difference between a fact and a
    /// lie. A run is only a streak while it reaches the present: anchoring on
    /// `days.last` alone says "you are on a five-night streak" to someone whose
    /// last recorded night was in June, in September, in the present tense, with
    /// no date attached. There is no honest reading of that sentence, so the run
    /// that ended months ago is not a streak and this returns `nil` for it.
    /// `withinDays` is one day rather than none because the freshest figure an
    /// accumulating metric can offer is already yesterday's.
    public static func streak(
        in days: [DailyValue],
        asOf now: Date,
        withinDays: Int = currentWithinDays,
        calendar: Calendar,
        where predicate: (Double) -> Bool
    ) -> HealthStreak? {
        guard let latest = days.last, predicate(latest.value) else { return nil }
        // Calendar days, not a division: two dates either side of a clock change
        // are 23 or 25 hours apart, and `interval / 86_400` calls a one-day-old
        // reading two days old twice a year.
        let age = dayGap(from: latest.day, to: now, calendar: calendar)
        // Bounded below as well as above. A third-party app writing a sample
        // dated next week is not validated by HealthKit anywhere, and a streak
        // that ends in the future is the same wrong claim pointing the other
        // way.
        guard age >= 0, age <= withinDays else { return nil }

        var length = 1
        var expected = latest.day
        for candidate in days.dropLast().reversed() {
            // Through `startOfDay(_:offsetBy:)` rather than a bare subtraction:
            // a chain that keeps its time of day stops matching bucket keys at
            // the first zone transition it crosses, and truncates the streak
            // there and at every step after it.
            let previous = startOfDay(expected, offsetBy: -1, calendar: calendar)
            guard candidate.day == previous, predicate(candidate.value) else { break }
            length += 1
            expected = previous
        }
        return HealthStreak(length: length, endingOn: latest.day)
    }

    /// The last day whose figure is finished.
    ///
    /// For a metric that accumulates, "today" at ten in the morning is a fraction
    /// of a day being compared against a mean of whole ones. Reading the last
    /// completed day instead is the difference between "40% below your usual" every
    /// morning and an answer that means something.
    ///
    /// Both branches are bounded above, and the non-accumulating one has to be:
    /// nothing validates the date a third-party app writes on a sample, the
    /// sleep query deliberately reaches to tomorrow's midnight so that a night
    /// ending this morning is read whole, and a record start-dated tonight is
    /// therefore returned, survives the plausibility cap and is keyed on
    /// tomorrow. Unbounded, it becomes *the* reading — a night that has not
    /// happened, reported in the present tense, hiding the real last night
    /// behind it. `streak` and `longMemory` both already refuse a negative age;
    /// this is the one place the same invariant was missing.
    public static func mostRecentComparableDay(
        in days: [DailyValue],
        metric: HealthMetric,
        now: Date,
        calendar: Calendar
    ) -> DailyValue? {
        let today = calendar.startOfDay(for: now)
        guard metric.accumulatesAcrossTheDay else { return days.last { $0.day <= today } }
        return days.last { $0.day < today }
    }
}
