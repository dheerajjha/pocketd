import Foundation

// The two detail pages that come from Health — Sleep and Activity — as values.
//
// Same split as `DayDetails`: the app reads HealthKit and hands over nightly
// totals and step buckets; every judgement — what "usual" is, whether today is
// ahead, what the grey line says — is made here, by the same functions the
// Today tiles use, so a tile and the page it opens cannot disagree.

// MARK: - Step pace

/// Where a usual day has got to by this time of day.
///
/// The figure that makes a step count readable before the day is over. A
/// morning's steps against a whole day's usual reads as "behind" every single
/// morning; against what this person has usually walked by the same minute of
/// the day, it says whether today is actually different.
public enum StepPace {

    /// Fewer than this many earlier days and there is no pace to speak of —
    /// the median of two mornings is two mornings.
    public static let minimumDays = 3

    /// The median, over the previous fortnight, of each day's steps up to the
    /// same wall-clock time as `now`.
    ///
    /// - Parameter hourly: Step counts in hour buckets, each dated at the start
    ///   of its hour, covering at least the days before today. Today's own
    ///   buckets may be included; they are ignored.
    ///
    /// The bucket containing the cut-off is counted in proportion — at 13:25,
    /// twenty-five minutes' worth of the 13:00 bucket — because an hour bucket
    /// counted whole would add a lunchtime walk that has not happened yet.
    /// Days with no steps at all are skipped rather than counted as zero: a
    /// day the phone stayed on the kitchen table is not a day this person did
    /// not walk.
    public static func usualByNow(
        hourly: [HealthSample],
        now: Date,
        calendar: Calendar = .current
    ) -> Double? {
        let startOfToday = calendar.startOfDay(for: now)
        let clock = calendar.dateComponents([.hour, .minute, .second], from: now)

        var byDay: [Date: [HealthSample]] = [:]
        for sample in hourly where sample.unit == .count && sample.value.isFinite && sample.value >= 0 {
            let day = calendar.startOfDay(for: sample.date)
            guard day < startOfToday else { continue }
            byDay[day, default: []].append(sample)
        }

        let recentDays = byDay.keys.sorted().suffix(Usual.baselineNights)
        var totals: [Double] = []
        for day in recentDays {
            let samples = byDay[day] ?? []
            guard samples.reduce(0, { $0 + $1.value }) > 0 else { continue }
            guard let cutoff = calendar.date(
                bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: clock.second ?? 0, of: day
            ) else { continue }
            totals.append(stepsBefore(cutoff, in: samples))
        }
        guard totals.count >= minimumDays else { return nil }
        return Usual.median(totals)
    }

    /// Steps in hour buckets before `cutoff`, the bucket it falls in counted
    /// in proportion.
    static func stepsBefore(_ cutoff: Date, in samples: [HealthSample]) -> Double {
        samples.reduce(0) { total, sample in
            let start = sample.date
            let end = start.addingTimeInterval(3600)
            if end <= cutoff { return total + sample.value }
            if start >= cutoff { return total }
            return total + sample.value * (cutoff.timeIntervalSince(start) / 3600)
        }
    }
}

// MARK: - Sleep

/// The Sleep page: USUAL | LAST NIGHT, the delta sentence, the last seven
/// nights.
public struct SleepDetail: Sendable, Equatable {

    public struct Night: Sendable, Equatable, Identifiable {
        /// The morning the night ended on — how Health files a night, and what
        /// "last night" means when said at breakfast.
        public var morning: Date
        /// Nil when nothing was recorded; never zero.
        public var duration: TimeInterval?
        public var id: Date { morning }

        public init(morning: Date, duration: TimeInterval?) {
            self.morning = morning
            self.duration = duration
        }

        /// The right-hand column of the list: `6h 36m`, padded for a mono
        /// column, or `—`.
        public var valueText: String {
            // Unpadded, the one way the app writes a length: "7h 5m" in the
            // list beside "7h 5m" in the Usual tile above it, not "7h 05m".
            duration.map { Format.duration($0) } ?? "—"
        }

