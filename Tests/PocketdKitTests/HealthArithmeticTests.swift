import Foundation
import Testing
@testable import PocketdKit

/// The HealthKit call cannot be tested — it needs a device with a Health
/// database, a human to answer a permission sheet, and years of recorded days.
/// What CAN be tested is every number the summary computes from what comes back,
/// and that is nearly all of the feature: a baseline, a delta and a scan over a
/// series is what makes a health assistant feel intelligent. Arithmetic that is
/// quietly wrong is worse than no feature, because it is unfalsifiable by the
/// person reading it.
private enum Fixture {
    static let london = TimeZone(identifier: "Europe/London")!
    /// Chile moves to summer time at *midnight*, so 7 September 2025 has no
    /// 00:00 at all and `startOfDay` for it is 01:00.
    ///
    /// Every other daylight-saving test in this file uses London, which shifts
    /// at 01:00 and therefore always has a midnight — which is precisely why a
    /// day-stepping bug is invisible to all of them. Santiago, Havana, Beirut,
    /// São Paulo and Tehran all shift at midnight; roughly 35 million people
    /// live in one of them.
    static let santiago = TimeZone(identifier: "America/Santiago")!
    static let utc = TimeZone(identifier: "UTC")!
    static let posix = Locale(identifier: "en_US_POSIX")

    static func calendar(_ zone: TimeZone = utc) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return calendar
    }

    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0,
        zone: TimeZone = utc
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// `count` consecutive days ending the day before `endingBefore`, built with
    /// calendar arithmetic so the series survives a clock change.
    static func series(
        endingBefore day: Date,
        count: Int,
        calendar: Calendar,
        value: (Int) -> Double
    ) -> [DailyValue] {
        (1...count).reversed().map { back in
            DailyValue(day: calendar.date(byAdding: .day, value: -back, to: day)!, value: value(back))
        }
    }
}

@Suite("Health arithmetic: bucketing days")
struct HealthDailyBucketTests {

    @Test("steps within one day are added, because they are different steps")
    func sumsAccumulatingMetrics() {
        let calendar = Fixture.calendar()
        let day = Fixture.date(2025, 9, 10, 0, 0)
        let samples = [
            HealthSample(value: 3_000, unit: .count, date: Fixture.date(2025, 9, 10, 9, 0)),
            HealthSample(value: 4_500, unit: .count, date: Fixture.date(2025, 9, 10, 17, 30))
        ]

        let days = HealthArithmetic.daily(samples, metric: .steps, calendar: calendar)
        #expect(days == [DailyValue(day: day, value: 7_500)])
    }

    @Test("two resting heart rates in one day are averaged, not added")
    func averagesDiscreteMetrics() {
        // Adding them reports a pulse of 140, which is the kind of number that
        // makes a user think something is wrong with them rather than with us.
        let calendar = Fixture.calendar()
        let samples = [
            HealthSample(value: 68, unit: .beatsPerMinute, date: Fixture.date(2025, 9, 10, 3, 0)),
            HealthSample(value: 72, unit: .beatsPerMinute, date: Fixture.date(2025, 9, 10, 15, 0))
        ]

        let days = HealthArithmetic.daily(samples, metric: .resting_heart_rate, calendar: calendar)
        #expect(days.count == 1)
        #expect(days[0].value == 70)
    }

    @Test("a sample in the wrong unit is dropped rather than believed")
    func mismatchedUnitsAreDropped() throws {
        // HRV read with `HKUnit.second()` instead of `.secondUnit(with: .milli)`
        // is a one-character mistake that produces a number a thousand times too
        // small and no error at all. A baseline built from a mixture of the two
        // is wrong and confident; too few days is wrong and says so.
        //
        // The tag is derived the way the reader derives it rather than written
        // in by hand. Hand-writing `.second` here tested a shape the app could
        // not produce: `dailyBuckets` used to copy `metric.unit` onto every
        // sample, so both sides of the check came off one `switch` and the 0.042
        // would have arrived labelled `.millisecond` — dropping nothing, ever.
        let calendar = Fixture.calendar()
        let misread = try #require(
            HealthUnit.named(HealthUnit.second.hkUnitString, preferring: HealthMetric.heart_rate_variability.unit)
        )
        #expect(misread == .second)

        let samples = [
            HealthSample(value: 42, unit: .millisecond, date: Fixture.date(2025, 9, 10, 3, 0)),
            HealthSample(value: 0.042, unit: misread, date: Fixture.date(2025, 9, 11, 3, 0))
        ]

        let days = HealthArithmetic.daily(samples, metric: .heart_rate_variability, calendar: calendar)
        #expect(days.count == 1)
        #expect(days[0].value == 42)
    }

    @Test("a non-finite value never enters a bucket")
    func nonFiniteValuesAreDropped() {
        // `JSONSerialization` throws on an infinity, LocalLLMClient swallows the
        // throw, and the whole tool result silently degrades to interpolated
        // text. Nothing that cannot be serialised may get as far as a mean.
        let calendar = Fixture.calendar()
        let samples = [
            HealthSample(value: .infinity, unit: .count, date: Fixture.date(2025, 9, 10, 9, 0)),
            HealthSample(value: 1_000, unit: .count, date: Fixture.date(2025, 9, 10, 10, 0))
        ]
        let days = HealthArithmetic.daily(samples, metric: .steps, calendar: calendar)
        #expect(days == [DailyValue(day: Fixture.date(2025, 9, 10, 0, 0), value: 1_000)])
    }

    @Test("on a 23-hour day, two samples 24 hours apart are on different days")
    func springForwardSplitsADay() {
        // Europe/London moves to BST at 01:00 on Sunday 30 March 2025, so that
        // day is 23 hours long. Bucketing by dividing a time interval by 86,400
        // puts both of these on 30 March and reports a day that never happened.
        let calendar = Fixture.calendar(Fixture.london)
        let first = Fixture.date(2025, 3, 30, 0, 30, zone: Fixture.london)
        let second = first.addingTimeInterval(24 * 3600)

        let days = HealthArithmetic.daily(
            [
                HealthSample(value: 1, unit: .count, date: first),
                HealthSample(value: 1, unit: .count, date: second)
            ],
            metric: .steps,
            calendar: calendar
        )

        #expect(days.count == 2)
        #expect(days[0].day == Fixture.date(2025, 3, 30, 0, 0, zone: Fixture.london))
        #expect(days[1].day == Fixture.date(2025, 3, 31, 0, 0, zone: Fixture.london))
    }

    @Test("on a 25-hour day, two samples 24 hours apart are on the same day")
    func fallBackKeepsADayTogether() {
        // The clocks go back at 02:00 on Sunday 26 October 2025, so that day is
        // 25 hours long and 24 hours of walking is still one day's walking.
        let calendar = Fixture.calendar(Fixture.london)
        let first = Fixture.date(2025, 10, 26, 0, 30, zone: Fixture.london)
        let second = first.addingTimeInterval(24 * 3600)

        let days = HealthArithmetic.daily(
            [
                HealthSample(value: 4_000, unit: .count, date: first),
                HealthSample(value: 4_000, unit: .count, date: second)
            ],
            metric: .steps,
            calendar: calendar
        )

        #expect(days.count == 1)
        #expect(days[0].value == 8_000)
        #expect(days[0].day == Fixture.date(2025, 10, 26, 0, 0, zone: Fixture.london))
    }

    @Test("buckets come back oldest first, whatever order the store used")
    func bucketsAreSorted() {
        let calendar = Fixture.calendar()
        let days = HealthArithmetic.daily(
            [
                HealthSample(value: 3, unit: .count, date: Fixture.date(2025, 9, 12, 9, 0)),
                HealthSample(value: 1, unit: .count, date: Fixture.date(2025, 9, 10, 9, 0)),
                HealthSample(value: 2, unit: .count, date: Fixture.date(2025, 9, 11, 9, 0))
            ],
            metric: .steps,
            calendar: calendar
        )
        #expect(days.map(\.value) == [1, 2, 3])
    }
}

@Suite("Health arithmetic: sleep")
struct HealthSleepTests {

