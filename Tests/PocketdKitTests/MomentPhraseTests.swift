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

    /// Resolved against the real clock and the real calendar.
    ///
    /// `NSDataDetector` anchors relative phrases to the SYSTEM time zone and
    /// offers no way to inject one, so a fixture calendar in Europe/London and
    /// a machine in another zone disagree by the offset — which looks exactly
    /// like a parsing bug and is not one. Anything that reaches the detector is
    /// therefore asserted on the hour, against `.current`, never on an absolute
    /// date.
    private func live(_ phrase: String) -> MomentPhrase.Resolution {
        MomentPhrase.resolve(phrase, now: Date(), calendar: .current)
    }

    @Test("a repeating phrase becomes a pattern and a first occurrence")
    func recurrenceIsRead() {
        // NSDataDetector reads "every day at 7am" as *today* at 7am: one
        // reminder, no repetition, no error — so the user asked for a daily
        // reminder, watched the app agree, and found out on the second morning.
        // The pattern is pulled out first and the rest resolved as an ordinary
        // time, which is why "at 7am" still gets the roll-forward and the
        // refusal to guess that every other phrase does.
        let expected: [(String, ReminderRepeat, Int)] = [
            ("every day at 7am", .daily, 7),
            ("each day at 9am", .daily, 9),
            ("daily at 9am", .daily, 9),
            ("every weekday at 8am", .weekdays, 8),
            ("every week at 10am", .weekly, 10),
            ("weekly at 10am", .weekly, 10),
            ("every month at 11am", .monthly, 11),
            ("every year at 6pm", .yearly, 18),
            // The shapes NSDataDetector returns NO MATCH for — a bare hour with
            // no am or pm. Left to it, "daily at 9" would be refused, which is
            // among the commonest ways anybody asks for this.
            ("every morning at 7", .daily, 7),
            ("every evening at 9", .daily, 21)
        ]
        for (phrase, pattern, hour) in expected {
            guard case let .repeating(read, first, hasTime) = live(phrase) else {
                Issue.record("\(phrase) did not resolve to a pattern"); continue
            }
            #expect(read == pattern, "\(phrase)")
            #expect(hasTime, "\(phrase)")
            #expect(Calendar.current.component(.hour, from: first) == hour, "\(phrase)")
        }
    }

    @Test("a bare hour with no am or pm takes the next one round")
    func bareHours() {
        // The detector matches "at 7am" and returns nothing at all for "at 9",
        // so without this the feature works in the morning and not after lunch.
        // Deterministic because `bareClockTime` uses the calendar it is given
        // rather than the detector's system zone.
        let nineAM = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 0))!
        // 01:45, so the next nine o'clock is this morning.
        guard case let .moment(morning, _) = resolve("at 9") else {
            Issue.record("at 9 did not resolve"); return
        }
        #expect(morning == nineAM)

        // From half past nine in the morning, the next one is half nine at night.
        let lateMorning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 30))!
        guard case let .moment(evening, _) = MomentPhrase.resolve("at 9", now: lateMorning, calendar: calendar, detector: { _ in nil }) else {
            Issue.record("did not resolve"); return
        }
        #expect(parts(evening).hour == 21)

        // An explicit 24-hour clock is never second-guessed.
        guard case let .moment(exact, _) = resolve("17:30") else {
            Issue.record("17:30 did not resolve"); return
        }
        #expect(parts(exact).hour == 17 && parts(exact).minute == 30)
    }

    @Test("every Tuesday is weekly, and the weekday survives to place the first one")
    func namedWeekdayRepeats() {
        // "Tuesday" is stripped from the pattern's point of view and kept from
        // the date's: weekly says how often, and the word is the only thing
        // that says which Tuesday.
        guard case let .repeating(pattern, first, _) = live("every Tuesday at 6pm") else {
            Issue.record("did not resolve"); return
        }
        #expect(pattern == .weekly)
        #expect(Calendar.current.component(.hour, from: first) == 18)
        #expect(Calendar.current.component(.weekday, from: first) == 3, "should land on a Tuesday")
    }

    @Test("a repeating phrase with no readable pattern or no time is still refused")
    func unreadableRecurrenceIsRefused() {
        // The half of the old blanket refusal that was doing real work. Filing
        // one reminder for something asked for "every so often" is the failure
        // this whole area exists to avoid, and "every day" with no hour in it
        // is half a reminder rather than a daily one.
        //
        // "every morning" is here rather than resolving to nine o'clock. The
        // detector would happily read "Monday morning" as 09:00, and adopting
        // that convention for a repeating alarm is exactly the invented hour
        // this file refuses everywhere else.
        for phrase in ["every so often", "every now and then", "every day", "every weekday", "every morning", "repeat", "always"] {
            #expect(live(phrase) == .recurring, "\(phrase)")
        }
    }

    @Test("recurrence is read before anything else can resolve it")
    func recurrenceBeatsAWorkingParse() {
        // The ordering is the test. "in 2 hours" parses on its own, and "every
        // day in 2 hours" must not quietly become a single reminder.
        guard case let .repeating(pattern, _, _) = resolve("every day in 2 hours") else {
            Issue.record("did not resolve to a pattern"); return
        }
        #expect(pattern == .daily)
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
            case .recurring, .repeating:
                Issue.record("\(phrase) is not a repeating phrase")
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
