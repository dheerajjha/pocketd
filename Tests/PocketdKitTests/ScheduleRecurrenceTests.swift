import Foundation
import Testing
@testable import PocketdKit

/// Where schedulers actually break.
///
/// Not in the enum, not in the store — in the two hours a year that do not
/// exist, the hour that happens twice, the month with no 31st, the midnight
/// that is both the end of one day and the start of the next, and the user who
/// got on a plane. Every one of these is a real bug somebody has shipped, and
/// every one of them is invisible on a developer's machine in June.
///
/// The single assertion that pays for this whole file is `springForwardIs23Hours`:
/// it is the test that fails the moment anyone replaces a calendar day step with
/// `addingTimeInterval(86_400)`, which looks equivalent, passes every test
/// written in a fixed-offset zone, and is wrong for two weeks of the year in
/// every zone that observes daylight saving.
@Suite("Scheduled task recurrence")
struct ScheduleRecurrenceTests {

    // MARK: - Fixtures

    static let london = TimeZone(identifier: "Europe/London")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let utc = TimeZone(identifier: "UTC")!

    static func calendar(_ zone: TimeZone = utc, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0,
        zone: TimeZone = utc
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    /// The wall-clock reading of an instant, which is the thing a user sees and
    /// the thing an instant comparison cannot express.
    static func wallClock(_ date: Date, in zone: TimeZone) -> (hour: Int, minute: Int, day: Int, month: Int) {
        let components = calendar(zone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (components.hour!, components.minute!, components.day!, components.month!)
    }

    static let nine = TimeOfDay(hour: 9, minute: 0)

    // MARK: - The ordinary cases, so the awkward ones mean something

    @Test("a daily task due later today fires today")
    func dailyLaterToday() {
        let next = FireSequence.next(
            after: Self.date(2026, 9, 14, 7, 0),
            of: .daily(at: Self.nine),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 9, 14, 9, 0))
    }

    @Test("a daily task whose time has gone fires tomorrow, not in a second")
    func dailyAlreadyGone() {
        let next = FireSequence.next(
            after: Self.date(2026, 9, 14, 14, 0),
            of: .daily(at: Self.nine),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 9, 15, 9, 0))
    }

