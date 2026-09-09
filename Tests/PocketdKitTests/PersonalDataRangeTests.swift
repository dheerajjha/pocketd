import Foundation
import Testing
@testable import PocketdKit

/// The calendar and reminder tools cannot be tested — they need a device with a
/// real EventKit database and a human to tap a permission prompt. What CAN be
/// tested is every decision they make before EventKit is touched: which dates a
/// range name resolves to, and what the user is told when there is nothing to
/// show. Both have been wrong in shipped software far more often than the
/// EventKit call has.
@Suite("Personal data ranges")
struct PersonalDataRangeTests {

    // MARK: - Fixtures

    static let london = TimeZone(identifier: "Europe/London")!
    static let utc = TimeZone(identifier: "UTC")!

    static func calendar(firstWeekday: Int, zone: TimeZone = utc) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0,
        zone: TimeZone = utc
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: - Days

    @Test("today runs midnight to midnight, not now to now")
    func today() {
        let calendar = Self.calendar(firstWeekday: 2)
        let now = Self.date(2025, 9, 11, 14, 37)
        let window = PersonalDataRange.eventWindow(for: .today, now: now, calendar: calendar)

        #expect(window.start == Self.date(2025, 9, 11, 0, 0))
        #expect(window.end == Self.date(2025, 9, 12, 0, 0))
        #expect(window.contains(now))
        // A meeting at 09:00 has already happened and is still today's.
        #expect(window.contains(Self.date(2025, 9, 11, 9, 0)))
    }

    @Test("midnight belongs to the day it opens, so today and tomorrow abut without overlapping")
    func halfOpen() {
        let calendar = Self.calendar(firstWeekday: 2)
        let now = Self.date(2025, 9, 11, 14, 37)
        let today = PersonalDataRange.eventWindow(for: .today, now: now, calendar: calendar)
        let tomorrow = PersonalDataRange.eventWindow(for: .tomorrow, now: now, calendar: calendar)

        let boundary = Self.date(2025, 9, 12, 0, 0)
        #expect(today.end == tomorrow.start)
        #expect((boundary < today.end) == false)  // not today's
        #expect(boundary >= tomorrow.start)       // tomorrow's

        // Foundation's `DateInterval.contains` is CLOSED at both ends: it
        // answers true for `end`. So midnight is in *both* intervals by that
        // measure, and it must never be the thing that decides which day an
        // event belongs to. `startDate < window.end` is the test the calendar
        // tool actually applies, for exactly this reason — EventKit's own
        // predicate is inclusive too and hands back the event that starts on
        // the closing midnight.
        #expect(today.contains(boundary))
        #expect(tomorrow.contains(boundary))
    }

    @Test("tomorrow is today shifted by exactly one day")
    func tomorrow() {
        let calendar = Self.calendar(firstWeekday: 2)
        let now = Self.date(2025, 9, 11, 23, 59)
        let window = PersonalDataRange.eventWindow(for: .tomorrow, now: now, calendar: calendar)

        #expect(window.start == Self.date(2025, 9, 12, 0, 0))
        #expect(window.end == Self.date(2025, 9, 13, 0, 0))
        #expect(window.contains(now) == false)
    }

    @Test("tomorrow crosses a month end")
    func tomorrowAcrossMonth() {
        let calendar = Self.calendar(firstWeekday: 2)
        let window = PersonalDataRange.eventWindow(
            for: .tomorrow, now: Self.date(2025, 1, 31, 18, 0), calendar: calendar
        )
        #expect(window.start == Self.date(2025, 2, 1, 0, 0))
        #expect(window.end == Self.date(2025, 2, 2, 0, 0))
    }

    // MARK: - Weeks and the first weekday

    @Test("this week starts on Monday for a Monday-first calendar")
    func weekStartsMonday() {
        let calendar = Self.calendar(firstWeekday: 2)
        // Wednesday 10 September 2025.
        let window = PersonalDataRange.eventWindow(
            for: .this_week, now: Self.date(2025, 9, 10, 12, 0), calendar: calendar
        )
        #expect(window.start == Self.date(2025, 9, 8, 0, 0))   // Monday
        #expect(window.end == Self.date(2025, 9, 15, 0, 0))    // the next Monday
    }

    @Test("the same instant gives a different week on a Sunday-first calendar")
    func weekStartsSunday() {
        let window = PersonalDataRange.eventWindow(
            for: .this_week, now: Self.date(2025, 9, 10, 12, 0), calendar: Self.calendar(firstWeekday: 1)
        )
        #expect(window.start == Self.date(2025, 9, 7, 0, 0))   // Sunday
        #expect(window.end == Self.date(2025, 9, 14, 0, 0))
    }