        /// The left-hand column: `Last night`, then the evening each night
        /// began — `Monday`, `Sunday` — which is how a night is said out loud.
        ///
        /// Not the morning's date, which is how Health files it: "Today 6h 36m"
        /// at the top of a sleep list reads as a nap still in progress.
        public func label(relativeTo now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
            let gap = Format.dayGap(from: now, to: morning, calendar: calendar)
            if gap == 0 { return "Last night" }
            let evening = calendar.date(byAdding: .day, value: -1, to: morning) ?? morning
            // The seventh night began a week before tonight, on today's own
            // weekday: "Wednesday" at the foot of the list on a Wednesday
            // reads as tonight. That one, and anything older, gets its date.
            guard gap > -6 else { return Format.shortDate(evening, calendar: calendar, locale: locale) }
            return evening.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
            )
        }
    }

    /// How many nights the list shows.
    public static let listedNights = 7

    public var availability: TodaySnapshot.Availability
    public var lastNight: TimeInterval?
    public var usual: TimeInterval?
    /// Newest first: last night, then the six before it. Always seven rows
    /// when connected, with gaps as `nil`, so a missing night is visible
    /// rather than closed up.
    public var nights: [Night]
    /// The verdict the Sleep tile shows, from the same rule.
    public var verdict: TileVerdict
    /// The grey line under the title.
    public var summary: String
    public var suggestion: String { "Was this week better than last?" }

    /// `6h 36m — 29 min under your usual.`
    public var deltaSentence: String { verdict.sentence }
    /// The comparison tiles' two figures, or `—`.
    public var lastNightText: String { lastNight.map { Format.duration($0) } ?? "—" }
    public var usualText: String { usual.map { Format.duration($0) } ?? "—" }

    public init(
        availability: TodaySnapshot.Availability,
        lastNight: TimeInterval?,
        usual: TimeInterval?,
        nights: [Night],
        verdict: TileVerdict,
        summary: String
    ) {
        self.availability = availability
        self.lastNight = lastNight
        self.usual = usual
        self.nights = nights
        self.verdict = verdict
        self.summary = summary
    }

    /// - Parameter nights: Nightly totals as `HealthArithmetic.nightlyTotals`
    ///   returns them, each dated at the morning it ended on. At least the
    ///   last fortnight, so the usual has something to stand on.
    ///
    /// The usual leaves last night out, for the reason `HealthSummary` gives at
    /// length: a night included in its own baseline is partly compared with
    /// itself. It is the same `Usual.typicalSleep` the Today tile's reader
    /// uses, so the page and the tile quote one number.
    public static func make(
        nights: [DailyValue],
        availability: TodaySnapshot.Availability,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> SleepDetail {
        let startOfToday = calendar.startOfDay(for: now)
        let lastNight = nights.last { calendar.isDate($0.day, inSameDayAs: startOfToday) }?.value
        let usual = Usual.typicalSleep(nights.filter { $0.day < startOfToday }.map(\.value))

        let snapshot = TodaySnapshot(generatedAt: now, health: availability, sleepLastNight: lastNight, sleepUsual: usual)
        let verdict = TodayVerdicts.sleep(snapshot)
        guard availability.isReadable else {
            return SleepDetail(
                availability: availability, lastNight: nil, usual: nil, nights: [],
                verdict: verdict,
                summary: availability == .refused ? "Health is off in Settings." : "Connect Health to see how you slept."
            )
        }

        let listed: [Night] = (0..<listedNights).compactMap { offset in
            guard let morning = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { return nil }
            let value = nights.last { calendar.isDate($0.day, inSameDayAs: morning) }?.value
            return Night(morning: morning, duration: value.flatMap { $0 > 0 ? $0 : nil })
        }

        return SleepDetail(
            availability: availability,
            lastNight: lastNight,
            usual: usual,
            nights: listed,
            verdict: verdict,
            summary: summary(listed)
        )
    }

    /// `You averaged 7h 2m a night this week.`
    ///
    /// The mean, not the median, and deliberately: this sentence describes the
    /// week that happened, short nights included, rather than the habit the
    /// usual is meant to capture.
    static func summary(_ nights: [Night]) -> String {
        let recorded = nights.compactMap(\.duration)
        guard !recorded.isEmpty else { return "No sleep recorded this week." }
        let average = Format.duration(recorded.reduce(0, +) / Double(recorded.count))
        guard recorded.count < nights.count else { return "You averaged \(average) a night this week." }
        return "You averaged \(average) over the \(Format.counted(recorded.count, "night")) recorded this week."
    }
}

// MARK: - Activity

/// The Activity page: TODAY | USUAL BY NOW (or A DAY), the sentence, the last
/// seven days.
public struct ActivityDetail: Sendable, Equatable {

    public struct Day: Sendable, Equatable, Identifiable {
        public var day: Date
        public var steps: Double?
        public var isToday: Bool
        public var id: Date { day }