    @Test("a night is attributed to the morning it ended on")
    func nightBelongsToTheWakeDay() {
        // 23:30 Monday to 07:00 Tuesday is what a person calls "last night" when
        // they say it on Tuesday morning, and it is where the Health app puts it.
        let calendar = Fixture.calendar()
        let intervals = [
            SleepInterval(
                start: Fixture.date(2025, 9, 8, 23, 30),
                end: Fixture.date(2025, 9, 9, 7, 0),
                asleep: true
            )
        ]
        let nights = HealthArithmetic.nightlyTotals(intervals, calendar: calendar)
        #expect(nights.count == 1)
        #expect(nights[0].day == Fixture.date(2025, 9, 9, 0, 0))
        #expect(nights[0].value == 7.5 * 3600)
    }

    @Test("overlapping sources are unioned, not added")
    func overlappingIntervalsAreMerged() {
        // Health routinely holds two sources for one night — a watch writing
        // stages and an app writing time in bed. Summing them gives fourteen-hour
        // nights, which is the single most common way a sleep figure goes wrong.
        let calendar = Fixture.calendar()
        let intervals = [
            SleepInterval(start: Fixture.date(2025, 9, 8, 23, 0), end: Fixture.date(2025, 9, 9, 7, 0), asleep: true),
            SleepInterval(start: Fixture.date(2025, 9, 8, 23, 30), end: Fixture.date(2025, 9, 9, 2, 0), asleep: true),
            SleepInterval(start: Fixture.date(2025, 9, 9, 2, 0), end: Fixture.date(2025, 9, 9, 5, 30), asleep: true)
        ]
        let nights = HealthArithmetic.nightlyTotals(intervals, calendar: calendar)
        #expect(nights.count == 1)
        #expect(nights[0].value == 8 * 3600)
    }

    @Test("a short stage wholly inside a long one does not shorten it")
    func containedIntervalsDoNotTruncate() {
        let calendar = Fixture.calendar()
        let intervals = [
            SleepInterval(start: Fixture.date(2025, 9, 8, 23, 0), end: Fixture.date(2025, 9, 9, 7, 0), asleep: true),
            SleepInterval(start: Fixture.date(2025, 9, 9, 1, 0), end: Fixture.date(2025, 9, 9, 1, 20), asleep: true)
        ]
        #expect(HealthArithmetic.nightlyTotals(intervals, calendar: calendar)[0].value == 8 * 3600)
    }

    @Test("time in bed awake is not sleep")
    func awakeIsExcluded() {
        // Reporting in-bed time as sleep flatters the user by about an hour a
        // night, every night, and the error is invisible because it is plausible.
        let calendar = Fixture.calendar()
        let intervals = [
            SleepInterval(start: Fixture.date(2025, 9, 8, 22, 30), end: Fixture.date(2025, 9, 8, 23, 30), asleep: false),
            SleepInterval(start: Fixture.date(2025, 9, 8, 23, 30), end: Fixture.date(2025, 9, 9, 6, 30), asleep: true)
        ]
        let nights = HealthArithmetic.nightlyTotals(intervals, calendar: calendar)
        #expect(nights[0].value == 7 * 3600)
    }

    @Test("a zero-length interval contributes nothing and does not create a night")
    func degenerateIntervalsAreIgnored() {
        let calendar = Fixture.calendar()
        let point = Fixture.date(2025, 9, 9, 3, 0)
        let nights = HealthArithmetic.nightlyTotals(
            [SleepInterval(start: point, end: point, asleep: true)],
            calendar: calendar
        )
        #expect(nights.isEmpty)
    }

    @Test("a night that spans the autumn clock change is measured in real hours")
    func nightAcrossFallBack() {
        // 23:00 to 07:00 across 26 October 2025 in London is nine hours of actual
        // sleep, because the hour from 01:00 to 02:00 happens twice.
        let calendar = Fixture.calendar(Fixture.london)
        let intervals = [
            SleepInterval(
                start: Fixture.date(2025, 10, 25, 23, 0, zone: Fixture.london),
                end: Fixture.date(2025, 10, 26, 7, 0, zone: Fixture.london),
                asleep: true
            )
        ]
        let nights = HealthArithmetic.nightlyTotals(intervals, calendar: calendar)
        #expect(nights[0].value == 9 * 3600)
        #expect(nights[0].day == Fixture.date(2025, 10, 26, 0, 0, zone: Fixture.london))
    }

    @Test("one 72-hour asleep record does not collapse three nights into a 79-hour night")
    func implausibleRunsAreDiscardedRatherThanReported() {
        // HealthKit validates no sample's duration, and the merge that stops two
        // sources being added together will happily chain an ordinary night onto
        // a corrupt record. Reported, this reads "Sleep 79 h — 1,029% above your
        // 28-day average", with a superlative on top of it. Dropping the run
        // costs the nights it swallowed; keeping it costs the user's trust in
        // every other number on the screen.
        let calendar = Fixture.calendar()
        func night(_ day: Int) -> SleepInterval {
            SleepInterval(
                start: Fixture.date(2025, 9, day, 0, 0),
                end: Fixture.date(2025, 9, day, 7, 0),
                asleep: true
            )
        }
        let intervals = [night(5), night(6), night(7), night(8), night(9)] + [
            SleepInterval(start: Fixture.date(2025, 9, 6, 0, 0), end: Fixture.date(2025, 9, 9, 0, 0), asleep: true)
        ]

        let nights = HealthArithmetic.nightlyTotals(intervals, calendar: calendar)
        // The one night the bad record never touched survives untouched.
        #expect(nights == [DailyValue(day: Fixture.date(2025, 9, 5, 0, 0), value: 7 * 3600)])
        #expect(nights.allSatisfy { $0.value <= HealthArithmetic.maximumNightSeconds })
    }

    @Test("a long but possible night is still a night")
    func theCapDoesNotPoliceUnusualSleep() {
        // The cap exists to catch corruption, not to have an opinion about
        // someone ill in bed. Fourteen hours is a real night and is reported.
        let calendar = Fixture.calendar()
        let intervals = [
            SleepInterval(
                start: Fixture.date(2025, 9, 9, 20, 0),
                end: Fixture.date(2025, 9, 10, 10, 0),
                asleep: true
            )
        ]
        let fourteenHours: TimeInterval = 14 * 3600
        #expect(HealthArithmetic.nightlyTotals(intervals, calendar: calendar).first?.value == fourteenHours)
    }

    @Test("the cap falls exactly on a day, and a minute past it is gone")
    func theCapIsAWholeDay() {
        // Spelled out in seconds rather than read back from the constant. Phrased
        // as `total(seconds: maximumNightSeconds) == maximumNightSeconds` this
        // compared the source to itself and held for any cap at all: at 14.5 h
        // the app would silently discard the fourteen-hour night the test above
        // exists to protect, and at 48 h a two-night chain from one corrupt
        // record would be reported as a single 48-hour night with a superlative
        // on top — the exact failure the cap is for — with nothing going red.
        let calendar = Fixture.calendar()
        func total(seconds: TimeInterval) -> Double? {
            let start = Fixture.date(2025, 9, 8, 0, 0)
            let intervals = [SleepInterval(start: start, end: start.addingTimeInterval(seconds), asleep: true)]
            return HealthArithmetic.nightlyTotals(intervals, calendar: calendar).first?.value
        }
        // Typed, because an untyped `24 * 3_600` on the right of an optional
        // defaults to `Int` inside the expectation macro and the comparison then
        // fails on two numbers that are equal.
        let wholeDay: TimeInterval = 24 * 3_600
        #expect(HealthArithmetic.maximumNightSeconds == wholeDay)
        #expect(total(seconds: wholeDay) == wholeDay)
        #expect(total(seconds: wholeDay + 60) == nil)
    }
}

@Suite("Health arithmetic: baselines")
struct HealthBaselineTests {

    @Test("a baseline needs fourteen days and refuses to be built from three")
    func sparseHistoryHasNoBaseline() {
        // The whole honesty of the feature. With n = 3 the standard error on the
        // mean is 58% of a standard deviation — the baseline differs from the
        // reading being compared to it by less than its own noise, and every
        // percentage printed against it is theatre.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        let days = Fixture.series(endingBefore: today, count: 3, calendar: calendar) { _ in 8_000 }

        #expect(HealthArithmetic.baseline(of: days, endingBefore: today, calendar: calendar) == nil)
    }