    @Test("...and a different one again on a Saturday-first calendar")
    func weekStartsSaturday() {
        // Much of the Gulf. If this is wrong the tool reports the wrong week to
        // an entire region and nothing else in the app notices.
        let window = PersonalDataRange.eventWindow(
            for: .this_week, now: Self.date(2025, 9, 10, 12, 0), calendar: Self.calendar(firstWeekday: 7)
        )
        #expect(window.start == Self.date(2025, 9, 6, 0, 0))   // Saturday
        #expect(window.end == Self.date(2025, 9, 13, 0, 0))
    }

    @Test("asked on the first day of the week, the week starts today")
    func onTheFirstDay() {
        let calendar = Self.calendar(firstWeekday: 2)
        let now = Self.date(2025, 9, 8, 0, 1) // Monday, one minute past midnight
        let window = PersonalDataRange.eventWindow(for: .this_week, now: now, calendar: calendar)

        #expect(window.start == Self.date(2025, 9, 8, 0, 0))
        #expect(window.contains(now))
    }

    @Test("asked on the last day of the week, the week still contains today")
    func onTheLastDay() {
        // The off-by-one that would break this is the reason it is here: a week
        // computed as "now ..< now + 7 days" passes every other test in this
        // file and fails only on the final day.
        let calendar = Self.calendar(firstWeekday: 2)
        let now = Self.date(2025, 9, 14, 23, 30) // Sunday, last day of a Mon-first week
        let window = PersonalDataRange.eventWindow(for: .this_week, now: now, calendar: calendar)

        #expect(window.start == Self.date(2025, 9, 8, 0, 0))
        #expect(window.end == Self.date(2025, 9, 15, 0, 0))
        #expect(window.contains(now))
    }

    @Test("next week begins exactly where this week ends")
    func nextWeekAbuts() {
        for firstWeekday in 1...7 {
            let calendar = Self.calendar(firstWeekday: firstWeekday)
            let now = Self.date(2025, 9, 10, 12, 0)
            let this = PersonalDataRange.eventWindow(for: .this_week, now: now, calendar: calendar)
            let next = PersonalDataRange.eventWindow(for: .next_week, now: now, calendar: calendar)

            #expect(this.end == next.start, "first weekday \(firstWeekday)")
            #expect(next.duration == this.duration, "first weekday \(firstWeekday)")
            #expect(next.contains(now) == false, "first weekday \(firstWeekday)")
        }
    }

    @Test("a week spanning new year keeps counting weekdays, not months")
    func weekAcrossNewYear() {
        // Wednesday 31 December 2025.
        let now = Self.date(2025, 12, 31, 10, 0)

        let monday = PersonalDataRange.eventWindow(for: .this_week, now: now, calendar: Self.calendar(firstWeekday: 2))
        #expect(monday.start == Self.date(2025, 12, 29, 0, 0))
        #expect(monday.end == Self.date(2026, 1, 5, 0, 0))

        let sunday = PersonalDataRange.eventWindow(for: .this_week, now: now, calendar: Self.calendar(firstWeekday: 1))
        #expect(sunday.start == Self.date(2025, 12, 28, 0, 0))
        #expect(sunday.end == Self.date(2026, 1, 4, 0, 0))

        let next = PersonalDataRange.eventWindow(for: .next_week, now: now, calendar: Self.calendar(firstWeekday: 2))
        #expect(next.start == Self.date(2026, 1, 5, 0, 0))
        #expect(next.end == Self.date(2026, 1, 12, 0, 0))
    }

    // MARK: - Daylight saving

    @Test("a spring-forward day is 23 hours long, not 24")
    func springForwardDay() {
        // Europe/London moves to BST at 01:00 on Sunday 30 March 2025.
        let calendar = Self.calendar(firstWeekday: 2, zone: Self.london)
        let now = Self.date(2025, 3, 30, 12, 0, zone: Self.london)
        let window = PersonalDataRange.eventWindow(for: .today, now: now, calendar: calendar)

        let expected: TimeInterval = 23 * 60 * 60
        #expect(window.duration == expected)
        #expect(window.start == Self.date(2025, 3, 30, 0, 0, zone: Self.london))
        #expect(window.contains(now))
    }

    @Test("an autumn week is 169 hours long, and still ends on a midnight")
    func fallBackWeek() {
        // Clocks go back at 02:00 on Sunday 26 October 2025.
        let calendar = Self.calendar(firstWeekday: 2, zone: Self.london)
        let now = Self.date(2025, 10, 22, 12, 0, zone: Self.london)
        let window = PersonalDataRange.eventWindow(for: .this_week, now: now, calendar: calendar)

        let expected: TimeInterval = 169 * 60 * 60
        #expect(window.duration == expected)
        #expect(window.start == Self.date(2025, 10, 20, 0, 0, zone: Self.london))
        #expect(window.end == Self.date(2025, 10, 27, 0, 0, zone: Self.london))
    }

