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
        let calendar = Fixture.calendar()
        func total(seconds: TimeInterval) -> Double? {
            let start = Fixture.date(2025, 9, 8, 0, 0)
            let intervals = [SleepInterval(start: start, end: start.addingTimeInterval(seconds), asleep: true)]
            return HealthArithmetic.nightlyTotals(intervals, calendar: calendar).first?.value
        }
        #expect(total(seconds: HealthArithmetic.maximumNightSeconds) == HealthArithmetic.maximumNightSeconds)
        #expect(total(seconds: HealthArithmetic.maximumNightSeconds + 60) == nil)
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
        for mean in [0.0, 1e-12, 100.0] {
            for sd in [0.0, 1e-12, 10.0] {
                for value in [0.0, 100.0, 1e9] {
                    let comparison = HealthArithmetic.compare(
                        value: value, on: Fixture.date(2025, 9, 10, 0, 0), metric: .steps,
                        to: Self.baseline(mean: mean, sd: sd)
                    )
                    #expect(comparison.zScore?.isFinite ?? true, "mean \(mean) sd \(sd) value \(value)")
                    #expect(comparison.percentDelta?.isFinite ?? true, "mean \(mean) sd \(sd) value \(value)")
                }
            }
        }
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

    @Test("a better day inside the last month is not news")
    func recentBetterDayIsNotASuperlative() {
        // "Best since Tuesday" describes ordinary variation dressed up as a
        // finding. A month is the shortest gap at which "best since" tells the
        // user something they did not already know.
        let calendar = Fixture.calendar()
        let today = Fixture.date(2025, 9, 11, 0, 0)
        var days = Fixture.series(endingBefore: today, count: 200, calendar: calendar) { back in
            back == 10 ? 20_000 : 6_000
        }
        days.append(DailyValue(day: today, value: 12_000))

        #expect(HealthArithmetic.superlative(in: days, direction: .higherIsBetter, calendar: calendar) == nil)
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
                == .bestInReach(spanDays: 100)
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
                == .bestInReach(spanDays: 120)
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

    @Test("with only today's steps there is no comparable day at all")
    func noCompletedDayIsHonestlyNothing() {
        let calendar = Fixture.calendar()
        let now = Fixture.date(2025, 9, 11, 10, 0)
        let days = [DailyValue(day: calendar.startOfDay(for: now), value: 900)]

        #expect(HealthArithmetic.mostRecentComparableDay(in: days, metric: .steps, now: now, calendar: calendar) == nil)
    }
}