    @Test("fourteen days is enough and thirteen is not")
    func minimumIsExact() {
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)

        let thirteen = Fixture.series(endingBefore: today, count: 13, calendar: calendar) { _ in 8_000 }
        let fourteen = Fixture.series(endingBefore: today, count: 14, calendar: calendar) { _ in 8_000 }

        #expect(HealthArithmetic.baseline(of: thirteen, endingBefore: today, calendar: calendar) == nil)
        #expect(HealthArithmetic.baseline(of: fourteen, endingBefore: today, calendar: calendar)?.dayCount == 14)
    }

    @Test("the day being judged is not in its own baseline")
    func theDayExcludesItself() {
        // A day included in its own baseline drags the baseline toward itself and
        // understates exactly the day the user asked about.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days = Fixture.series(endingBefore: today, count: 20, calendar: calendar) { _ in 100 }
        days.append(DailyValue(day: today, value: 10_000))

        let baseline = HealthArithmetic.baseline(of: days, endingBefore: today, calendar: calendar)
        #expect(baseline?.mean == 100)
        #expect(baseline?.dayCount == 20)
    }

    @Test("days older than the window are not in it either")
    func theWindowHasABack()  {
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        // 40 days of history: the 28-day window may only see the recent 28.
        let days = Fixture.series(endingBefore: today, count: 40, calendar: calendar) { back in
            back <= 28 ? 100 : 100_000
        }
        let baseline = HealthArithmetic.baseline(of: days, endingBefore: today, calendar: calendar)
        #expect(baseline?.dayCount == 28)
        #expect(baseline?.mean == 100)
    }

    @Test("the spread is a sample standard deviation, not a population one")
    func besselCorrection() {
        // Seven tens and seven twenties: the population formula gives exactly 5,
        // Bessel gives sqrt(350/13). Using the population formula understates the
        // spread, which biases every judgement toward calling an ordinary day
        // unusual — a bias nobody would ever notice from the output.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        let days = Fixture.series(endingBefore: today, count: 14, calendar: calendar) { back in
            back <= 7 ? 10 : 20
        }

        let baseline = HealthArithmetic.baseline(of: days, endingBefore: today, calendar: calendar)
        #expect(baseline?.mean == 15)
        #expect(abs((baseline?.standardDeviation ?? 0) - (350.0 / 13.0).squareRoot()) < 1e-9)
        #expect(abs((baseline?.standardDeviation ?? 0) - 5) > 0.1)
    }

    @Test("both halves of the degenerate floor bite, and neither is the other")
    func bothDegenerateFloorsAreLoadBearing() {
        // Every other degenerate fixture in this file uses `sd == 0` against a
        // non-zero mean, which satisfies `max(1e-9, abs(mean) * 0.001)` twice
        // over — so either half could be deleted with the suite green. These two
        // straddle it in opposite directions.
        //
        // A resting heart rate recorded to whole numbers is the real case: 60
        // bpm with a couple of 61s in twenty-eight days has a spread that is a
        // rounding artefact rather than a fact about the user, and dividing by
        // it puts today's 61 at twenty standard deviations and "well above your
        // usual range" on a one-beat change.
        let roundingArtefact = HealthBaseline(mean: 60, standardDeviation: 0.05, dayCount: 28, windowDays: 28)
        #expect(roundingArtefact.spreadIsDegenerate)   // relative floor bites; 0.05 > 1e-9

        let tinyAroundZero = HealthBaseline(mean: 0, standardDeviation: 1e-11, dayCount: 28, windowDays: 28)
        #expect(tinyAroundZero.spreadIsDegenerate)     // absolute floor bites; the relative one is 0

        // And a floor that is a floor rather than a blanket: just above it, the
        // spread is real and the z-score is allowed.
        let real = HealthBaseline(mean: 60, standardDeviation: 0.07, dayCount: 28, windowDays: 28)
        #expect(!real.spreadIsDegenerate)

        // The consequence, which is what anybody actually reads.
        let day = Fixture.date(2025, 9, 10, 0, 0)
        let onABeat = HealthArithmetic.compare(value: 61, on: day, metric: .resting_heart_rate, to: roundingArtefact)
        #expect(onABeat.zScore == nil)
        #expect(onABeat.band == .usual)
    }

    @Test("a window with no variation at all is degenerate rather than infinitely sensitive")
    func flatSeriesIsDegenerate() {
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        let days = Fixture.series(endingBefore: today, count: 20, calendar: calendar) { _ in 60 }
        let baseline = HealthArithmetic.baseline(of: days, endingBefore: today, calendar: calendar)!

        #expect(baseline.standardDeviation == 0)
        #expect(baseline.spreadIsDegenerate)
    }

    @Test("a baseline window built across a clock change still holds 28 days")
    func windowSurvivesDaylightSaving() {
        // Counted with `Calendar`, so the 23-hour day does not push the far end
        // of the window an hour into the day before it and drop a reading.
        let calendar = Fixture.calendar(Fixture.london)
        let today = Fixture.date(2025, 4, 7, 0, 0, zone: Fixture.london)
        let days = Fixture.series(endingBefore: today, count: 28, calendar: calendar) { _ in 8_000 }

        #expect(HealthArithmetic.baseline(of: days, endingBefore: today, calendar: calendar)?.dayCount == 28)
    }
}

@Suite("Health arithmetic: comparisons")
struct HealthComparisonTests {

    private static func baseline(mean: Double, sd: Double) -> HealthBaseline {
        HealthBaseline(mean: mean, standardDeviation: sd, dayCount: 28, windowDays: 28)
    }

    @Test("resting heart rate 71 against a usual 80 is 11% below")
    func percentDeltaIsSigned() {
        let comparison = HealthArithmetic.compare(
            value: 71, on: Fixture.date(2025, 9, 10, 0, 0), metric: .resting_heart_rate,
            to: Self.baseline(mean: 80, sd: 4)
        )
        #expect(abs((comparison.percentDelta ?? 0) - (-11.25)) < 1e-9)
        #expect(HealthFormat.percent(abs(comparison.percentDelta ?? 0), locale: Fixture.posix) == "11%")
    }

    @Test("bands break at exactly one and two standard deviations")
    func bandThresholds() {
        // About 68% of a roughly normal metric's days sit inside one standard
        // deviation and about 95% inside two, so "in your usual range" is true
        // two days in three and "well above" fires around once a fortnight. A
        // tighter band makes every Tuesday remarkable and the user stops reading.
        let base = Self.baseline(mean: 100, sd: 10)
        let day = Fixture.date(2025, 9, 10, 0, 0)

        func band(_ value: Double) -> BaselineBand {
            HealthArithmetic.compare(value: value, on: day, metric: .steps, to: base).band
        }

        #expect(band(109.99) == .usual)
        #expect(band(110) == .above)      // z == 1 exactly
        #expect(band(119.99) == .above)
        #expect(band(120) == .wellAbove)  // z == 2 exactly
        #expect(band(90) == .below)
        #expect(band(80) == .wellBelow)
        #expect(band(100) == .usual)
    }

    @Test("a degenerate spread bands on percentage instead of dividing by zero")
    func degenerateSpreadFallsBackToPercent() {
        // A user whose resting heart rate reads 60 every day has a standard
        // deviation of zero. A z-score against it is infinite or NaN, and
        // `JSONSerialization` throws on both — which LocalLLMClient swallows, so
        // the tool result silently degrades to interpolated text.
        let flat = Self.baseline(mean: 60, sd: 0)
        let day = Fixture.date(2025, 9, 10, 0, 0)

        let unchanged = HealthArithmetic.compare(value: 62, on: day, metric: .resting_heart_rate, to: flat)
        #expect(unchanged.zScore == nil)
        #expect(unchanged.band == .usual)

        let raised = HealthArithmetic.compare(value: 70, on: day, metric: .resting_heart_rate, to: flat)
        #expect(raised.band == .above)

        let far = HealthArithmetic.compare(value: 90, on: day, metric: .resting_heart_rate, to: flat)
        #expect(far.band == .wellAbove)
        #expect(far.zScore == nil)
    }

