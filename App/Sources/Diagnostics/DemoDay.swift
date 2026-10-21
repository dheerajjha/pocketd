import Foundation
import PocketdKit

/// The seeded demo day, everywhere it has to be told the same way.
///
/// Three places describe the demo day, and they used to describe three
/// different ones. The calendar and reminders come from `DemoSeed`; Health on a
/// simulator is fabricated under `-pocketd.demoHealth`, because a simulator has
/// no Health and this app promises never to write to Health to fill one; and
/// the demo routine results were sentences typed by hand — "Two reminders are
/// due today and one has slipped" beside a Today tile reading "1 due". Here
/// all three come from one place, through the same Kit rules the real app
/// uses, so a capture of any screen agrees with a capture of any other.
///
/// The fabricated data is compiled only into Debug, like `DemoSeed`. The one
/// member a Release build keeps is `isRequested`, permanently false, so that
/// the code asking "is this a demo?" — the snapshot's Health availability —
/// reads the same in both configurations and takes no demo path in Release.
enum DemoDay {

    /// `-pocketd.demoHealth`. Always false in Release.
    #if DEBUG
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.demoHealth")
    }
    #else
    static let isRequested = false
    #endif
}

#if DEBUG
extension DemoDay {

    // MARK: - Sleep

    /// The fortnight before last night, oldest first, in minutes.
    ///
    /// Chosen so the median is exactly 7h 05m — the usual the Today tile has
    /// always shown in captures — with the ordinary spread of a real
    /// fortnight around it, so the seven-night list does not look generated.
    static let earlierNightMinutes = [412, 431, 398, 425, 447, 405, 425, 460, 389, 436, 425, 418, 452, 425]

    /// Last night: 6h 36m, 29 minutes under the usual. Inside the band, so the
    /// tile reads "Rested" and still carries the minutes.
    static let lastNightMinutes = 396

    /// Nightly totals, each dated at the morning the night ended on, the shape
    /// `HealthArithmetic.nightlyTotals` hands back.
    static func nights(now: Date, calendar: Calendar = .current) -> [DailyValue] {
        let startOfToday = calendar.startOfDay(for: now)
        var nights: [DailyValue] = []
        for (index, minutes) in earlierNightMinutes.enumerated() {
            let back = earlierNightMinutes.count - index
            guard let morning = calendar.date(byAdding: .day, value: -back, to: startOfToday) else { continue }
            nights.append(DailyValue(day: morning, value: Double(minutes * 60)))
        }
        nights.append(DailyValue(day: startOfToday, value: Double(lastNightMinutes * 60)))
        return nights
    }

    // MARK: - Steps

    /// The fortnight before today, oldest first. Median 6,100: the usual the
    /// tile has always shown.
    static let earlierDaySteps: [Double] = [5_800, 6_400, 6_100, 7_200, 5_200, 6_100, 6_900, 4_800, 6_100, 6_600, 5_900, 6_100, 7_400, 6_300]

    /// Today so far.
    static let stepsToday: Double = 4_120

    /// How a day's walking is spread over its hours, in percent: a walk to
    /// work, lunch, a walk home. What makes "usual by now" a real comparison
    /// on a simulator rather than a straight line.
    static let hourShares: [Int: Double] = [
        7: 4, 8: 10, 9: 8, 10: 5, 11: 5, 12: 10, 13: 8, 14: 5,
        15: 5, 16: 6, 17: 10, 18: 10, 19: 7, 20: 5, 21: 2,
    ]

