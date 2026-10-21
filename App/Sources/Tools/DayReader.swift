import Foundation
import PocketdKit

/// Today, and the four pages behind its tiles, read straight from EventKit and
/// HealthKit.
///
/// Data first, words second: everything here is a read and a Kit rule, never a
/// generation, so Today and its detail pages are right on a phone with no brain
/// at all, and are on screen in the time EventKit takes to answer.
///
/// Every function takes the availability the caller has already decided — the
/// person's switch and iOS's grant, folded by `TodaySnapshot.Availability.of` —
/// and reads nothing for a source that is not readable. Nothing here asks iOS
/// for anything: `EventAccess` and `HealthAccess` report an unasked source as
/// not connected, and the sheet is only ever the connect door's.
///
/// Under `-pocketd.demoHealth` (Debug only) the Health reads are replaced by
/// `DemoDay`'s fabricated history — computed by the same Kit functions, so a
/// simulator shows full pages and they agree with the tiles.
enum DayReader {

    /// What each source may be read for.
    struct Access: Sendable, Equatable {
        var calendar: TodaySnapshot.Availability
        var reminders: TodaySnapshot.Availability
        var health: TodaySnapshot.Availability
    }

    /// How far back the Health reads go: the fortnight a usual is drawn from,
    /// plus the night or day being compared with it.
    static let historyDays = Usual.baselineNights + 1

    // MARK: - The snapshot

    /// Everything the Today tiles and the template brief need, in one read.
    ///
    /// A drop-in for the reads in `AppModel.makeTodaySnapshot`, and better in
    /// three ways the tiles depend on: events from this morning's midnight, so
    /// the brief can say "Nothing on your calendar today" and mean it; each
    /// reminder's time-of-day flag, so the Due tile turns a 5 PM reminder
    /// overdue at 5 PM; and the step pace, so Activity says "by now" instead
    /// of setting a morning against a whole day.
    static func snapshot(now: Date, calendar: Calendar = .current, access: Access) async -> TodaySnapshot {
        async let events = snapshotEvents(readable: access.calendar.isReadable, now: now, calendar: calendar)
        async let reminders = snapshotReminders(readable: access.reminders.isReadable, now: now, calendar: calendar)
        async let body = body(readable: access.health.isReadable, now: now, calendar: calendar)

        let (dueToday, overdue) = await reminders
        let health = await body
        return TodaySnapshot(
            generatedAt: now,
            calendar: access.calendar,
            reminders: access.reminders,
            health: access.health,
            events: await events,
            dueToday: dueToday,
            overdue: overdue,
            sleepLastNight: health.sleepLastNight,
            sleepUsual: health.sleepUsual,
            stepsToday: health.stepsToday,
            stepsUsual: health.stepsUsual,
            restingHeartRate: health.restingHeartRate,
            restingHeartRateUsual: health.restingHeartRateUsual,
            stepsUsualByNow: health.stepsUsualByNow,
            eventsCoverWholeDay: access.calendar.isReadable
        )
    }