    @Test("a zero mean produces no percentage rather than an infinite one")
    func zeroMeanHasNoPercentage() {
        let comparison = HealthArithmetic.compare(
            value: 500, on: Fixture.date(2025, 9, 10, 0, 0), metric: .steps,
            to: Self.baseline(mean: 0, sd: 0)
        )
        #expect(comparison.percentDelta == nil)
        #expect(comparison.zScore == nil)
        #expect(comparison.band == .usual)
    }

    @Test("nothing non-finite ever leaves a comparison")
    func everythingIsFinite() {
        let day = Fixture.date(2025, 9, 10, 0, 0)

        // The grid, which is cheap and proves the ordinary cases stay ordinary —
        // but on its own it cannot fail. Every sd at or below 1e-12 is caught by
        // the degenerate check and returns `nil` before any division, and the
        // rest divide a finite numerator by 10, so the guard is never once
        // handed a non-finite argument and deleting it leaves this green.
        for mean in [0.0, 1e-12, 100.0] {
            for sd in [0.0, 1e-12, 10.0] {
                for value in [0.0, 100.0, 1e9] {
                    let comparison = HealthArithmetic.compare(
                        value: value, on: day, metric: .steps, to: Self.baseline(mean: mean, sd: sd)
                    )
                    #expect(comparison.zScore?.isFinite ?? true, "mean \(mean) sd \(sd) value \(value)")
                    #expect(comparison.percentDelta?.isFinite ?? true, "mean \(mean) sd \(sd) value \(value)")
                }
            }
        }

        // An infinite spread passes the degenerate check — `inf <= inf` — and
        // then divides infinity by infinity, which is NaN.
        let overflowed = HealthArithmetic.compare(
            value: 1e308, on: day, metric: .steps, to: Self.baseline(mean: .infinity, sd: .infinity)
        )
        #expect(overflowed.percentDelta == nil)
        #expect(overflowed.zScore == nil)

        // A NaN spread passes it the other way — `nan <= 0.1` is false — and
        // reaches the division as a live divisor.
        let unmeasurable = HealthArithmetic.compare(
            value: 120, on: day, metric: .steps, to: Self.baseline(mean: 100, sd: .nan)
        )
        #expect(unmeasurable.zScore == nil)

        // And a non-finite value against an ordinary baseline.
        let runaway = HealthArithmetic.compare(
            value: .infinity, on: day, metric: .steps, to: Self.baseline(mean: 100, sd: 10)
        )
        #expect(runaway.zScore == nil)
        #expect(runaway.percentDelta == nil)
    }

    @Test("a series that overflows to infinity produces no number rather than a NaN")
    func overflowNeverReachesThePayload() {
        // Reachable end to end: `daily` admits any finite sample, and finite
        // samples of about 1e308 sum to `+inf`. Mean, variance and spread are
        // then all infinite, the degenerate check passes, and the percentage is
        // `(1e308 - inf) / inf` — a NaN, which `JSONSerialization` throws on and
        // LocalLLMClient answers by interpolating the whole dictionary as text.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        let days = Fixture.series(endingBefore: today, count: 20, calendar: calendar) { _ in 1e308 }

        let baseline = HealthArithmetic.baseline(of: days, endingBefore: today, calendar: calendar)
        #expect(baseline?.mean.isFinite == false)

        let comparison = HealthArithmetic.compare(
            value: 1e308, on: today, metric: .steps, to: baseline!
        )
        #expect(comparison.zScore == nil)
        #expect(comparison.percentDelta == nil)
    }
}

@Suite("Health arithmetic: long memory")
struct HealthLongMemoryTests {

    @Test("the last time a day was this good is reported by date")
    func bestSince() {
        // The claim a ninety-day retention window physically cannot make. The
        // scan runs over whatever the phone holds, which is everything the user
        // has ever recorded.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days = Fixture.series(endingBefore: today, count: 200, calendar: calendar) { _ in 6 * 3600 }
        // One better night, 120 days ago.
        let landmark = calendar.date(byAdding: .day, value: -120, to: today)!
        days = days.map { $0.day == landmark ? DailyValue(day: $0.day, value: 9 * 3600) : $0 }
        days.append(DailyValue(day: today, value: 8.5 * 3600))

        guard case let .bestSince(day, gap)? = HealthArithmetic.superlative(
            in: days, direction: .higherIsBetter, calendar: calendar
        ) else {
            Issue.record("expected a bestSince")
            return
        }
        #expect(day == landmark)
        #expect(gap == 120)
    }