        public init(day: Date, steps: Double?, isToday: Bool) {
            self.day = day
            self.steps = steps
            self.isToday = isToday
        }

        /// `4,120`, or `—`.
        public func valueText(locale: Locale = .current) -> String {
            steps.map { Format.count($0, locale: locale) } ?? "—"
        }

        /// `Today`, `Yesterday`, then the weekday.
        public func label(relativeTo now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
            Format.day(day, relativeTo: now, calendar: calendar, locale: locale)
        }
    }

    public static let listedDays = 7

    public var availability: TodaySnapshot.Availability
    public var today: Double?
    public var usualByNow: Double?
    public var usualDaily: Double?
    /// Newest first: today (so far), then the six days before it.
    public var days: [Day]
    /// The verdict the Activity tile shows, from the same rule.
    public var verdict: TileVerdict
    public var summary: String
    public var suggestion: String { "How active was I this week?" }

    public var deltaSentence: String { verdict.sentence }

    /// The grey comparison tile's label: by now when there is a pace to
    /// compare with, a day when there is only the daily figure.
    public var usualLabel: String { usualByNow == nil ? "Usual a day" : "Usual by now" }
    public func todayText(locale: Locale = .current) -> String { today.map { Format.count($0, locale: locale) } ?? "—" }
    public func usualText(locale: Locale = .current) -> String {
        (usualByNow ?? usualDaily).map { Format.count($0, locale: locale) } ?? "—"
    }

    public init(
        availability: TodaySnapshot.Availability,
        today: Double?,
        usualByNow: Double?,
        usualDaily: Double?,
        days: [Day],
        verdict: TileVerdict,
        summary: String
    ) {
        self.availability = availability
        self.today = today
        self.usualByNow = usualByNow
        self.usualDaily = usualDaily
        self.days = days
        self.verdict = verdict
        self.summary = summary
    }

    /// - Parameter daily: Steps per day, as `HealthArithmetic.daily` returns
    ///   them, covering at least the last fortnight and today.
    /// - Parameter hourly: Hour buckets for the same span, when the reader
    ///   could get them. Nil leaves the page on the daily figure.
    public static func make(
        daily: [DailyValue],
        hourly: [HealthSample]?,
        availability: TodaySnapshot.Availability,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> ActivityDetail {
        let startOfToday = calendar.startOfDay(for: now)
        let today = daily.last { calendar.isDate($0.day, inSameDayAs: startOfToday) }?.value
        let earlier = daily.filter { $0.day < startOfToday }.map(\.value)
        let usualDaily = Usual.median(Array(earlier.suffix(Usual.baselineNights)))
        let usualByNow = hourly.flatMap { StepPace.usualByNow(hourly: $0, now: now, calendar: calendar) }

        let snapshot = TodaySnapshot(
            generatedAt: now, health: availability,
            stepsToday: today, stepsUsual: usualDaily, stepsUsualByNow: usualByNow
        )
        let verdict = TodayVerdicts.activity(snapshot, calendar: calendar, locale: locale)
        guard availability.isReadable else {
            return ActivityDetail(
                availability: availability, today: nil, usualByNow: nil, usualDaily: nil, days: [],
                verdict: verdict,
                summary: availability == .refused ? "Health is off in Settings." : "Connect Health to see your steps."
            )
        }

        let listed: [Day] = (0..<listedDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { return nil }
            let value = daily.last { calendar.isDate($0.day, inSameDayAs: day) }?.value
            return Day(day: day, steps: value, isToday: offset == 0)
        }

        return ActivityDetail(
            availability: availability,
            today: today,
            usualByNow: usualByNow,
            usualDaily: usualDaily,
            days: listed,
            verdict: verdict,
            summary: summary(verdict: verdict, usualByNow: usualByNow, usualDaily: usualDaily, locale: locale)
        )
    }

    /// `You're ahead of your usual pace today.` — or, with only a daily
    /// figure, what that figure is, rather than a judgement on an estimate.
    static func summary(verdict: TileVerdict, usualByNow: Double?, usualDaily: Double?, locale: Locale) -> String {
        if usualByNow != nil {
            switch verdict.status {
            case "Ahead": return "You're ahead of your usual pace today."
            case "Behind": return "You're behind your usual pace today."
            case "On track": return "You're on your usual pace today."
            default: break
            }
        }
        if verdict.status == "No data" { return "No steps recorded today." }
        if let usualDaily {
            return "You usually walk \(Format.counted(Int(usualDaily.rounded()), "step", locale: locale)) a day."
        }
        return "Your usual shows after a few more days."
    }
}