    /// Step counts in hour buckets, the shape `HealthAccess.stepBuckets(…,
    /// hourly: true)` hands back: the fortnight before today, then today's
    /// 4,120 spread over the hours that have begun.
    static func hourlySteps(now: Date, calendar: Calendar = .current) -> [HealthSample] {
        let startOfToday = calendar.startOfDay(for: now)
        var samples: [HealthSample] = []
        for (index, total) in earlierDaySteps.enumerated() {
            let back = earlierDaySteps.count - index
            guard let day = calendar.date(byAdding: .day, value: -back, to: startOfToday) else { continue }
            for (hour, share) in hourShares {
                guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
                samples.append(HealthSample(value: total * share / 100, unit: .count, date: start))
            }
        }

        let currentHour = calendar.component(.hour, from: now)
        let begun = hourShares.filter { $0.key <= currentHour }
        if begun.isEmpty {
            // Before seven: the whole figure in the hour already under way.
            let start = calendar.date(bySettingHour: currentHour, minute: 0, second: 0, of: now) ?? startOfToday
            samples.append(HealthSample(value: stepsToday, unit: .count, date: start))
        } else {
            let weight = begun.values.reduce(0, +)
            for (hour, share) in begun {
                guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) else { continue }
                samples.append(HealthSample(value: stepsToday * share / weight, unit: .count, date: start))
            }
        }
        return samples.sorted { $0.date < $1.date }
    }

    static let restingHeartRate: Double? = 58
    static let restingHeartRateUsual: Double? = 61

    // MARK: - The day, as one snapshot

    /// The seeded day as Today would read it at `now`, without touching
    /// EventKit: the rows `DemoSeed` stages and the Health above.
    static func snapshot(at now: Date, calendar: Calendar = .current) -> TodaySnapshot {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let horizon = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now

        let events = DemoSeed.events(now: now, calendar: calendar)
            .filter { $0.start < horizon }
            .map { BriefEvent(title: $0.title, start: $0.start, end: $0.end, location: $0.location) }

        var due: [BriefReminder] = []
        var overdue: [BriefReminder] = []
        for reminder in DemoSeed.reminders(now: now, calendar: calendar) {
            guard let stated = reminder.due else { continue }
            // As EventKit gives a date-only reminder back: at midnight.
            let deadline = reminder.dueHasTime ? stated : calendar.startOfDay(for: stated)
            guard deadline < endOfToday else { continue }
            let row = BriefReminder(title: reminder.title, due: deadline, dueHasTime: reminder.dueHasTime)
            if deadline < startOfToday { overdue.append(row) } else { due.append(row) }
        }

        let body = DayReader.summarise(
            nights: nights(now: now, calendar: calendar),
            hourly: hourlySteps(now: now, calendar: calendar),
            restingHeartRate: (restingHeartRate, restingHeartRateUsual),
            now: now,
            calendar: calendar
        )
        return TodaySnapshot(
            generatedAt: now,
            calendar: .connected,
            reminders: .connected,
            health: .connected,
            events: events,
            dueToday: due,
            overdue: overdue,
            sleepLastNight: body.sleepLastNight,
            sleepUsual: body.sleepUsual,
            stepsToday: body.stepsToday,
            stepsUsual: body.stepsUsual,
            restingHeartRate: body.restingHeartRate,
            restingHeartRateUsual: body.restingHeartRateUsual,
            stepsUsualByNow: body.stepsUsualByNow,
            eventsCoverWholeDay: true
        )
    }

    // MARK: - Routine results

    /// What the Morning brief routine wrote at `date` about the seeded day.
    ///
    /// The template brief, from the seeded rows, so the routine card and the
    /// Today tiles count the same reminders: at 7:31 that is "Standup at 9:30
    /// AM is next. You have 1 reminder due today and 1 overdue, and you slept
    /// 6h 36m, 29 min under your usual."
    static func morningBrief(at date: Date, calendar: Calendar = .current) -> String {
        BriefPrompt.fallback(
            snapshot: snapshot(at: date, calendar: calendar),
            name: DemoSeed.seededName,
            now: date,
            calendar: calendar
        )
    }

    /// The run before that, yesterday morning. Written out rather than read,
    /// because the seed stages no events for yesterday; in digits like every
    /// line on screen.
    static let yesterdaysMorningBrief = "Good morning, Sam. Standup at 9:30 AM is next, then the dentist at 4:30 PM. You have 2 reminders due today, and you slept 7h 10m, 5 min over your usual."

    /// What the Overdue nudge routine reported this morning about the seeded
    /// list: the one reminder that slipped, as `WatcherEvaluation` writes it.
    static func overdueNudge(at date: Date, calendar: Calendar = .current) -> String {
        let split = DueSplit.of(snapshot(at: date, calendar: calendar), now: date, calendar: calendar)
        let lines = split.overdue.map { reminder -> String in
            guard let due = reminder.due else { return reminder.title }
            let day = Format.dayPhrase(due, relativeTo: date, calendar: calendar)
            let time = reminder.dueHasTime ? " at \(Format.time(due, calendar: calendar))" : ""
            return "\(reminder.title) — due \(day)\(time)"
        }
        return (["\(split.overdue.count) overdue"] + lines).joined(separator: "\n")
    }
}
#endif