    @Test("a better day 29 days back is not news and one 30 days back is")
    func theSuperlativeGapIsExactlyAMonth() {
        // "Best since Tuesday" describes ordinary variation dressed up as a
        // finding. A month is the shortest gap at which "best since" tells the
        // user something they did not already know.
        //
        // Both sides of the boundary, because one side pins nothing: with the
        // better day ten days back — where this fixture used to sit — the
        // threshold could be anything from 11 to 99 and a better day 25 days ago,
        // squarely inside the month the title claims, would still be announced.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)

        func superlative(betterDayAt back: Int) -> HealthSuperlative? {
            var days = Fixture.series(endingBefore: today, count: 200, calendar: calendar) { day in
                day == back ? 20_000 : 6_000
            }
            days.append(DailyValue(day: today, value: 12_000))
            return HealthArithmetic.superlative(in: days, direction: .higherIsBetter, calendar: calendar)
        }

        #expect(superlative(betterDayAt: 29) == nil)
        #expect(
            superlative(betterDayAt: 30)
                == .bestSince(day: calendar.date(byAdding: .day, value: -30, to: today)!, gapDays: 30)
        )
    }

    @Test("an all-time high is claimed only as far back as the data reaches")
    func bestInReachIsHonestAboutItsReach() {
        // "Your best ever" from a series that starts in May is a flattering lie.
        // The reported claim is bounded by what the phone can actually see.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days = Fixture.series(endingBefore: today, count: 100, calendar: calendar) { _ in 6_000 }
        days.append(DailyValue(day: today, value: 20_000))

        #expect(
            HealthArithmetic.superlative(in: days, direction: .higherIsBetter, calendar: calendar)
                == .bestInReach(spanDays: 100, dayCount: 101)
        )
    }

    @Test("a superlative counts the days it has as well as the span they straddle")
    func bestInReachSeparatesReachFromDensity() {
        // A tracker worn for a week in July and again this week. The span is how
        // far the claim reaches and says nothing at all about how much is behind
        // it, so a sentence that quotes the span as a count of days of data —
        // "in the 39 days of step data on this iPhone", over two readings —
        // asserts a history the phone does not hold.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        let days = [
            DailyValue(day: calendar.date(byAdding: .day, value: -40, to: today)!, value: 3_000),
            DailyValue(day: calendar.date(byAdding: .day, value: -1, to: today)!, value: 9_000)
        ]

        #expect(
            HealthArithmetic.superlative(in: days, direction: .higherIsBetter, calendar: calendar)
                == .bestInReach(spanDays: 39, dayCount: 2)
        )
    }

    @Test("a series shorter than a month claims nothing at all")
    func shortSeriesClaimsNothing() {
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days = Fixture.series(endingBefore: today, count: 5, calendar: calendar) { _ in 6_000 }
        days.append(DailyValue(day: today, value: 20_000))

        #expect(HealthArithmetic.superlative(in: days, direction: .higherIsBetter, calendar: calendar) == nil)
    }

    @Test("for resting heart rate, best means lowest")
    func lowerIsBetterInvertsTheScan() {
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days = Fixture.series(endingBefore: today, count: 120, calendar: calendar) { _ in 70 }
        days.append(DailyValue(day: today, value: 58))

        #expect(
            HealthArithmetic.superlative(in: days, direction: .lowerIsBetter, calendar: calendar)
                == .bestInReach(spanDays: 120, dayCount: 121)
        )
        // The same series read the other way round is not a high at all.
        #expect(HealthArithmetic.superlative(in: days, direction: .higherIsBetter, calendar: calendar) == nil)
    }

    @Test("the gap is counted in calendar days, so a clock change does not shorten it")
    func gapIsCalendarArithmetic() {
        // 30 March to 26 October 2025 in London contains both clock changes.
        // Dividing the interval by 86,400 loses an hour and rounds a 30-day gap
        // to 29 — the difference between saying something and staying quiet.
        let calendar = Fixture.calendar(Fixture.london)
        let from = Fixture.date(2025, 3, 30, 0, 0, zone: Fixture.london)
        let to = calendar.date(byAdding: .day, value: 30, to: from)!

        #expect(HealthArithmetic.dayGap(from: from, to: to, calendar: calendar) == 30)
        #expect(Int(to.timeIntervalSince(from) / 86_400) == 29)
    }

    @Test("a day whose midnight never happened is still one day before the next one")
    func gapSurvivesAZoneThatShiftsAtMidnight() {
        // Santiago goes to summer time at midnight on 7 September 2025, so the
        // start of that day is 01:00 and only 23 hours separate it from the start
        // of the 8th. `dateComponents([.day],)` counts whole days from the time
        // of day it begins at, and no whole day fits between 01:00 and the next
        // 00:00 — so the gap came back one short for every span beginning on
        // such a day. One short is the difference between a reading described as
        // current and one carrying "that reading is 2 days old"; it is also a
        // silently shortened `bestInReach` reach.
        let calendar = Fixture.calendar(Fixture.santiago)
        func startOfDay(_ month: Int, _ day: Int) -> Date {
            calendar.startOfDay(for: Fixture.date(2025, month, day, 12, 0, zone: Fixture.santiago))
        }

        // The premise, stated rather than assumed: 00:00 does not exist that day.
        #expect(startOfDay(9, 7) == Fixture.date(2025, 9, 7, 1, 0, zone: Fixture.santiago))
        let twentyThreeHours: TimeInterval = 23 * 3_600
        #expect(startOfDay(9, 8).timeIntervalSince(startOfDay(9, 7)) == twentyThreeHours)

        #expect(HealthArithmetic.dayGap(from: startOfDay(9, 7), to: startOfDay(9, 8), calendar: calendar) == 1)
        #expect(HealthArithmetic.dayGap(from: startOfDay(9, 7), to: startOfDay(9, 9), calendar: calendar) == 2)
        #expect(
            HealthArithmetic.dayGap(
                from: startOfDay(9, 7),
                to: Fixture.date(2025, 9, 9, 10, 0, zone: Fixture.santiago),
                calendar: calendar
            ) == 2
        )
        // Backwards too, and to itself.
        #expect(HealthArithmetic.dayGap(from: startOfDay(9, 9), to: startOfDay(9, 7), calendar: calendar) == -2)
        #expect(HealthArithmetic.dayGap(from: startOfDay(9, 7), to: startOfDay(9, 7), calendar: calendar) == 0)
    }

    @Test("the day before a day is that day's start, not that day's clock time")
    func steppingADayReNormalises() {
        // The primitive the streak walk and the baseline window both stand on.
        // `date(byAdding: .day,)` keeps the time of day it was handed, so one
        // step back from Santiago's 01:00 start lands on 01:00 of an ordinary
        // day — an hour past that day's start and no longer equal to any bucket
        // key, with the hour carried into every step after it.
        let calendar = Fixture.calendar(Fixture.santiago)
        func startOfDay(_ month: Int, _ day: Int) -> Date {
            calendar.startOfDay(for: Fixture.date(2025, month, day, 12, 0, zone: Fixture.santiago))
        }

        #expect(HealthArithmetic.startOfDay(startOfDay(9, 7), offsetBy: -1, calendar: calendar) == startOfDay(9, 6))
        #expect(HealthArithmetic.startOfDay(startOfDay(9, 6), offsetBy: 1, calendar: calendar) == startOfDay(9, 7))
        #expect(HealthArithmetic.startOfDay(startOfDay(9, 9), offsetBy: -8, calendar: calendar) == startOfDay(9, 1))
        // The bare subtraction this replaced, so the difference is on the record.
        #expect(calendar.date(byAdding: .day, value: -1, to: startOfDay(9, 7)) != startOfDay(9, 6))
    }
}

@Suite("Health arithmetic: streaks")
struct HealthStreakTests {

    @Test("five nights over eight hours in a row")
    func countsConsecutiveDays() {
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days = Fixture.series(endingBefore: today, count: 20, calendar: calendar) { back in
            back <= 4 ? 8.5 * 3600 : 6 * 3600
        }
        days.append(DailyValue(day: today, value: 9 * 3600))

        let streak = HealthArithmetic.streak(in: days, asOf: today, calendar: calendar, where: { $0 >= 8 * 3600 })
        #expect(streak?.length == 5)
        #expect(streak?.endingOn == today)
    }

    @Test("a missing day breaks the streak rather than being skipped over")
    func gapsBreakTheStreak() {
        // Health is full of gaps — a watch left on the charger, a phone in a
        // coat. Treating a gap as a pass turns "five nights over eight hours"
        // into a claim about two nights and three absences.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days: [DailyValue] = []
        for back in [6, 5, 4, 2, 1] {
            days.append(DailyValue(day: calendar.date(byAdding: .day, value: -back, to: today)!, value: 9 * 3600))
        }
        days.append(DailyValue(day: today, value: 9 * 3600))

        // Days 3 back is absent, so the run ending today is 1, 2 and today.
        #expect(HealthArithmetic.streak(in: days, asOf: today, calendar: calendar, where: { $0 >= 8 * 3600 })?.length == 3)
    }

    @Test("a streak has to include the most recent day or there is no streak now")
    func streakMustBeCurrent() {
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days = Fixture.series(endingBefore: today, count: 10, calendar: calendar) { _ in 9 * 3600 }
        days.append(DailyValue(day: today, value: 4 * 3600))

        #expect(HealthArithmetic.streak(in: days, asOf: today, calendar: calendar, where: { $0 >= 8 * 3600 }) == nil)
    }

    @Test("a streak counted across a clock change does not lose a day")
    func streakSurvivesDaylightSaving() {
        let calendar = Fixture.calendar(Fixture.london)
        let today = Fixture.date(2025, 3, 31, 0, 0, zone: Fixture.london)
        var days = Fixture.series(endingBefore: today, count: 6, calendar: calendar) { _ in 11_000 }
        days.append(DailyValue(day: today, value: 11_000))

        #expect(HealthArithmetic.streak(in: days, asOf: today, calendar: calendar, where: { $0 >= 10_000 })?.length == 7)
    }

    @Test("a streak counted through a midnight that never happened keeps every day")
    func streakSurvivesAZoneThatShiftsAtMidnight() {
        // The London test above cannot reach this: London shifts at 01:00 and so
        // always has a midnight, which makes the bare subtraction look correct
        // in every daylight-saving test this repo had. Santiago shifts *at*
        // midnight, the start of 7 September is 01:00, and a chain of
        // subtractions picks that hour up and never matches a bucket key again —
        // so a nine-day run was reported as three, and any genuine run is
        // truncated at the clock change for every user in the zone.
        let calendar = Fixture.calendar(Fixture.santiago)
        let now = Fixture.date(2025, 9, 10, 10, 0, zone: Fixture.santiago)
        // Keyed with `startOfDay`, which is exactly how `daily` and
        // `nightlyTotals` key a bucket.
        let days = (1...9).map { day in
            DailyValue(
                day: calendar.startOfDay(for: Fixture.date(2025, 9, day, 12, 0, zone: Fixture.santiago)),
                value: 12_000
            )
        }

        let streak = HealthArithmetic.streak(in: days, asOf: now, calendar: calendar, where: { $0 >= 10_000 })
        #expect(streak?.length == 9)
        #expect(streak?.endingOn == days.last?.day)
    }

