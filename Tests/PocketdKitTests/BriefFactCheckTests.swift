import Foundation
import Testing
@testable import PocketdKit

/// A brain's brief may say nothing numeric that is not a fact of the day.
///
/// The cases are the ones QA photographed above tiles that said otherwise:
/// tomorrow's design review written into a sentence about this afternoon, a
/// sleep gap of "1 hour and 25 minutes" that was 29, "1,980 fewer steps" beside
/// an Activity tile reading Ahead, and "p.m." beside "4:30 PM" everywhere else.
/// The template is never checked; it is assembled from the facts.
@Suite("Brief fact check")
struct BriefFactCheckTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let us = Locale(identifier: "en_US")

    /// Wednesday 21 October 2026; tomorrow is Thursday.
    static func date(_ hour: Int, _ minute: Int = 0, day: Int = 21) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// The seeded demo day.
    static func demo(now: Date) -> TodaySnapshot {
        TodaySnapshot(
            generatedAt: now,
            calendar: .connected,
            reminders: .connected,
            health: .connected,
            events: [
                BriefEvent(title: "Standup", start: date(9, 30), end: date(9, 45)),
                BriefEvent(title: "Lunch at The Arches", start: date(13), end: date(14), location: "The Arches"),
                BriefEvent(title: "Dentist", start: date(16, 30), end: date(17, 15)),
                BriefEvent(title: "Design review", start: date(10, day: 22), end: date(11, day: 22)),
                BriefEvent(title: "Yoga", start: date(18, 30, day: 22), end: date(20, day: 22)),
            ],
            dueToday: [
                BriefReminder(title: "Call the dentist", due: date(16), dueHasTime: true),
                BriefReminder(title: "Call the plumber", due: date(17), dueHasTime: true),
            ],
            overdue: [BriefReminder(title: "Submit expenses", due: date(18, day: 20), dueHasTime: true)],
            sleepLastNight: 6 * 3600 + 36 * 60,
            sleepUsual: 7 * 3600 + 5 * 60,
            stepsToday: 4_120,
            stepsUsual: 6_100,
            stepsUsualByNow: 1_187,
            eventsCoverWholeDay: true
        )
    }

    static func check(_ text: String, at now: Date, snapshot: TodaySnapshot? = nil, locale: Locale = us) -> String? {
        plain(BriefPrompt.screened(
            text,
            facts: BriefFacts(snapshot: snapshot ?? demo(now: now), now: now, calendar: calendar, locale: locale)
        ))
    }

    // MARK: - Times, and the day they are on

    @Test("tomorrow's design review written into an afternoon sentence is refused")
    func tomorrowEventWithoutTomorrow() {
        // QA, 3:12 PM, two rewrites out of two.
        #expect(Self.check(
            "Good afternoon, Sam. You have a dentist appointment at 4:30 p.m. today and a design review at 10:00 a.m.",
            at: Self.date(15, 12)
        ) == nil)
    }

    @Test("the same brief, saying tomorrow, is kept and put into the app's format")
    func tomorrowSaidIsKept() {
        let text = "Good afternoon, Sam. You have a dentist appointment at 4:30 p.m. today. Tomorrow, there is a design review at 10:00 a.m. and yoga at 6:30 p.m."
        #expect(Self.check(text, at: Self.date(15, 12))
            == "Good afternoon, Sam. You have a dentist appointment at 4:30 PM today. Tomorrow, there is a design review at 10:00 AM and yoga at 6:30 PM.")
    }

    @Test("tomorrow can come after the time, or as the weekday")
    func otherWaysOfSayingTomorrow() {
        let afternoon = Self.date(15)
        #expect(Self.check("Good afternoon. At 10:00 AM you have a design review tomorrow.", at: afternoon) != nil)
        #expect(Self.check("Good afternoon. On Thursday there is a design review at 10:00 AM.", at: afternoon) != nil)
        #expect(Self.check(
            "Good afternoon. The dentist is at 4:30 PM, and tomorrow starts with a design review at 10:00 AM.", at: afternoon
        ) != nil)
        // And a today item is not moved to tomorrow.
        #expect(Self.check("Good afternoon. Tomorrow you have the dentist at 4:30 PM.", at: afternoon) == nil)
    }

    @Test("a time that is no event's or reminder's is refused, including the clock")
    func timesMustBeFacts() {
        #expect(Self.check("Good morning, Sam. It is 9:41 AM.", at: Self.date(9, 41)) == nil)
        #expect(Self.check("Good morning, Sam. Lunch is at 12:30 PM.", at: Self.date(9, 41)) == nil)
    }

    @Test("an event already under way is not a time a brief may give")
    func eventUnderWayIsNotAFact() {
        // 1:45 PM, lunch from 1:00 to 2:00: "at 1:00 PM" reads as still to come.
        #expect(Self.check("Good afternoon, Sam. You have lunch at 1:00 PM at The Arches.", at: Self.date(13, 45)) == nil)
        #expect(Self.check("Good afternoon, Sam. The dentist is at 4:30 PM.", at: Self.date(13, 45)) == "Good afternoon, Sam. The dentist is at 4:30 PM.")
    }

    @Test("times without AM or PM, or in words for the half of the day, still match and are tidied")
    func looseTimes() {
        #expect(Self.check("Good afternoon. The dentist is at 4:30 in the afternoon.", at: Self.date(14))
            == "Good afternoon. The dentist is at 4:30 PM.")
        #expect(Self.check("Good afternoon. The dentist is at 4:30.", at: Self.date(14))
            == "Good afternoon. The dentist is at 4:30 PM.")
        #expect(Self.check("Good morning. Lunch is at 1pm.", at: Self.date(9))
            == "Good morning. Lunch is at 1:00 PM.")
    }

    @Test("a phone on the 24-hour clock gets 24-hour times")
    func twentyFourHour() {
        #expect(Self.check("Good afternoon. The dentist is at 4:30 p.m.", at: Self.date(14), locale: Locale(identifier: "en_GB"))
            == "Good afternoon. The dentist is at 16:30.")
    }

    // MARK: - Lengths of time

    @Test("a sleep gap the brain worked out wrong is refused")
    func wrongSleepGap() {
        // QA, Health only: the true gap is 29 minutes.
        var health = Self.demo(now: Self.date(9, 41))
        health.calendar = .off
        health.reminders = .off
        #expect(Self.check(
            "Good morning, Samira. You slept for 6 hours and 36 minutes, which is 1 hour and 25 minutes less than your usual 7 hours and 5 minutes. You took 4,120 steps, which is 1,980 fewer steps than your usual 6,100.",
            at: Self.date(9, 41), snapshot: health
        ) == nil)
    }

    @Test("the right gap is kept, and every length is put into the app's format")
    func rightSleepGap() {
        #expect(Self.check(
            "Good morning. You slept 6 hours and 36 minutes, 29 minutes less than your usual 7 hours and 5 minutes.",
            at: Self.date(9, 41)
        ) == "Good morning. You slept 6h 36m, 29 min less than your usual 7h 5m.")
    }

    // MARK: - Numbers

    @Test("a step difference nobody was given is refused; the figures it was given are kept")
    func stepNumbers() {
        #expect(Self.check("Good morning. You have taken 4,120 steps, which is 1,980 fewer than usual.", at: Self.date(9, 41)) == nil)
        #expect(Self.check(
            "Good morning. You have taken 4120 steps, ahead of the 1,187 you usually have by now.", at: Self.date(9, 41)
        ) == "Good morning. You have taken 4,120 steps, ahead of the 1,187 you usually have by now.")
    }

    @Test("a number before a comma is checked like any other")
    func numberBeforeAComma() {
        // Seen on the simulator: "4120," went through unchecked and unformatted.
        #expect(Self.check(
            "Good morning. The number of steps you took was 4120, compared to your usual 1,187 by this time.", at: Self.date(9, 41)
        ) == "Good morning. The number of steps you took was 4,120, compared to your usual 1,187 by this time.")
        #expect(Self.check("Good morning. You took 5000, which is a lot.", at: Self.date(9, 41)) == nil)
    }

    @Test("counts must be the day's counts")
    func counts() {
        let now = Self.date(9, 41)
        #expect(Self.check("Good morning. You have 2 reminders due today and 1 overdue.", at: now) != nil)
        // "Two" is put into digits first, then checked like any other count.
        #expect(Self.check("Good morning. You have two reminders due today and one overdue reminder.", at: now) != nil)
        #expect(Self.check("Good morning. You have 7 reminders due today.", at: now) == nil)
    }

    @Test("a number inside a title may be quoted with it")
    func numbersInTitles() {
        var snapshot = Self.demo(now: Self.date(9))
        snapshot.events = [BriefEvent(title: "Room 101 review", start: Self.date(15), end: Self.date(16))]
        #expect(Self.check("Good morning. Room 101 review is at 3:00 PM.", at: Self.date(9), snapshot: snapshot) != nil)
    }

    @Test("a brief with no numbers at all passes untouched")
    func noNumbers() {
        let text = "Good morning, Sam. Your calendar is clear, and nothing is overdue."
        var snapshot = Self.demo(now: Self.date(9))
        snapshot.overdue = []
        #expect(Self.check(text, at: Self.date(9), snapshot: snapshot) == text)
    }

    @Test("the screen still refuses what it refused before the facts")
    func earlierScreensStillApply() {
        #expect(Self.check("Good morning, Sam. You slept seven hours and ten minutes last night.", at: Self.date(9)) == nil)
        #expect(Self.check("EVENTS 13:00 Lunch at The Arches DUE Call the plumber", at: Self.date(9)) == nil)
    }
}