    @Test("a spring-forward week is 167 hours, so seven days is not seven times 86400")
    func springForwardWeek() {
        let calendar = Self.calendar(firstWeekday: 2, zone: Self.london)
        let now = Self.date(2025, 3, 26, 12, 0, zone: Self.london)
        let window = PersonalDataRange.eventWindow(for: .this_week, now: now, calendar: calendar)

        let expected: TimeInterval = 167 * 60 * 60
        #expect(window.duration == expected)
        let sevenFlatDays: TimeInterval = 7 * 86_400
        #expect(window.duration != sevenFlatDays)
        #expect(window.end == Self.date(2025, 3, 31, 0, 0, zone: Self.london))
    }

    // MARK: - Reminder windows

    @Test("overdue is open at the bottom and closes at this instant")
    func overdue() {
        let now = Self.date(2025, 9, 11, 14, 37)
        let window = PersonalDataRange.reminderWindow(for: .overdue, now: now, calendar: Self.calendar(firstWeekday: 2))

        #expect(window.start == nil)
        #expect(window.end == now)
        #expect(window.contains(Self.date(2019, 1, 1)))
        #expect(window.contains(now) == false)
        #expect(window.isUnbounded == false)
    }

    @Test("all_open is unbounded at both ends, which is what EventKit needs to include undated reminders")
    func allOpen() {
        let window = PersonalDataRange.reminderWindow(
            for: .all_open, now: Self.date(2025, 9, 11), calendar: Self.calendar(firstWeekday: 2)
        )
        #expect(window.isUnbounded)
        #expect(window.contains(Self.date(1970, 1, 1)))
        #expect(window.contains(Self.date(2999, 1, 1)))
    }

    @Test("dated reminder filters resolve to the same days the calendar tool uses")
    func reminderDaysMatchCalendarDays() {
        let calendar = Self.calendar(firstWeekday: 2)
        let now = Self.date(2025, 9, 10, 12, 0)

        for (filter, range) in [
            (ReminderFilter.today, CalendarRange.today),
            (.tomorrow, .tomorrow),
            (.this_week, .this_week)
        ] {
            let reminders = PersonalDataRange.reminderWindow(for: filter, now: now, calendar: calendar)
            let events = PersonalDataRange.eventWindow(for: range, now: now, calendar: calendar)
            #expect(reminders.start == events.start, "\(filter)")
            #expect(reminders.end == events.end, "\(filter)")
        }
    }

    // MARK: - The schema contract

    @Test("the accepted range names are exactly what the tool schema advertises")
    func rangeNames() {
        // The @ToolArguments macro emits `CalendarRange.allCases.map { $0.rawValue }`
        // straight into the JSON schema the model is shown, so these strings
        // are not an implementation detail — they are the tool's public API,
        // and renaming a case silently changes the prompt.
        #expect(CalendarRange.allCases.map(\.rawValue) == ["today", "tomorrow", "this_week", "next_week"])
        #expect(ReminderFilter.allCases.map(\.rawValue) == ["overdue", "today", "tomorrow", "this_week", "all_open"])
    }

    @Test("every range name decodes from the JSON a model emits")
    func decodesFromModelOutput() throws {
        // The model returns arguments as JSON; a case the decoder rejects is a
        // dead tool call.
        for raw in CalendarRange.allCases.map(\.rawValue) {
            let decoded = try JSONDecoder().decode(CalendarRange.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded.rawValue == raw)
        }
        #expect((try? JSONDecoder().decode(CalendarRange.self, from: Data("\"last_week\"".utf8))) == nil)
    }

    // MARK: - Empty is not the same as denied

    @Test("an empty result says so, in words the model can repeat")
    func emptyTextIsASentence() {
        for range in CalendarRange.allCases {
            #expect(range.emptyText.hasSuffix("."))
            #expect(range.emptyText.contains("event"))
        }
        for filter in ReminderFilter.allCases {
            #expect(filter.emptyText.hasSuffix("."))
        }
        #expect(CalendarRange.today.emptyText != CalendarRange.tomorrow.emptyText)
        #expect(ReminderFilter.overdue.emptyText != ReminderFilter.all_open.emptyText)
    }