    /// Today from midnight, and tomorrow.
    ///
    /// From midnight rather than from `now`: the morning's finished standup is
    /// what lets the brief tell "nothing else today" from "nothing today". The
    /// prompt and the tiles filter it back out themselves.
    private static func snapshotEvents(readable: Bool, now: Date, calendar: Calendar) async -> [BriefEvent] {
        guard readable else { return [] }
        let startOfToday = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: startOfToday) else { return [] }
        switch await EventAccess.shared.events(in: DateInterval(start: startOfToday, end: end), limit: 60) {
        case let .rows(rows, _): return rows.map(BriefEvent.init)
        case .unauthorized: return []
        }
    }

    /// Open reminders due by the end of today, split at this morning's
    /// midnight. The finer split by the clock is `DueSplit`'s, made when the
    /// tile is drawn, from the `dueHasTime` each row now carries.
    private static func snapshotReminders(
        readable: Bool,
        now: Date,
        calendar: Calendar
    ) async -> (due: [BriefReminder], overdue: [BriefReminder]) {
        guard readable else { return ([], []) }
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return ([], []) }
        switch await EventAccess.shared.reminders(in: DateWindow(start: nil, end: endOfToday), limit: 60) {
        case let .rows(rows, _):
            var due: [BriefReminder] = []
            var overdue: [BriefReminder] = []
            for row in rows {
                guard let deadline = row.due else { continue }
                if deadline < startOfToday {
                    overdue.append(BriefReminder(row))
                } else {
                    due.append(BriefReminder(row))
                }
            }
            return (due, overdue)
        case .unauthorized:
            return ([], [])
        }
    }

    // MARK: - Health, shared by the snapshot and the pages

    /// The night and step figures, and what is usual for both.
    struct Body: Sendable, Equatable {
        var nights: [DailyValue] = []
        var dailySteps: [DailyValue] = []
        var hourlySteps: [HealthSample]?
        var sleepLastNight: TimeInterval?
        var sleepUsual: TimeInterval?
        var stepsToday: Double?
        var stepsUsual: Double?
        var stepsUsualByNow: Double?
        var restingHeartRate: Double?
        var restingHeartRateUsual: Double?
        /// False when Health was never connected or could not be read, as
        /// opposed to connected and empty.
        var wasRead = false
    }

    /// One pass over Health: nightly sleep, and steps by the hour — from which
    /// the daily totals are summed rather than queried a second time.
    ///
    /// The usuals leave today out, for the reason `HealthSummary.baseline`
    /// gives: a night inside its own baseline is partly compared with itself,
    /// and a partial day inside a daily median pulls "usual" down every
    /// morning.
    static func body(readable: Bool, now: Date, calendar: Calendar) async -> Body {
        guard readable else { return Body() }
        #if DEBUG
        if DemoDay.isRequested {
            return summarise(
                nights: DemoDay.nights(now: now, calendar: calendar),
                hourly: DemoDay.hourlySteps(now: now, calendar: calendar),
                restingHeartRate: (DemoDay.restingHeartRate, DemoDay.restingHeartRateUsual),
                now: now,
                calendar: calendar
            )
        }
        #endif
        let startOfToday = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -historyDays, to: startOfToday) else { return Body() }
        let window = DateInterval(start: from, end: max(now, from))

        async let sleep = HealthAccess.shared.sleepIntervals(for: window)
        async let steps = HealthAccess.shared.stepBuckets(in: window, hourly: true)
        let intervals = await sleep
        let hourly = await steps
        guard intervals != nil || hourly != nil else { return Body() }
        return summarise(
            nights: HealthArithmetic.nightlyTotals(intervals ?? [], calendar: calendar),
            hourly: hourly,
            restingHeartRate: (nil, nil),
            now: now,
            calendar: calendar
        )
    }

    static func summarise(
        nights: [DailyValue],
        hourly: [HealthSample]?,
        restingHeartRate: (Double?, Double?),
        now: Date,
        calendar: Calendar
    ) -> Body {
        let startOfToday = calendar.startOfDay(for: now)
        let daily = HealthArithmetic.daily(hourly ?? [], metric: .steps, calendar: calendar)
        let earlierSteps = daily.filter { $0.day < startOfToday }.map(\.value)
        return Body(
            nights: nights,
            dailySteps: daily,
            hourlySteps: hourly,
            sleepLastNight: nights.last { calendar.isDate($0.day, inSameDayAs: startOfToday) }?.value,
            sleepUsual: Usual.typicalSleep(nights.filter { $0.day < startOfToday }.map(\.value)),
            stepsToday: daily.last { calendar.isDate($0.day, inSameDayAs: startOfToday) }?.value,
            stepsUsual: Usual.median(Array(earlierSteps.suffix(Usual.baselineNights))),
            stepsUsualByNow: hourly.flatMap { StepPace.usualByNow(hourly: $0, now: now, calendar: calendar) },
            restingHeartRate: restingHeartRate.0,
            restingHeartRateUsual: restingHeartRate.1,
            wasRead: true
        )
    }

    // MARK: - The pages

    /// Your day: NOW · LATER TODAY · TOMORROW.
    static func agenda(
        now: Date,
        calendar: Calendar = .current,
        availability: TodaySnapshot.Availability
    ) async -> DayAgenda {
        guard availability.isReadable else {
            return DayAgenda.make(events: [], availability: availability, now: now, calendar: calendar)
        }
        let startOfToday = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now
        switch await EventAccess.shared.dayEvents(in: DateInterval(start: startOfToday, end: max(end, startOfToday))) {
        case let .rows(events, _):
            return DayAgenda.make(events: events, availability: .connected, now: now, calendar: calendar)
        case let .unauthorized(authorization):
            return DayAgenda.make(events: [], availability: Self.availability(authorization), now: now, calendar: calendar)
        }
    }

    /// Reminders: OVERDUE · TODAY · LATER.
    static func reminders(
        now: Date,
        calendar: Calendar = .current,
        availability: TodaySnapshot.Availability
    ) async -> ReminderAgenda {
        guard availability.isReadable else {
            return ReminderAgenda.make(reminders: [], availability: availability, now: now, calendar: calendar)
        }
        switch await EventAccess.shared.dayReminders() {
        case let .rows(rows, _):
            return ReminderAgenda.make(reminders: rows, availability: .connected, now: now, calendar: calendar)
        case let .unauthorized(authorization):
            return ReminderAgenda.make(reminders: [], availability: Self.availability(authorization), now: now, calendar: calendar)
        }
    }

    /// Sleep: last night against usual, and the last seven nights.
    static func sleep(
        now: Date,
        calendar: Calendar = .current,
        availability: TodaySnapshot.Availability
    ) async -> SleepDetail {
        let body = await body(readable: availability.isReadable, now: now, calendar: calendar)
        return SleepDetail.make(
            nights: body.nights,
            availability: body.wasRead ? availability : notRead(availability),
            now: now,
            calendar: calendar
        )
    }

    /// Activity: today against the usual by now, and the last seven days.
    static func activity(
        now: Date,
        calendar: Calendar = .current,
        availability: TodaySnapshot.Availability
    ) async -> ActivityDetail {
        let body = await body(readable: availability.isReadable, now: now, calendar: calendar)
        return ActivityDetail.make(
            daily: body.dailySteps,
            hourly: body.hourlySteps,
            availability: body.wasRead ? availability : notRead(availability),
            now: now,
            calendar: calendar
        )
    }

    /// A refusal met at read time, as the page's availability.
    static func availability(_ authorization: PersonalDataAuthorization) -> TodaySnapshot.Availability {
        switch authorization {
        case .granted: .connected
        case .notDetermined: .off
        case .denied, .restricted, .writeOnly: .refused
        }
    }

    /// Health the caller thought readable that turned out never to have been
    /// asked: the page says "Connect", which is what is true.
    private static func notRead(_ availability: TodaySnapshot.Availability) -> TodaySnapshot.Availability {
        availability.isReadable ? .off : availability
    }
}