    @Test("the same five nights are a streak in June and are not a streak in September")
    func aStreakIsOnlyEverAClaimAboutNow() {
        // The lie this exists to stop, stated as plainly as it can be: a user who
        // stopped wearing their watch in June, told in September, in the present
        // tense and with no date attached, that they are on a five-night streak.
        // Anchoring on `days.last` alone cannot tell these two calls apart.
        let calendar = Fixture.calendar()
        let lastNight = Fixture.date(2025, 6, 12, 0, 0)
        let days = Fixture.series(endingBefore: lastNight, count: 4, calendar: calendar) { _ in 9 * 3600 }
            + [DailyValue(day: lastNight, value: 9 * 3600)]

        let asItHappened = HealthArithmetic.streak(
            in: days, asOf: Fixture.date(2025, 6, 12, 10, 0), calendar: calendar, where: { $0 >= 8 * 3600 }
        )
        #expect(asItHappened?.length == 5)
        #expect(asItHappened?.endingOn == lastNight)

        let threeMonthsLater = HealthArithmetic.streak(
            in: days, asOf: Fixture.date(2025, 9, 11, 10, 0), calendar: calendar, where: { $0 >= 8 * 3600 }
        )
        #expect(threeMonthsLater == nil)
    }

    @Test("yesterday still counts and the day before it does not")
    func recencyToleranceIsExactlyOneDay() {
        // One day of slack rather than none, because an accumulating metric is
        // read from the last day that is over: the freshest step count any
        // summary can hold is already yesterday's. Two days means the phone has
        // no record of yesterday at all, and a run ending before that is a claim
        // about days nobody measured.
        let calendar = Fixture.calendar()
        let now = Fixture.date(2025, 9, 11, 10, 0)
        func streak(endingDaysBack: Int) -> HealthStreak? {
            let end = calendar.date(byAdding: .day, value: -endingDaysBack, to: calendar.startOfDay(for: now))!
            let days = Fixture.series(endingBefore: end, count: 4, calendar: calendar) { _ in 11_000 }
                + [DailyValue(day: end, value: 11_000)]
            return HealthArithmetic.streak(in: days, asOf: now, calendar: calendar, where: { $0 >= 10_000 })
        }

        #expect(streak(endingDaysBack: 0)?.length == 5)
        #expect(streak(endingDaysBack: 1)?.length == 5)
        #expect(streak(endingDaysBack: 2) == nil)
    }

    @Test("a run ending in the future is not a streak either")
    func futureDatedDaysAreRefused() {
        // Nothing validates the date a third-party app writes on a sample. A
        // streak that ends tomorrow is the same wrong claim pointing the other
        // way, and it would otherwise pass a check that only looks for staleness.
        let calendar = Fixture.calendar()
        let now = Fixture.date(2025, 9, 11, 10, 0)
        let end = Fixture.date(2025, 9, 13, 0, 0)
        let days = Fixture.series(endingBefore: end, count: 4, calendar: calendar) { _ in 11_000 }
            + [DailyValue(day: end, value: 11_000)]

        #expect(HealthArithmetic.streak(in: days, asOf: now, calendar: calendar, where: { $0 >= 10_000 }) == nil)
    }

    @Test("recency is counted in calendar days, so a 25-hour day does not age a streak out of existence")
    func recencySurvivesTheClockGoingBack() {
        // 26 October 2025 in London is 25 hours long, so a run that ended
        // yesterday morning can be more than 48 hours behind `now` in real
        // seconds. `Int(interval / 86_400)` calls that two days and throws away a
        // streak that is running right now; the calendar calls it one.
        let calendar = Fixture.calendar(Fixture.london)
        let end = Fixture.date(2025, 10, 26, 0, 0, zone: Fixture.london)
        let now = Fixture.date(2025, 10, 27, 23, 30, zone: Fixture.london)
        #expect(now.timeIntervalSince(end) > 48 * 3600)

        let days = Fixture.series(endingBefore: end, count: 4, calendar: calendar) { _ in 11_000 }
            + [DailyValue(day: end, value: 11_000)]
        #expect(HealthArithmetic.streak(in: days, asOf: now, calendar: calendar, where: { $0 >= 10_000 })?.length == 5)
    }
}

@Suite("Health arithmetic: the unit a number was actually read in")
struct HealthUnitTagTests {

    @Test("two units of different size never share a spelling")
    func magnitudesStayDistinguishable() {
        // Every tag is worked out from this string, so a collision between units
        // of different size is a silent thousand-fold rescaling waiting to
        // happen. Beats and breaths per minute are the one collision allowed:
        // one magnitude, two names, and neither can be mistaken for the other's
        // number because there is only one number.
        var bySpelling: [String: Set<HealthUnit>] = [:]
        for unit in HealthUnit.allCases {
            bySpelling[unit.hkUnitString, default: []].insert(unit)
        }
        for (spelling, units) in bySpelling where units.count > 1 {
            #expect(units == [.beatsPerMinute, .breathsPerMinute], "\(spelling) is shared by \(units)")
        }
    }

    @Test("every metric's own unit survives the round trip the reader does")
    func everyMetricRoundTrips() {
        // `dailyBuckets` tags each sample `HealthUnit.named(hkUnit.unitString,
        // preferring: metric.unit)`. If that disagreed with `metric.unit` for a
        // correctly configured read, `daily` would drop every sample of that
        // metric and a working phone would be reported as having no data — the
        // guard failing closed on the one path it must not.
        for metric in HealthMetric.allCases {
            #expect(HealthUnit.named(metric.unit.hkUnitString, preferring: metric.unit) == metric.unit, "\(metric)")
        }
    }

    @Test("a value read in seconds is labelled seconds, however firmly the caller expected milliseconds")
    func theTagComesFromTheReadingRatherThanFromTheMetric() {
        // `HKQuantity.doubleValue(for:)` answers in any compatible unit without
        // complaint, so this is the whole of the defence: the preference may
        // choose a name for a magnitude HealthKit has already fixed, and may
        // never choose the magnitude.
        #expect(HealthUnit.named("s", preferring: .millisecond) == .second)
        #expect(HealthUnit.named("ms", preferring: .millisecond) == .millisecond)
        #expect(HealthUnit.named("count", preferring: .beatsPerMinute) == .count)
        // The tie it is allowed to break, both ways round.
        #expect(HealthUnit.named("count/min", preferring: .beatsPerMinute) == .beatsPerMinute)
        #expect(HealthUnit.named("count/min", preferring: .breathsPerMinute) == .breathsPerMinute)
        // A unit this app has no name for is not guessed at.
        #expect(HealthUnit.named("furlong", preferring: .count) == nil)
    }
}

@Suite("Health arithmetic: incomplete days")
struct HealthPartialDayTests {

    @Test("today's steps are not compared against whole days")
    func accumulatingMetricsWaitForTheDayToEnd() {
        // Steps at ten in the morning are a fraction of a day measured against a
        // mean of whole ones. Without this the tool reports the user well below
        // their usual range every single morning, and is right about nothing.
        let calendar = Fixture.calendar()
        let now = Fixture.date(2025, 9, 11, 10, 0)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let days = [
            DailyValue(day: yesterday, value: 9_000),
            DailyValue(day: today, value: 900)
        ]

        let latest = HealthArithmetic.mostRecentComparableDay(in: days, metric: .steps, now: now, calendar: calendar)
        #expect(latest?.day == yesterday)
        #expect(latest?.value == 9_000)
    }

    @Test("last night's sleep is comparable the moment it is recorded")
    func measuredMetricsUseTheLatestDay() {
        // A night is attributed to the morning it ended, so by the time anyone
        // asks, the figure is finished. Making sleep wait a day would answer
        // "how did I sleep" with the night before last.
        let calendar = Fixture.calendar()
        let now = Fixture.date(2025, 9, 11, 10, 0)
        let today = calendar.startOfDay(for: now)
        let days = [
            DailyValue(day: calendar.date(byAdding: .day, value: -1, to: today)!, value: 6 * 3600),
            DailyValue(day: today, value: 8 * 3600)
        ]

        #expect(HealthArithmetic.mostRecentComparableDay(in: days, metric: .sleep, now: now, calendar: calendar)?.day == today)
    }

