import Foundation
import Testing
@testable import PocketdKit

/// Three prompts per user per year is Apple's ceiling and the system swallows
/// the rest silently, so every rule here is really about not spending one.
@Suite("Review moments")
struct ReviewMomentTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12))!
    }

    private func ask(_ state: ReviewMoment.State, on day: Int) -> Bool {
        ReviewMoment.shouldAsk(state, now: date(day), calendar: calendar)
    }

    @Test("asks once the app has done its job a few times, after a couple of days")
    func theHappyMoment() {
        let state = ReviewMoment.State(firstLaunch: date(1), toolBackedAnswers: 3)
        #expect(ask(state, on: 5))
    }

    @Test("one good answer is not enough")
    func notAfterOne() {
        // The first tool-backed answer is usually somebody checking whether it
        // works at all, rather than getting value out of it.
        for answers in 0...2 {
            let state = ReviewMoment.State(firstLaunch: date(1), toolBackedAnswers: answers)
            #expect(!ask(state, on: 9), "asked after \(answers)")
        }
    }

    @Test("never on the first day, however well it went")
    func notOnDayOne() {
        // A prompt on day one reads as a shakedown. The person in the app on
        // day one is still deciding whether to keep it.
        let keen = ReviewMoment.State(firstLaunch: date(1), toolBackedAnswers: 20)
        #expect(!ask(keen, on: 1))
        #expect(!ask(keen, on: 2))
        #expect(ask(keen, on: 3))
    }

    @Test("an install from before this code existed is not asked")
    func missingFirstLaunchFailsClosed() {
        // Nothing recorded means we cannot tell whether this is their first
        // day, so we wait for the next answer rather than guess.
        let unknown = ReviewMoment.State(firstLaunch: nil, toolBackedAnswers: 50)
        #expect(!ask(unknown, on: 30))
    }

    @Test("somebody who has already been asked is left alone for months")
    func coolingOff() {
        // Apple allows three a year and we intend to use about one. If they
        // liked it enough to rate it they already did, and if they did not,
        // asking again in a fortnight is the behaviour that earns a one-star.
        let asked = ReviewMoment.State(firstLaunch: date(1), toolBackedAnswers: 40, lastAsked: date(10))
        #expect(!ask(asked, on: 30))
        #expect(!ask(asked, on: 100))
        // 120 days after the 10th of September is the 8th of January.
        let later = ReviewMoment.shouldAsk(
            asked,
            now: calendar.date(from: DateComponents(year: 2027, month: 1, day: 9, hour: 12))!,
            calendar: calendar
        )
        #expect(later)
    }

    @Test("a clock moved backwards does not open the gate")
    func clockGoingBackwards() {
        // A negative gap compared against a signed threshold would read as
        // "long enough ago". Both windows are clamped at zero.
        let state = ReviewMoment.State(firstLaunch: date(20), toolBackedAnswers: 10, lastAsked: date(20))
        #expect(!ask(state, on: 2))
        #expect(ReviewMoment.days(from: date(20), to: date(2), calendar: calendar) == 0)
    }

    @Test("the gates are counted in calendar days, not in 86,400-second units")
    func daysAreCalendarDays() {
        // Same reasoning as MomentPhrase's roll-forward: Britain's clocks make
        // a day 23 or 25 hours twice a year, and a threshold measured in
        // seconds drifts across them.
        var british = Calendar(identifier: .gregorian)
        british.timeZone = TimeZone(identifier: "Europe/London")!
        let before = british.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 12))!
        let after = british.date(from: DateComponents(year: 2026, month: 3, day: 30, hour: 12))!
        #expect(ReviewMoment.days(from: before, to: after, calendar: british) == 2)
    }
}