    @Test("nothing found and not allowed to look are never the same sentence")
    func emptyIsDistinguishableFromDenied() {
        // The whole point. A model told "no events" invents nothing; a model
        // handed an empty list because permission was refused confabulates a
        // day's meetings, and the user has no way to tell.
        var refusals: Set<String> = []
        for entity in PersonalDataEntity.allCases {
            for authorization in PersonalDataAuthorization.allCases where !authorization.canRead {
                refusals.insert(authorization.explanation(for: entity))
            }
        }
        let empties = Set(
            CalendarRange.allCases.map(\.emptyText) + ReminderFilter.allCases.map(\.emptyText)
        )

        #expect(refusals.isDisjoint(with: empties))
        // Every refusal names the app, so the user knows who is asking; no
        // empty result does, so the two cannot be confused at a glance either.
        #expect(refusals.allSatisfy { $0.contains("Pocketd") })
        #expect(empties.allSatisfy { !$0.contains("Pocketd") })
    }

    // MARK: - Authorization

    @Test("write-only is not a read grant")
    func writeOnlyCannotRead() {
        // iOS 17 split calendar access in two. "Add Only Access" satisfies any
        // check for "not denied" and reads nothing at all.
        #expect(PersonalDataAuthorization.writeOnly.canRead == false)
        #expect(PersonalDataAuthorization.notDetermined.canRead == false)
        #expect(PersonalDataAuthorization.denied.canRead == false)
        #expect(PersonalDataAuthorization.restricted.canRead == false)
        #expect(PersonalDataAuthorization.granted.canRead)
    }

    @Test("each refusal points at the screen that actually has the switch")
    func refusalsAreActionable() {
        let denied = PersonalDataAuthorization.denied.explanation(for: .calendar)
        #expect(denied.contains("Privacy & Security > Calendars"))

        let remindersDenied = PersonalDataAuthorization.denied.explanation(for: .reminders)
        #expect(remindersDenied.contains("Privacy & Security > Reminders"))

        // Restricted is the one state the user cannot fix in Settings; saying
        // "turn it on in Settings" there is a wild goose chase.
        let restricted = PersonalDataAuthorization.restricted.explanation(for: .calendar)
        #expect(restricted.contains("Settings >") == false)
        #expect(restricted.contains("restricted"))

        #expect(PersonalDataAuthorization.writeOnly.explanation(for: .calendar).contains("Full Access"))
    }

    @Test("the four refusals are four different sentences")
    func refusalsAreDistinct() {
        let sentences = PersonalDataAuthorization.allCases
            .filter { !$0.canRead }
            .map { $0.explanation(for: .calendar) }
        #expect(Set(sentences).count == sentences.count)
    }

    // MARK: - Formatting

    @Test("a timed moment carries a clock time and a whole day does not")
    func momentVersusDay() {
        let locale = Locale(identifier: "en_GB")
        let start = Self.date(2025, 9, 11, 14, 30)
        let later = Self.date(2025, 9, 11, 16, 45)

        let moment = PersonalDataFormat.moment(start, locale: locale, timeZone: Self.utc)
        let sameDay = PersonalDataFormat.day(start, locale: locale, timeZone: Self.utc)

        // Locale-proof: two times on one day are two different moments and one
        // single day.
        #expect(moment != PersonalDataFormat.moment(later, locale: locale, timeZone: Self.utc))
        #expect(sameDay == PersonalDataFormat.day(later, locale: locale, timeZone: Self.utc))
        #expect(moment.contains("30"))
        #expect(sameDay.contains("30") == false)
        #expect(moment.contains("11"))
        #expect(sameDay.contains("11"))
    }

    @Test("formatting is done in the user's zone, not UTC")
    func formattingHonoursTimeZone() {
        // A Date is an instant; the only reason to format it here rather than
        // let JSONSerialization stringify it is that this is where the user's
        // zone is known. If that stopped working these two would agree.
        let locale = Locale(identifier: "en_GB")
        let instant = Self.date(2025, 9, 11, 23, 30, zone: Self.utc)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        #expect(
            PersonalDataFormat.moment(instant, locale: locale, timeZone: Self.utc)
            != PersonalDataFormat.moment(instant, locale: locale, timeZone: tokyo)
        )
        // Half past eleven at night in London is the following morning in Tokyo.
        #expect(PersonalDataFormat.day(instant, locale: locale, timeZone: tokyo).contains("12"))
    }

    @Test("no formatted date is empty, in any locale the tool might meet")
    func formattingNeverEmpty() {
        let instant = Self.date(2025, 9, 11, 14, 30)
        for identifier in ["en_US", "en_GB", "de_DE", "ja_JP", "ar_SA", "hi_IN"] {
            let locale = Locale(identifier: identifier)
            #expect(PersonalDataFormat.moment(instant, locale: locale, timeZone: Self.utc).isEmpty == false)
            #expect(PersonalDataFormat.day(instant, locale: locale, timeZone: Self.utc).isEmpty == false)
        }
    }
}