    @Test("a night dated tomorrow is not the reading for today")
    func futureDatedDaysAreNotComparable() {
        // Nothing validates the date a third-party app writes on a sample, the
        // sleep window deliberately reaches tomorrow's midnight so a night
        // ending this morning is read whole, and thirteen hours is under the
        // plausibility cap — so a record start-dated tonight comes back, keys on
        // tomorrow, and unbounded becomes *the* reading: a night that has not
        // happened, in the present tense, with this morning's real one nowhere.
        // `streak` and `longMemory` already refuse a negative age; this was the
        // one place the same invariant was missing.
        let calendar = Fixture.calendar()
        let now = Fixture.date(2025, 9, 11, 10, 0)
        let today = calendar.startOfDay(for: now)
        let days = [
            DailyValue(day: calendar.date(byAdding: .day, value: -1, to: today)!, value: 7 * 3600),
            DailyValue(day: today, value: 8 * 3600),
            DailyValue(day: calendar.date(byAdding: .day, value: 1, to: today)!, value: 13 * 3600)
        ]

        let eightHours: TimeInterval = 8 * 3600
        let latest = HealthArithmetic.mostRecentComparableDay(in: days, metric: .sleep, now: now, calendar: calendar)
        #expect(latest?.day == today)
        #expect(latest?.value == eightHours)

        // An accumulating metric never reached this, because its bound was
        // already there — asserted so the two branches cannot drift apart.
        let steps = HealthArithmetic.mostRecentComparableDay(in: days, metric: .steps, now: now, calendar: calendar)
        #expect(steps?.day == calendar.date(byAdding: .day, value: -1, to: today))
    }

    @Test("with only today's steps there is no comparable day at all")
    func noCompletedDayIsHonestlyNothing() {
        let calendar = Fixture.calendar()
        let now = Fixture.date(2025, 9, 11, 10, 0)
        let days = [DailyValue(day: calendar.startOfDay(for: now), value: 900)]

        #expect(HealthArithmetic.mostRecentComparableDay(in: days, metric: .steps, now: now, calendar: calendar) == nil)
    }
}

/// What every metric added after the first eight has to answer, and why each
/// answer is the one that matters.
///
/// A metric is data rather than logic in this package — the baseline, the
/// z-score, the delta and the record scan are all generic over it — which is
/// exactly why this file is where a new one can go wrong. Nothing in the
/// arithmetic can tell that a heart rate was summed instead of averaged, or that
/// a weight was given a better end; both produce a well-formed number and a
/// confident sentence.
private struct MetricSpec: Sendable {
    let metric: HealthMetric
    let unit: HealthUnit
    let aggregation: HealthAggregation
    let direction: HealthDirection
    let accumulates: Bool
}

/// The seven, written out a second time on purpose.
///
/// Every one of these is a fact about HealthKit or about the world that no code
/// in this package can derive, so the only defence is two copies that have to be
/// edited together. A table that merely restated the switch would be worthless;
/// the value here is that the tests below use it to drive real arithmetic.
private let addedMetrics: [MetricSpec] = [
    MetricSpec(metric: .distance, unit: .kilometer, aggregation: .sum, direction: .higherIsBetter, accumulates: true),
    MetricSpec(metric: .stand_hours, unit: .count, aggregation: .sum, direction: .higherIsBetter, accumulates: true),
    MetricSpec(metric: .heart_rate, unit: .beatsPerMinute, aggregation: .mean, direction: .neither, accumulates: false),
    MetricSpec(metric: .blood_oxygen, unit: .fractionOfOne, aggregation: .mean, direction: .higherIsBetter, accumulates: false),
    MetricSpec(metric: .mindful_minutes, unit: .second, aggregation: .sum, direction: .higherIsBetter, accumulates: true),
    MetricSpec(metric: .body_mass, unit: .kilogram, aggregation: .mean, direction: .neither, accumulates: false),
    MetricSpec(metric: .vo2_max, unit: .millilitersPerKilogramMinute, aggregation: .mean, direction: .higherIsBetter, accumulates: false)
]

@Suite("Health arithmetic: the metrics added after the first eight")
struct HealthAddedMetricTests {

    @Test("each one answers with the unit, aggregation, direction and accumulation it is documented to")
    func theVocabularyIsWhatItClaims() {
        for spec in addedMetrics {
            #expect(spec.metric.unit == spec.unit, "\(spec.metric) unit")
            #expect(spec.metric.aggregation == spec.aggregation, "\(spec.metric) aggregation")
            #expect(spec.metric.direction == spec.direction, "\(spec.metric) direction")
            #expect(spec.metric.accumulatesAcrossTheDay == spec.accumulates, "\(spec.metric) accumulation")
            // And the unit survives the round trip the reader does, so a
            // correctly configured read cannot be dropped as a mismatch.
            #expect(HealthUnit.named(spec.unit.hkUnitString, preferring: spec.unit) == spec.unit, "\(spec.metric) tag")
        }
    }

    @Test("a day of point measurements is averaged rather than added up")
    func pointMeasurementsAreNeverSummed() {
        // Summed, a day of heart rate samples is a number in the thousands, and
        // nothing downstream can tell that from a pulse: the payload hands the
        // model finished clauses, so whatever comes out of here is repeated as a
        // fact about somebody's body.
        let calendar = Fixture.calendar()
        let day = Fixture.date(2025, 9, 10, 0, 0)
        let readings: [(metric: HealthMetric, unit: HealthUnit, values: [Double], mean: Double)] = [
            (.heart_rate, .beatsPerMinute, [54, 150, 66], 90),
            (.blood_oxygen, .fractionOfOne, [0.96, 0.98], 0.97),
            (.body_mass, .kilogram, [72, 73], 72.5),
            (.vo2_max, .millilitersPerKilogramMinute, [41, 43], 42)
        ]

        for reading in readings {
            let samples = reading.values.enumerated().map { index, value in
                HealthSample(value: value, unit: reading.unit, date: Fixture.date(2025, 9, 10, 6 + index * 4, 0))
            }
            let days = HealthArithmetic.daily(samples, metric: reading.metric, calendar: calendar)

            #expect(days.count == 1, "\(reading.metric)")
            #expect(days.first?.day == day, "\(reading.metric)")
            #expect(abs((days.first?.value ?? .nan) - reading.mean) < 1e-9, "\(reading.metric) came back \(String(describing: days.first?.value))")
            // The number this is standing in front of, named rather than
            // implied: three readings of a pulse add to 270.
            #expect(days.first?.value != reading.values.reduce(0, +), "\(reading.metric)")
        }
    }

    @Test("at nine in the morning a running total is read from the last day that is over")
    func runningTotalsWaitForTheDayToEnd() {
        // The bug an earlier review caught, once per metric that can have it. A
        // day still being added to, measured against a mean of whole ones,
        // reports the user far below their usual range every single morning —
        // and it is invisible in a fixture that only ever holds finished days.
        let calendar = Fixture.calendar()
        let now = Fixture.date(2025, 9, 11, 9, 0)
        let today = calendar.startOfDay(for: now)
        let yesterday = HealthArithmetic.startOfDay(today, offsetBy: -1, calendar: calendar)
        let days = [DailyValue(day: yesterday, value: 10), DailyValue(day: today, value: 2)]

        for spec in addedMetrics where spec.accumulates {
            let latest = HealthArithmetic.mostRecentComparableDay(
                in: days, metric: spec.metric, now: now, calendar: calendar
            )
            #expect(latest?.day == yesterday, "\(spec.metric)")
            #expect(latest?.value == 10, "\(spec.metric)")
        }

        // And the other way for the ones that are single readings: a weight
        // written this morning is finished the moment it is written, and holding
        // it back a day would answer "what do I weigh" with Tuesday.
        for spec in addedMetrics where !spec.accumulates {
            let latest = HealthArithmetic.mostRecentComparableDay(
                in: days, metric: spec.metric, now: now, calendar: calendar
            )
            #expect(latest?.day == today, "\(spec.metric)")
        }
    }