    @Test("next is strictly after, so settling a firing cannot hand it straight back")
    func nextIsStrict() {
        let firing = Self.date(2026, 9, 14, 9, 0)
        #expect(FireSequence.next(after: firing, of: .daily(at: Self.nine), calendar: Self.calendar())
                == Self.date(2026, 9, 15, 9, 0))
    }

    @Test("last is inclusive, so a task evaluated at its own firing instant is owed")
    func lastIsInclusive() {
        let firing = Self.date(2026, 9, 14, 9, 0)
        #expect(FireSequence.last(onOrBefore: firing, of: .daily(at: Self.nine), calendar: Self.calendar())
                == firing)
    }

    @Test("a daily task crosses a month end without arithmetic on the day number")
    func acrossMonthEnd() {
        let next = FireSequence.next(
            after: Self.date(2026, 1, 31, 18, 0),
            of: .daily(at: Self.nine),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 2, 1, 9, 0))
    }

    // MARK: - Midnight

    @Test("a task at midnight fires at midnight, not a day late")
    func midnightFiresOnItsOwnDay() {
        let calendar = Self.calendar()
        let midnight = TimeOfDay(hour: 0, minute: 0)
        // The trap: placing a clock time inside a day searches forward from the
        // start of that day, and the start of that day IS midnight. An
        // implementation that searched strictly after it would put every
        // midnight task twenty-four hours late, every time, and nothing else in
        // this file would notice.
        #expect(FireSequence.fireInstant(
            on: Self.date(2026, 3, 10), at: midnight, calendar: calendar
        ) == Self.date(2026, 3, 10))
    }

    @Test("midnight belongs to the day it opens: owed now, next tomorrow")
    func midnightBoundary() {
        let calendar = Self.calendar()
        let midnight = TimeOfDay(hour: 0, minute: 0)
        let instant = Self.date(2026, 3, 10)

        #expect(FireSequence.last(onOrBefore: instant, of: .daily(at: midnight), calendar: calendar) == instant)
        #expect(FireSequence.next(after: instant, of: .daily(at: midnight), calendar: calendar)
                == Self.date(2026, 3, 11))
    }

    // MARK: - Daylight saving

    @Test("the gap across spring forward is 23 hours, which 86,400 seconds is not")
    func springForwardIs23Hours() {
        // Europe/London, 29 March 2026: 01:00 GMT becomes 02:00 BST, so the day
        // is 23 hours long. A daily 09:00 task must still fire at 09:00 — the
        // number on the clock, not the number of seconds since the last one.
        let calendar = Self.calendar(Self.london)
        let saturday = Self.date(2026, 3, 28, 9, 0, zone: Self.london)
        let sunday = FireSequence.next(after: saturday, of: .daily(at: Self.nine), calendar: calendar)
        let fired = try! #require(sunday)

        #expect(Self.wallClock(fired, in: Self.london).hour == 9)
        #expect(Self.wallClock(fired, in: Self.london).day == 29)
        // The load-bearing line. Anything built on adding a fixed day of
        // seconds produces 86,400 here and an 08:00 notification for the next
        // six months.
        #expect(fired.timeIntervalSince(saturday) == 23 * 3600)
    }

    @Test("the gap across fall back is 25 hours, and the task still says 09:00")
    func fallBackIs25Hours() {
        let calendar = Self.calendar(Self.london)
        let saturday = Self.date(2026, 10, 24, 9, 0, zone: Self.london)
        let sunday = try! #require(
            FireSequence.next(after: saturday, of: .daily(at: Self.nine), calendar: calendar)
        )
        #expect(Self.wallClock(sunday, in: Self.london).hour == 9)
        #expect(sunday.timeIntervalSince(saturday) == 25 * 3600)
    }

    @Test("a task at a clock time that does not exist fires at the next one that does")
    func springForwardSkippedTime() {
        // 01:30 on 29 March 2026 in London is not a time. `.strict` would
        // return nothing and the task would silently skip a day once a year;
        // `.nextTime` fires it at 02:00, which is the first moment that exists.
        let calendar = Self.calendar(Self.london)
        let fired = try! #require(FireSequence.next(
            after: Self.date(2026, 3, 29, 0, 0, zone: Self.london),
            of: .daily(at: TimeOfDay(hour: 1, minute: 30)),
            calendar: calendar
        ))
        let clock = Self.wallClock(fired, in: Self.london)
        #expect(clock.day == 29)
        #expect(clock.hour == 2)
        #expect(clock.minute == 0)
    }

    @Test("a task at a clock time that happens twice fires once, on the first one")
    func fallBackRepeatedTime() {
        // 25 October 2026 in London runs 01:00–01:59 twice: once at UTC+1 and
        // again at UTC+0. A scheduler that matches both sends the same
        // notification an hour apart, which is the version of this bug users
        // actually notice and report.
        let calendar = Self.calendar(Self.london)
        let halfPastOne = TimeOfDay(hour: 1, minute: 30)
        let first = try! #require(FireSequence.next(
            after: Self.date(2026, 10, 25, 0, 0, zone: Self.london),
            of: .daily(at: halfPastOne),
            calendar: calendar
        ))
        // The BST reading, an hour before the GMT one.
        #expect(first == Self.date(2026, 10, 25, 0, 30, zone: Self.utc))

        // ...and the one after it is the NEXT day, not the second 01:30.
        let following = try! #require(
            FireSequence.next(after: first, of: .daily(at: halfPastOne), calendar: calendar)
        )
        #expect(following == Self.date(2026, 10, 26, 1, 30, zone: Self.london))
        #expect(Self.wallClock(following, in: Self.london).day == 26)
    }

    // MARK: - The user moving

    @Test("the same rule fires at nine wherever the user is standing")
    func timeZoneChange() {
        // The point of storing a clock time rather than an instant. Same rule,
        // same moment of evaluation, two devices — or one device on either side
        // of a flight.
        let recurrence = Recurrence.daily(at: Self.nine)
        let now = Self.date(2026, 6, 15, 12, 0, zone: Self.utc)

        let inLondon = try! #require(
            FireSequence.next(after: now, of: recurrence, calendar: Self.calendar(Self.london))
        )
        let inTokyo = try! #require(
            FireSequence.next(after: now, of: recurrence, calendar: Self.calendar(Self.tokyo))
        )

        #expect(Self.wallClock(inLondon, in: Self.london).hour == 9)
        #expect(Self.wallClock(inTokyo, in: Self.tokyo).hour == 9)
        // Different absolute instants. Had the rule been stored as a `Date`,
        // both would be the same instant and one of the two would be wrong by
        // the whole offset — 09:00 London is 17:00 in Tokyo.
        #expect(inLondon != inTokyo)
        // London is already past 09:00 local on the 15th, so it waits for the
        // 16th; Tokyo is past 21:00, so it also waits for the 16th — and 09:00
        // in Tokyo comes first.
        #expect(inTokyo < inLondon)
    }

    // MARK: - Short months

    @Test("the 31st skips February when the rule says skip")
    func monthlySkipsAShortMonth() {
        let next = FireSequence.next(
            after: Self.date(2026, 1, 31, 12, 0),
            of: .monthly(day: 31, at: Self.nine, whenShort: .skip),
            calendar: Self.calendar()
        )
        // February 2026 has 28 days and March has 31, so the next firing is two
        // months away. Clamping silently would have produced 28 February.
        #expect(next == Self.date(2026, 3, 31, 9, 0))
    }

    @Test("the 31st lands on the last day of February when the rule says last day")
    func monthlyClampsToLastDay() {
        let next = FireSequence.next(
            after: Self.date(2026, 1, 31, 12, 0),
            of: .monthly(day: 31, at: Self.nine, whenShort: .lastDay),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 2, 28, 9, 0))
    }

    @Test("the last day of February is the 29th in a leap year")
    func monthlyKnowsAboutLeapYears() {
        // The reason this asks the calendar for the month's length rather than
        // carrying a table of twelve numbers.
        let next = FireSequence.next(
            after: Self.date(2028, 1, 31, 12, 0),
            of: .monthly(day: 31, at: Self.nine, whenShort: .lastDay),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2028, 2, 29, 9, 0))
    }

    @Test("the 30th skips February too, and lands in March")
    func monthlySkipsForThirtiethAsWell() {
        let next = FireSequence.next(
            after: Self.date(2026, 1, 30, 12, 0),
            of: .monthly(day: 30, at: Self.nine, whenShort: .skip),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 3, 30, 9, 0))
    }

    @Test("a clamped monthly task does not fire twice in a month that is long enough")
    func monthlyClampDoesNotDouble() {
        // 31 March exists, so `.lastDay` must fire on the 31st and not also on
        // some other day it considers the end.
        let calendar = Self.calendar()
        let march = try! #require(FireSequence.next(
            after: Self.date(2026, 3, 1, 12, 0),
            of: .monthly(day: 31, at: Self.nine, whenShort: .lastDay),
            calendar: calendar
        ))
        #expect(march == Self.date(2026, 3, 31, 9, 0))
        #expect(FireSequence.next(after: march, of: .monthly(day: 31, at: Self.nine, whenShort: .lastDay),
                                  calendar: calendar) == Self.date(2026, 4, 30, 9, 0))
    }

    // MARK: - Weekly

    @Test("a weekly task picks the next selected day")
    func weeklyNextDay() {
        // 14 September 2026 is a Monday; the 16th is the Wednesday.
        let next = FireSequence.next(
            after: Self.date(2026, 9, 14, 12, 0),
            of: .weekly(days: [.monday, .wednesday], at: Self.nine),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 9, 16, 9, 0))
    }

    @Test("a weekly task on today's weekday, already past, waits a whole week")
    func weeklyWrapsAround() {
        let next = FireSequence.next(
            after: Self.date(2026, 9, 14, 12, 0),
            of: .weekly(days: [.monday], at: Self.nine),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 9, 21, 9, 0))
    }

    @Test("weekdays means Monday to Friday, so Friday evening points at Monday")
    func weekdaysSkipTheWeekend() {
        // 18 September 2026 is a Friday. Sunday is `Weekday` raw value 1, which
        // is where a hand-rolled set literal gets this wrong.
        let next = FireSequence.next(
            after: Self.date(2026, 9, 18, 18, 0),
            of: .weekdays(at: Self.nine),
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 9, 21, 9, 0))
        #expect(Weekday.workdays.contains(.sunday) == false)
        #expect(Weekday.workdays.contains(.saturday) == false)
        #expect(Weekday.workdays.count == 5)
    }

    @Test("a weekly task landing on the transition day still says 09:00")
    func weeklyOntoATransitionDay() {
        // The daily tests above reach the transition day in a single step. This
        // one walks seven days to get there, so it covers the handoff between
        // the day walk and the placement of the clock time inside the day —
        // placement being where an offset calculation actually goes wrong,
        // because on 29 March the hour between midnight and 09:00 is 23 hours
        // long in wall-clock terms and 22 in real ones.
        let calendar = Self.calendar(Self.london)
        let previous = Self.date(2026, 3, 22, 9, 0, zone: Self.london)
        let fired = try! #require(FireSequence.next(
            after: previous,
            of: .weekly(days: [.sunday], at: Self.nine),
            calendar: calendar
        ))
        let clock = Self.wallClock(fired, in: Self.london)
        #expect((clock.month, clock.day, clock.hour, clock.minute) == (3, 29, 9, 0))
        // A week minus the hour the clocks took.
        #expect(fired.timeIntervalSince(previous) == 167 * 3600)
    }

    @Test("a monthly task landing on the transition day still says 09:00")
    func monthlyOntoATransitionDay() {
        let calendar = Self.calendar(Self.london)
        let fired = try! #require(FireSequence.next(
            after: Self.date(2026, 3, 1, 12, 0, zone: Self.london),
            of: .monthly(day: 29, at: Self.nine, whenShort: .lastDay),
            calendar: calendar
        ))
        let clock = Self.wallClock(fired, in: Self.london)
        #expect((clock.month, clock.day, clock.hour, clock.minute) == (3, 29, 9, 0))
    }

    @Test("a weekly rule with no days selected never fires, and says so")
    func weeklyWithNoDays() {
        let recurrence = Recurrence.weekly(days: [], at: Self.nine)
        #expect(recurrence.isFireable == false)
        // Must terminate rather than walk to the horizon looking for a day that
        // cannot exist.
        #expect(FireSequence.next(after: Self.date(2026, 9, 14), of: recurrence, calendar: Self.calendar()) == nil)
        #expect(FireSequence.last(onOrBefore: Self.date(2026, 9, 14), of: recurrence, calendar: Self.calendar()) == nil)
    }

    // MARK: - One-shots

    @Test("a one-shot in the future is next, and nothing is owed")
    func onceAhead() {
        let when = Self.date(2026, 9, 20, 15, 0)
        let recurrence = Recurrence.once(when)
        #expect(FireSequence.next(after: Self.date(2026, 9, 14), of: recurrence, calendar: Self.calendar()) == when)
        #expect(FireSequence.last(onOrBefore: Self.date(2026, 9, 14), of: recurrence, calendar: Self.calendar()) == nil)
    }

    @Test("a one-shot that has passed is owed once and never again")
    func onceBehind() {
        let when = Self.date(2026, 9, 13, 15, 0)
        let recurrence = Recurrence.once(when)
        #expect(FireSequence.last(onOrBefore: Self.date(2026, 9, 14), of: recurrence, calendar: Self.calendar()) == when)
        #expect(FireSequence.next(after: Self.date(2026, 9, 14), of: recurrence, calendar: Self.calendar()) == nil)
    }

    // MARK: - A clamped time of day

    @Test("an impossible time of day is clamped rather than left to spin")
    func timeOfDayIsClamped() {
        // Reachable from a file on disk. An hour of 25 matches no day, and the
        // day walk would run to its horizon on every evaluation looking for it.
        let clamped = TimeOfDay(hour: 25, minute: 99)
        #expect(clamped.hour == 23)
        #expect(clamped.minute == 59)

        let decoded = try! JSONDecoder().decode(
            TimeOfDay.self, from: Data(#"{"hour":25,"minute":-4}"#.utf8)
        )
        #expect(decoded.hour == 23)
        #expect(decoded.minute == 0)
    }

    // MARK: - Dueness

    @Test("a task created after today's firing is not instantly due")
    func createdInThePast() {
        // The bug this is the fix for: create a 09:00 morning briefing at two in
        // the afternoon and it fires immediately, because 09:00 today is behind
        // `now`. `settledThrough` starts at `createdAt`, so the morning that had
        // already gone before the task existed is already settled.
        let created = Self.date(2026, 9, 14, 14, 0)
        let task = ScheduledTask(
            title: "Morning briefing",
            body: .prompt("What is on today?"),
            recurrence: .daily(at: Self.nine),
            createdAt: created
        )
        let dueness = task.dueness(now: Self.date(2026, 9, 14, 14, 0), calendar: Self.calendar())
        #expect(dueness.owed == nil)
        #expect(dueness.next == Self.date(2026, 9, 15, 9, 0))
    }

    @Test("the same task is due once its own morning comes round")
    func dueAfterTheFirstRealFiring() {
        let task = ScheduledTask(
            title: "Morning briefing",
            body: .prompt("What is on today?"),
            recurrence: .daily(at: Self.nine),
            createdAt: Self.date(2026, 9, 14, 14, 0)
        )
        let dueness = task.dueness(now: Self.date(2026, 9, 15, 9, 30), calendar: Self.calendar())
        #expect(dueness.owed == Self.date(2026, 9, 15, 9, 0))
        #expect(dueness.missed == 0)
        #expect(dueness.next == Self.date(2026, 9, 16, 9, 0))
    }

    @Test("four days in a drawer produce one firing, not four")
    func missedFiringsCollapse() {
        // A phone that was off, or that iOS declined to wake, must not deliver
        // four identical notifications the moment it comes back.
        let task = ScheduledTask(
            title: "Overdue",
            body: .watcher(rule: .reminders(.overdue), notifyWhenEmpty: false),
            recurrence: .daily(at: Self.nine),
            createdAt: Self.date(2026, 3, 1, 8, 0),
            settledThrough: Self.date(2026, 3, 1, 9, 0)
        )
        let dueness = task.dueness(now: Self.date(2026, 3, 5, 10, 0), calendar: Self.calendar())
        #expect(dueness.owed == Self.date(2026, 3, 5, 9, 0))
        // The 2nd, 3rd and 4th. Reported rather than hidden, so the UI can say
        // the schedule was not kept instead of implying it was.
        #expect(dueness.missed == 3)
    }

    @Test("the missed count saturates rather than walking a year of firings")
    func missedSaturates() {
        let task = ScheduledTask(
            title: "Ancient",
            body: .watcher(rule: .reminders(.overdue), notifyWhenEmpty: false),
            recurrence: .daily(at: Self.nine),
            createdAt: Self.date(2020, 1, 1),
            settledThrough: Self.date(2020, 1, 1)
        )
        let dueness = task.dueness(now: Self.date(2026, 9, 14, 10, 0), calendar: Self.calendar())
        #expect(dueness.missed == Dueness.missedCap)
        #expect(dueness.owed == Self.date(2026, 9, 14, 9, 0))
    }

    @Test("a disabled task is never due and offers no next firing to schedule")
    func disabledTaskIsInert() {
        var task = ScheduledTask(
            title: "Paused",
            body: .watcher(rule: .events(.today), notifyWhenEmpty: false),
            recurrence: .daily(at: Self.nine),
            createdAt: Self.date(2026, 9, 1)
        )
        task.isEnabled = false
        let dueness = task.dueness(now: Self.date(2026, 9, 14, 10, 0), calendar: Self.calendar())
        #expect(dueness.owed == nil)
        // nil rather than tomorrow: the app cancels its pending notification
        // request off this, and a date here would leave one queued for a firing
        // that will not happen.
        #expect(dueness.next == nil)
    }

    @Test("settling advances past every missed firing, so it cannot fire again")
    func settlingClosesTheGap() {
        var task = ScheduledTask(
            title: "Overdue",
            body: .watcher(rule: .reminders(.overdue), notifyWhenEmpty: false),
            recurrence: .daily(at: Self.nine),
            createdAt: Self.date(2026, 3, 1, 8, 0),
            settledThrough: Self.date(2026, 3, 1, 9, 0)
        )
        let now = Self.date(2026, 3, 5, 10, 0)
        let owed = try! #require(task.dueness(now: now, calendar: Self.calendar()).owed)
        task.settle(.nothingToReport(firing: owed, ranAt: now, context: .backgroundRefresh), at: now)

        #expect(task.settledThrough == owed)
        let after = task.dueness(now: Self.date(2026, 3, 5, 10, 1), calendar: Self.calendar())
        #expect(after.owed == nil)
        #expect(after.next == Self.date(2026, 3, 6, 9, 0))
    }
}
