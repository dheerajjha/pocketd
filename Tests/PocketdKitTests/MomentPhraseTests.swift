import Foundation
import Testing
@testable import PocketdKit

/// The half of "set me a reminder" that decides whether it is useful or a lie.
///
/// A reminder at the wrong hour is worse than no reminder, because the user
/// believes it is set and stops holding the thing in their head. So the bar
/// these tests hold the parser to is not "gets the common cases right" — it is
/// "is never confidently wrong", and most of what is below is the second one.
@Suite("Moment phrases")
struct MomentPhraseTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    /// Sunday 14 September 2026, 01:45 — the clock in the screenshot that
    /// started this feature.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 1, minute: 45))!
    }

    private func resolve(_ phrase: String, stub: Date? = nil) -> MomentPhrase.Resolution {
        MomentPhrase.resolve(phrase, now: now, calendar: calendar, detector: { _ in stub })
    }

    private func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    // MARK: - The refusal that matters most

    @Test("a repeating phrase is refused, never flattened to one occurrence")
    func recurrenceIsRefused() {
        // NSDataDetector reads "every day at 7am" as *today* at 7am: one
        // reminder, no repetition, and no error anywhere. The user asked for a
        // daily reminder, watched the app agree, and finds out on the second
        // morning. Refusing is a worse demo and an honest one.
        for phrase in [
            "every day at 7am",
            "each morning",
            "daily at 9",
            "every Tuesday at 6pm",
            "repeat weekly",
            "every weekday at 8"
        ] {
            #expect(resolve(phrase, stub: now) == .recurring, "\(phrase)")
        }
    }

    @Test("recurrence is checked before anything else can resolve it")
    func recurrenceBeatsAWorkingParse() {
        // The ordering is the test. "in 2 hours" parses, and "every day in 2
        // hours" must still be refused rather than quietly becoming one.
        #expect(resolve("every day in 2 hours") == .recurring)
    }

    // MARK: - The silently-wrong class

    @Test("a phrase whose time was dropped is unresolved, never the fallback hour")
    func droppedTimeIsCaught() {
        // The real failure: NSDataDetector matches "tomorrow", silently throws
        // away "half past four", and returns noon. Run against the REAL
        // detector because a stub would be testing the stub.
        //
        // Asserted as an invariant rather than as an expected value, so that a
        // future iOS whose detector handles this correctly makes the test
        // pass better rather than fail. What can never happen is noon.
        for phrase in ["half past four tomorrow", "quarter to six tomorrow"] {
            let resolution = MomentPhrase.resolve(phrase, now: now, calendar: calendar)
            switch resolution {
            case .unresolved:
                break // correct: it asks rather than guesses
            case let .moment(date, _):
                let hour = parts(date).hour
                #expect(hour != 12 && hour != 0, "\(phrase) silently became the fallback hour")
            case .recurring:
                Issue.record("\(phrase) is not recurring")
            }
        }
    }

    @Test("an ordinary day word still resolves — the tripwire is not a blanket refusal")
    func theTripwireDoesNotOverreach() {
        // A guard that rejected anything with a clock word in it would reject
        // "tomorrow morning", which is fine, and the feature would be useless
        // in a different direction.
        #expect(MomentPhrase.mentionsTimeBeyond(now, in: "tomorrow morning", calendar: calendar) == false)
        #expect(MomentPhrase.mentionsTimeBeyond(now, in: "tomorrow", calendar: calendar) == false)
    }

    // MARK: - Shapes the detector cannot do

    @Test("in N minutes, which the detector does not match at all")
    func relativeOffsets() {
        // Verified directly: NSDataDetector returns no match for "in 20
        // minutes". Left to it, one of the most common ways anybody asks for a
        // short reminder would simply fail.
        guard case let .moment(date, hasTime) = resolve("in 20 minutes") else {
            Issue.record("in 20 minutes did not resolve"); return
        }
        #expect(hasTime)
        #expect(parts(date).hour == 2)
        #expect(parts(date).minute == 5)

        guard case let .moment(later, _) = resolve("in 2 hours") else {
            Issue.record("in 2 hours did not resolve"); return
        }
        #expect(parts(later).hour == 3)
        #expect(parts(later).minute == 45)
    }

    @Test("a nonsense amount does not become a reminder")
    func relativeRejectsRubbish() {
        #expect(resolve("in zero minutes") == .unresolved)
        #expect(resolve("in -5 minutes") == .unresolved)
        #expect(resolve("in 20 bananas") == .unresolved)
    }

    @Test("a well-formed ISO string is honoured rather than second-guessed")
    func isoIsAccepted() {
        guard case let .moment(date, hasTime) = resolve("2026-09-14T02:00:00") else {
            Issue.record("ISO did not resolve"); return
        }
        #expect(hasTime)
        #expect(parts(date).hour == 2)
        #expect(parts(date).day == 14)
    }

    @Test("something ISO-shaped and impossible does not become a date")
    func isoRejectsImpossible() {
        // The exact failure `CalendarRange` was written to avoid: a small model
        // emitting a month of 13.
        #expect(resolve("2025-13-01T00:00:00") == .unresolved)
    }

    // MARK: - Times already gone

    @Test("a bare time already past today means the next one")
    func bareTimeRollsForward() {
        // Said at 01:45, "at 1" means one o'clock tomorrow, which is what every
        // clock app on the phone does.
        let onePM = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 1, minute: 0))!
        guard case let .moment(date, _) = resolve("at 1", stub: onePM) else {
            Issue.record("did not resolve"); return
        }
        #expect(parts(date).day == 15)
        #expect(parts(date).hour == 1)
    }

    @Test("a named day is owed the day it named, even in the past")
    func anExplicitDayIsNotMoved() {
        // "2am today" said at 3am means 2am today. An overdue reminder is a
        // real and useful thing; a silently moved one is not.
        let twoAM = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 0, minute: 30))!
        guard case let .moment(date, _) = resolve("00:30 today", stub: twoAM) else {
            Issue.record("did not resolve"); return
        }
        #expect(parts(date).day == 14, "a named day must not be rolled forward")
        #expect(parts(date).hour == 0)
    }

    @Test("rolling forward moves by calendar days, not by 86,400 seconds")
    func rollForwardSurvivesDaylightSaving() {
        // Britain's clocks go forward at 01:00 on 29 March 2026, making that
        // day 23 hours long. Noon is the hour that shows it: adding a calendar
        // day keeps the wall clock at 12:00, adding 86,400 seconds lands at
        // 13:00 and the reminder goes off an hour late.
        //
        // Deliberately not 01:30, which is what this test used first and which
        // proved nothing: 01:30 falls inside the gap, does not exist on the
        // 29th, and both methods resolve it to 02:30. A case where the two
        // agree cannot tell them apart.
        var springCalendar = Calendar(identifier: .gregorian)
        springCalendar.timeZone = TimeZone(identifier: "Europe/London")!
        let noon = springCalendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 12, minute: 0))!
        let justAfter = noon.addingTimeInterval(60)

        let rolled = MomentPhrase.rollForwardIfBareTimeIsPast(noon, phrase: "at 12", now: justAfter, calendar: springCalendar)
        let wall = springCalendar.dateComponents([.day, .hour, .minute], from: rolled)
        #expect(wall.day == 29)
        #expect(wall.hour == 12 && wall.minute == 0, "landed at \(wall.hour ?? -1):\(wall.minute ?? -1)")

        // And the arithmetic this is avoiding, so the test says what it defends.
        let naive = springCalendar.dateComponents([.hour], from: noon.addingTimeInterval(86_400))
        #expect(naive.hour == 13, "the naive version should be the wrong one")
    }

    // MARK: - Nothing in, nothing out

    @Test("nothing dependable means unresolved, never a default")
    func nothingBecomesNothing() {
        for phrase in ["", "   ", "later", "soon", "sometime", "banana", "when I get round to it"] {
            #expect(resolve(phrase) == .unresolved, "\(phrase)")
        }
    }

    @Test("the apostrophe an iPhone actually types")
    func curlyApostrophe() {
        // U+2019, the same trap `ToolOffer` documents. The user's own words are
        // what the model relays, and they come off an iOS keyboard.
        #expect(MomentPhrase.normalise("tomorrow at 5 o\u{2019}clock").contains("o'clock"))
    }

    // MARK: - The real detector, on the sentence that started this

    @Test("the question from the screenshot resolves to two in the morning")
    func theMotivatingPhrase() {
        // Run against the real `NSDataDetector` with the real clock, because
        // this is the end-to-end claim. Asserted on the hour rather than on an
        // absolute date so the test does not depend on when it runs.
        let rightNow = Date()
        guard case let .moment(date, hasTime) = MomentPhrase.resolve("2 AM today", now: rightNow, calendar: .current) else {
            Issue.record("'2 AM today' did not resolve"); return
        }
        #expect(hasTime)
        var current = Calendar.current
        current.timeZone = .current
        #expect(current.component(.hour, from: date) == 2)
        #expect(current.isDate(date, inSameDayAs: rightNow), "'today' must mean today")
    }

    @Test("tomorrow at three in the afternoon, end to end")
    func tomorrowAfternoon() {
        let rightNow = Date()
        guard case let .moment(date, _) = MomentPhrase.resolve("tomorrow at 3pm", now: rightNow, calendar: .current) else {
            Issue.record("did not resolve"); return
        }
        let current = Calendar.current
        #expect(current.component(.hour, from: date) == 15)
        let tomorrow = current.date(byAdding: .day, value: 1, to: rightNow)!
        #expect(current.isDate(date, inSameDayAs: tomorrow))
    }
}