    @Test("a running total on a day whose midnight never happened is still read from the day before")
    func runningTotalsSurviveAMidnightThatNeverHappened() {
        // Santiago goes to summer time at midnight on 7 September 2025, so that
        // day begins at 01:00. Every comparison below is between a bucket key
        // and a day boundary, and a day-step that kept its clock time would land
        // an hour inside the wrong day and hand back this morning's unfinished
        // distance as though the day were over.
        let calendar = Fixture.calendar(Fixture.santiago)
        let now = Fixture.date(2025, 9, 7, 9, 0, zone: Fixture.santiago)
        let today = calendar.startOfDay(for: now)
        let yesterday = HealthArithmetic.startOfDay(today, offsetBy: -1, calendar: calendar)

        // The premise, stated rather than assumed.
        #expect(today == Fixture.date(2025, 9, 7, 1, 0, zone: Fixture.santiago))
        #expect(calendar.startOfDay(for: yesterday) == yesterday)

        let days = [DailyValue(day: yesterday, value: 8.2), DailyValue(day: today, value: 1.1)]
        let latest = HealthArithmetic.mostRecentComparableDay(
            in: days, metric: .distance, now: now, calendar: calendar
        )
        #expect(latest?.day == yesterday)
        #expect(latest?.value == 8.2)
    }

    @Test("a metric with no better end is never given a record, whichever way the day went")
    func metricsWithNoDirectionClaimNoSuperlative() {
        // `direction` feeds nothing but the superlative, so this is the whole of
        // what a wrong value there would buy: "lowest weight since May", a
        // health judgement about a number that has no better end, in a sentence
        // the user cannot check. Both extremes are tried, because a wrong
        // direction is only visible from one side.
        let calendar = Fixture.calendar()
        let end = Fixture.date(2025, 9, 11, 0, 0)

        func series(endingAt last: Double) -> [DailyValue] {
            var days = Fixture.series(endingBefore: end, count: 200, calendar: calendar) { _ in 75 }
            days[days.count - 1] = DailyValue(day: days[days.count - 1].day, value: last)
            return days
        }
        let highest = series(endingAt: 90)
        let lowest = series(endingAt: 60)

        for metric in [HealthMetric.body_mass, .heart_rate] {
            #expect(metric.direction == .neither, "\(metric)")
            #expect(HealthArithmetic.superlative(in: highest, direction: metric.direction, calendar: calendar) == nil, "\(metric) at its highest")
            #expect(HealthArithmetic.superlative(in: lowest, direction: metric.direction, calendar: calendar) == nil, "\(metric) at its lowest")
        }

        // Both series do fire for a direction that has an opinion, so the two
        // silences above are the direction and not the fixture.
        #expect(HealthArithmetic.superlative(in: highest, direction: .higherIsBetter, calendar: calendar) != nil)
        #expect(HealthArithmetic.superlative(in: lowest, direction: .lowerIsBetter, calendar: calendar) != nil)
    }

    @Test("a day of stand hours is a count of markers rather than a length of time")
    func standHoursAreCounted() {
        // The watch writes one marker an hour and the ring shows how many of
        // them say the user stood, so a day's figure is a count of markers.
        // `appleStandTime`, the quantity type beside it, measures minutes spent
        // on your feet — a real number about a different thing, and the label
        // "Stand hours" over a sum of it would be wrong by construction.
        let calendar = Fixture.calendar()
        let samples = (7..<19).map { hour in
            HealthSample(value: 1, unit: .count, date: Fixture.date(2025, 9, 10, hour, 30))
        }

        let days = HealthArithmetic.daily(samples, metric: .stand_hours, calendar: calendar)
        #expect(days == [DailyValue(day: Fixture.date(2025, 9, 10, 0, 0), value: 12)])
        #expect(HealthFormat.value(12, metric: .stand_hours, locale: Fixture.posix) == "12")
    }

    @Test("mindful sessions are added in seconds and printed the way sleep is")
    func mindfulSessionsAreDurations() {
        // A mindful session has no quantity at all: its value is not applicable
        // and the measurement is the distance between its two dates. Seconds are
        // what `timeIntervalSince` means, which is the one unit here that cannot
        // be got wrong, and from there it is an ordinary summed metric rather
        // than a second interval mechanism beside sleep's.
        let calendar = Fixture.calendar()
        let samples = [
            HealthSample(value: 600, unit: .second, date: Fixture.date(2025, 9, 10, 7, 0)),
            HealthSample(value: 900, unit: .second, date: Fixture.date(2025, 9, 10, 21, 30))
        ]

        let days = HealthArithmetic.daily(samples, metric: .mindful_minutes, calendar: calendar)
        #expect(days == [DailyValue(day: Fixture.date(2025, 9, 10, 0, 0), value: 1_500)])
        #expect(HealthFormat.value(1_500, metric: .mindful_minutes, locale: Fixture.posix) == "25 m")
        #expect(HealthFormat.value(4_500, metric: .mindful_minutes, locale: Fixture.posix) == "1 h 15 m")
    }

    @Test("blood oxygen stays the fraction HealthKit stores and becomes a percentage once")
    func bloodOxygenIsAFractionUntilItIsPrinted() {
        // `HKUnit.percent()` measures a value between 0 and 1, so a saturation
        // of 98% arrives as 0.98. Multiplying at the seam would rescale the
        // number and relabel it in the same motion, which is the one failure the
        // unit tag exists to catch and the only one it cannot; multiplying where
        // the sign is printed cannot go wrong quietly.
        #expect(HealthUnit.fractionOfOne.hkUnitString == "%")
        #expect(HealthFormat.value(0.968, metric: .blood_oxygen, locale: Fixture.posix) == "96.8%")
        // The baseline mean goes through the same formatter as the reading, so
        // the two can never end up in different magnitudes.
        #expect(HealthFormat.value(0.97, metric: .blood_oxygen, locale: Fixture.posix) == "97.0%")
    }

    @Test("VO2 max carries two spellings of one unit, and they are held apart")
    func vo2MaxSpellingsAreNotInterchangeable() {
        // Checked against the framework rather than remembered: HealthKit
        // normalises this compound unit to `mL/min·kg` whichever order its parts
        // are assembled in, while everybody else writes the mass first. A guess
        // here is not a wrong number — `daily` drops every sample whose tag does
        // not match — it is a watch that has been recording for years reported
        // as having nothing.
        #expect(HealthUnit.millilitersPerKilogramMinute.hkUnitString == "mL/min·kg")
        #expect(HealthUnit.millilitersPerKilogramMinute.rawValue == "mL/kg·min")
        #expect(HealthUnit.named("mL/min·kg", preferring: .millilitersPerKilogramMinute) == .millilitersPerKilogramMinute)
        // The spelling the payload prints is not one this app will accept from
        // HealthKit, so the two cannot be quietly swapped for each other.
        #expect(HealthUnit.named("mL/kg·min", preferring: .millilitersPerKilogramMinute) == nil)
    }

    @Test("every new figure carries its unit into the payload, or is already labelled by one")
    func figuresAreSelfDescribing() {
        // The model reads these strings and nothing else. A bare 7.4 beside a
        // 28-day average of 6.1 is a comparison it will narrate in whatever unit
        // it assumes, on a phone set to any region.
        #expect(HealthFormat.value(7.42, metric: .distance, locale: Fixture.posix) == "7.4 km")
        #expect(HealthFormat.value(72.46, metric: .body_mass, locale: Fixture.posix) == "72.5 kg")
        #expect(HealthFormat.value(42.13, metric: .vo2_max, locale: Fixture.posix) == "42.1 mL/kg·min")
        #expect(HealthFormat.value(61, metric: .heart_rate, locale: Fixture.posix) == "61 bpm")
        // The two exceptions, and they are exceptions because their own label
        // already says what they count: "Stand hours 12 hours" is a stutter.
        #expect(HealthMetric.stand_hours.label == "Stand hours")
        #expect(HealthMetric.mindful_minutes.label == "Mindful minutes")
    }

    @Test("no metric belongs to two foci, so nothing is read or reported twice")
    func fociDoNotOverlap() {
        // `oneToolCoversEverything` proves every metric is reachable; this is the
        // other half. A metric in two foci is read twice, printed twice and
        // counted twice against the notable cap.
        var seen: Set<HealthMetric> = []
        for focus in HealthFocus.allCases {
            for metric in focus.metrics {
                #expect(seen.insert(metric).inserted, "\(metric) appears in \(focus) and in another focus")
            }
        }
        #expect(seen.count == HealthMetric.allCases.count)
        #expect(HealthFocus.body.metrics == [.body_mass, .vo2_max])
    }
}
