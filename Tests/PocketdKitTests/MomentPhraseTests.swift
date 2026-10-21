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
        // Said at 01:45, "at 1:00" — which the detector reads as one in the
        // morning — means one o'clock tomorrow, which is what every clock app
        // on the phone does. (A whole "at 1" never reaches the detector: it is
        // one in the afternoon, by the one-to-six rule.)
        let onePM = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 1, minute: 0))!
        guard case let .moment(date, _) = resolve("at 1:00", stub: onePM) else {
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

    @Test("tomorrow at 9 is nine tomorrow morning, not the detector's noon")
    func tomorrowAtNine() {
        // "Remind me tomorrow at 9 to call the bank". A bare hour beside a day
        // word is the detector's to read, and it reads this one as 09:00.
        let rightNow = Date()
        guard case let .moment(date, hasTime) = MomentPhrase.resolve("tomorrow at 9", now: rightNow, calendar: .current) else {
            Issue.record("did not resolve"); return
        }
        let current = Calendar.current
        #expect(hasTime)
        #expect(current.component(.hour, from: date) == 9)
        #expect(current.isDate(date, inSameDayAs: current.date(byAdding: .day, value: 1, to: rightNow)!))
    }

    @Test("tomorrow 9 and 9 tomorrow are what tomorrow at 9 is, not the detector's noon")
    func tomorrowNineWithoutAt() {
        // "Remind me tomorrow 9 to call the bank". The detector matches only
        // "tomorrow" in "tomorrow 9" and "9 tomorrow" and returns noon, and
        // nothing in either phrase trips the half-past wire. Against the real
        // detector, as `tomorrowAtNine` is, and asserted the same way.
        let rightNow = Date()
        let current = Calendar.current
        let tomorrow = current.date(byAdding: .day, value: 1, to: rightNow)!
        for phrase in ["tomorrow 9", "9 tomorrow", "Tomorrow 9", "tomorrow, 9", "tomorrow 09", "9 tomorrow morning"] {
            guard case let .moment(date, hasTime) = MomentPhrase.resolve(phrase, now: rightNow, calendar: current) else {
                Issue.record("\(phrase) did not resolve"); continue
            }
            #expect(hasTime, "\(phrase)")
            #expect(current.component(.hour, from: date) == 9 && current.component(.minute, from: date) == 0, "\(phrase) landed at \(date)")
            #expect(current.isDate(date, inSameDayAs: tomorrow), "\(phrase) landed on \(date)")
        }
        // The same reading for the other day words and hours.
        for (phrase, hour) in [("tomorrow 21", 21), ("tomorrow evening 7", 19), ("8 tomorrow morning", 8)] {
            guard case let .moment(date, _) = MomentPhrase.resolve(phrase, now: rightNow, calendar: current) else {
                Issue.record("\(phrase) did not resolve"); continue
            }
            #expect(current.component(.hour, from: date) == hour, "\(phrase) landed at \(date)")
            #expect(current.isDate(date, inSameDayAs: tomorrow), "\(phrase) landed on \(date)")
        }
        for (phrase, hour) in [("tonight 8", 20), ("8 tonight", 20), ("today 6", 18)] {
            guard case let .moment(date, _) = MomentPhrase.resolve(phrase, now: rightNow, calendar: current) else {
                Issue.record("\(phrase) did not resolve"); continue
            }
            #expect(current.component(.hour, from: date) == hour, "\(phrase) landed at \(date)")
        }
    }

    @Test("only the bare day-and-hour shape gets its 'at'")
    func whatGetsAnAt() {
        let rewritten: [(String, String)] = [
            ("tomorrow 9", "tomorrow at 9"),
            ("9 tomorrow", "at 9 tomorrow"),
            ("Tomorrow 9", "Tomorrow at 9"),
            ("tomorrow, 9", "tomorrow, at 9"),
            ("tonight 8", "tonight at 8"),
            ("6 today", "at 6 today"),
            ("tomorrow morning 8", "tomorrow morning at 8"),
            ("8 tomorrow morning", "at 8 tomorrow morning"),
            ("tomorrow 0", "tomorrow at 0"),
            ("tomorrow 23", "tomorrow at 23")
        ]
        for (phrase, expected) in rewritten {
            #expect(MomentPhrase.withAtBeforeLoneHour(phrase) == expected, "\(phrase)")
        }
        // Already read right, or not this shape: exactly as they were. A
        // weekday's number can be its date ("Friday 5"), "tomorrow at 8 evening"
        // is read as eight in the morning, and a second number or word is
        // somebody else's sentence.
        for phrase in [
            "tomorrow at 9", "tomorrow 9am", "tomorrow 9 am", "tomorrow 9:30", "tomorrow 9.30", "tomorrow 9 o'clock",
            "Friday 5", "monday 10", "tomorrow 8 evening", "tomorrow 9 9", "today tomorrow 9", "tomorrow 24",
            "tomorrow +9", "tomorrow 900", "tomorrow", "9", "at 9", "in 20 minutes", "every day 9", ""
        ] {
            #expect(MomentPhrase.withAtBeforeLoneHour(phrase) == phrase, "\(phrase)")
        }
    }

    // MARK: - A day and no time

    @Test("tomorrow, Friday and next Monday are dates, never the detector's noon")
    func daysAreDates() {
        // "Remind me to buy milk tomorrow": Apple's model passed "tomorrow",
        // the detector answered noon, and the reminder went off at 12:00 PM.
        // Against the real detector, asserted as the other live tests are.
        let rightNow = Date()
        let current = Calendar.current
        let tomorrow = current.startOfDay(for: current.date(byAdding: .day, value: 1, to: rightNow)!)
        #expect(MomentPhrase.resolve("tomorrow", now: rightNow, calendar: current) == .moment(tomorrow, hasTime: false))
        for (phrase, weekday) in [("Friday", 6), ("on Friday", 6), ("next Monday", 2)] {
            guard case let .moment(date, hasTime) = MomentPhrase.resolve(phrase, now: rightNow, calendar: current) else {
                Issue.record("\(phrase) did not resolve"); continue
            }
            #expect(!hasTime, "\(phrase) has a time")
            #expect(current.component(.weekday, from: date) == weekday, "\(phrase) landed on \(date)")
            #expect(date == current.startOfDay(for: date), "\(phrase) carries a clock time: \(date)")
        }
        // A time that was said still is one.
        guard case let .moment(nine, hasTime) = MomentPhrase.resolve("tomorrow at 9", now: rightNow, calendar: current) else {
            Issue.record("tomorrow at 9 did not resolve"); return
        }
        #expect(hasTime && current.component(.hour, from: nine) == 9)
    }

    @Test("the detector's answer keeps its time only when the words named one")
    func detectorDaysAndTimes() {
        // Monday 14 September 2026, 01:45; the stand-in answers like the real
        // one, with noon for a day it was given no time for.
        let noonTomorrow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12, minute: 0))!
        let tomorrow = calendar.startOfDay(for: noonTomorrow)
        #expect(resolve("tomorrow", stub: noonTomorrow) == .moment(tomorrow, hasTime: false))
        #expect(resolve("tomorrow at noon", stub: noonTomorrow) == .moment(noonTomorrow, hasTime: true))
        let nineTomorrow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 9, minute: 0))!
        #expect(resolve("tomorrow morning", stub: nineTomorrow) == .moment(nineTomorrow, hasTime: true))
        // A repeating day with no time repeats as a day.
        guard case let .repeating(pattern, first, hasTime) = resolve("every Friday", stub: noonTomorrow) else {
            Issue.record("every Friday did not resolve to a pattern"); return
        }
        #expect(pattern == .weekly && !hasTime && first == tomorrow)
    }

    @Test("what counts as naming a time of day")
    func timeOfDayWords() {
        for phrase in ["at 9", "9:30", "17:00", "9.30", "9am", "noon", "tonight", "tomorrow morning", "at nine", "5 o'clock", "tomorrow at 9", "half past four tomorrow"] {
            #expect(MomentPhrase.saysATimeOfDay(phrase), "\(phrase)")
        }
        for phrase in ["tomorrow", "Friday", "next Monday", "25 December", "october 30", "on 25.12", "today", "the 25th"] {
            #expect(!MomentPhrase.saysATimeOfDay(phrase), "\(phrase)")
        }
    }

    @Test("next week, this weekend and the 25th are read as days, never in the past")
    func daysTheDetectorCannotRead() {
        // Monday 14 September 2026, 01:45. The detector has no match for any
        // of these, and they used to be refused.
        func day(_ phrase: String, at now: Date? = nil) -> (month: Int, day: Int)? {
            guard case let .moment(date, false) = MomentPhrase.resolve(phrase, now: now ?? self.now, calendar: calendar, detector: { _ in nil }) else {
                return nil
            }
            #expect(date == calendar.startOfDay(for: date), "\(phrase) carries a clock time")
            return (calendar.component(.month, from: date), calendar.component(.day, from: date))
        }
        for phrase in ["on the 25th", "the 25th", "25th", "the 25", "by the 25th"] {
            #expect(day(phrase).map { $0 == (9, 25) } == true, "\(phrase): \(String(describing: day(phrase)))")
        }
        #expect(day("the 14th").map { $0 == (9, 14) } == true, "today counts")
        #expect(day("the 10th").map { $0 == (10, 10) } == true, "a day gone this month is next month's")
        #expect(day("the 31st").map { $0 == (10, 31) } == true, "September has no 31st")
        for phrase in ["this weekend", "the weekend", "at the weekend", "weekend"] {
            #expect(day(phrase).map { $0 == (9, 19) } == true, "\(phrase): \(String(describing: day(phrase)))")
        }
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 10, minute: 0))!
        #expect(day("this weekend", at: saturday).map { $0 == (9, 19) } == true, "a weekend that has begun is today")
        #expect(day("in 3 days").map { $0 == (9, 17) } == true)

        guard case let .moment(nextWeek, false) = MomentPhrase.resolve("next week", now: now, calendar: calendar, detector: { _ in nil }) else {
            Issue.record("next week did not resolve to a day"); return
        }
        #expect(calendar.component(.weekday, from: nextWeek) == calendar.firstWeekday)
        #expect(nextWeek > now && nextWeek <= calendar.date(byAdding: .day, value: 7, to: now)!, "\(nextWeek)")
        // A bare number is not a day of the month.
        #expect(MomentPhrase.resolve("25", now: now, calendar: calendar, detector: { _ in nil }) == .unresolved)
    }

    // MARK: - A weekday and a bare hour

    @Test("Friday 5 is Friday at 5 and monday 10 is monday at 10, by the same reader")
    func weekdayHourIsWeekdayAtHour() {
        // Against the real detector, which read "Friday 5" as Thursday 5
        // November at noon and "monday 10" as Monday 10 August. Asserted on the
        // clock and the weekday, as the other live tests are.
        let rightNow = Date()
        let current = Calendar.current
        let pairs: [(String, String, Int, Int)] = [
            ("Friday 5", "Friday at 5", 6, 17),
            ("monday 10", "monday at 10", 2, 10),
            ("5 Friday", "Friday at 5", 6, 17),
            ("fri 5", "friday at 5", 6, 17),
            ("on Friday 5", "on Friday at 5", 6, 17)
        ]
        for (bare, withAt, weekday, hour) in pairs {
            let read = MomentPhrase.resolve(bare, now: rightNow, calendar: current)
            #expect(read == MomentPhrase.resolve(withAt, now: rightNow, calendar: current), "\(bare) is not \(withAt)")
            guard case let .moment(date, hasTime) = read else {
                Issue.record("\(bare) did not resolve"); continue
            }
            #expect(hasTime)
            #expect(current.component(.weekday, from: date) == weekday, "\(bare) landed on \(date)")
            #expect(current.component(.hour, from: date) == hour && current.component(.minute, from: date) == 0, "\(bare) landed at \(date)")
            #expect(date > rightNow && date < current.date(byAdding: .day, value: 8, to: rightNow)!, "\(bare) landed on \(date)")
        }
    }

    /// The fixture's `now`, 14 September 2026 at 01:45, is a Monday — whatever
    /// the screenshot it came from said. The stand-in detector answers the
    /// hour asked about on a date nobody asked for, 5 November, the way the
    /// real one did: only its hour may survive.
    private func weekdayAt(_ phrase: String, now: Date? = nil, readAs hour: Int, asked: inout [String]) -> DateComponents? {
        let read = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: hour, minute: 0))!
        var heard: [String] = []
        let result = MomentPhrase.resolve(phrase, now: now ?? self.now, calendar: calendar) { heard.append($0); return read }
        asked += heard
        guard case let .moment(date, true) = result else { return nil }
        return parts(date)
    }

    @Test("every way of writing it asks the detector one phrase, and lands on the coming weekday")
    func weekdayShapes() {
        var asked: [String] = []
        for phrase in ["Friday 5", "friday 5", "5 Friday", "on Friday 5", "fri 5", "Friday, 5", "this friday 5", "Friday at 5", "at 5 Friday"] {
            let wall = weekdayAt(phrase, readAs: 17, asked: &asked)
            #expect(wall?.month == 9 && wall?.day == 18 && wall?.hour == 17 && wall?.minute == 0, "\(phrase) landed at \(String(describing: wall))")
        }
        #expect(Set(asked) == ["friday at 5"], "\(Set(asked))")
    }

    @Test("today's weekday counts while the time is ahead, and otherwise it is next week")
    func todaysWeekday() {
        var asked: [String] = []
        // Monday, 01:45: ten this morning and five this afternoon are ahead.
        #expect(weekdayAt("monday 10", readAs: 10, asked: &asked)?.day == 14)
        #expect(weekdayAt("monday 5", readAs: 17, asked: &asked)?.day == 14)
        // Late on Monday they have gone: next Monday.
        let lateMonday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 23, minute: 0))!
        let next = weekdayAt("monday 10", now: lateMonday, readAs: 10, asked: &asked)
        #expect(next?.day == 21 && next?.hour == 10, "\(String(describing: next))")
    }

    @Test("a detector that drops the hour is not believed")
    func droppedWeekdayHour() {
        // Noon for "friday at 5" is the fallback, not five o'clock.
        var asked: [String] = []
        #expect(weekdayAt("Friday 5", readAs: 12, asked: &asked) == nil)
        #expect(MomentPhrase.resolve("Friday 5", now: now, calendar: calendar, detector: { _ in nil }) == .unresolved)
    }

    @Test("a weekday and an hour hold their wall clock across a clock change")
    func weekdayAcrossDaylightSaving() {
        // Britain's clocks go back early on Sunday 25 October 2026.
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 14, minute: 33))!
        var asked: [String] = []
        for hour in [6, 18] {
            let wall = weekdayAt("sunday 6", now: saturday, readAs: hour, asked: &asked)
            #expect(wall?.day == 25 && wall?.hour == hour && wall?.minute == 0, "landed at \(String(describing: wall))")
        }
    }

    @Test("every Friday 5 repeats from the coming Friday")
    func weeklyWeekdayAndHour() {
        let five = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 17, minute: 0))!
        guard case let .repeating(pattern, first, hasTime) = resolve("every Friday 5", stub: five) else {
            Issue.record("did not resolve to a pattern"); return
        }
        #expect(pattern == .weekly && hasTime)
        #expect(parts(first).day == 18 && parts(first).hour == 17)
    }

    @Test("only a weekday and a whole hour take this path")
    func weekdayShapesLeftAlone() {
        // The detector reads these right as they are, or they are somebody
        // else's sentence.
        for phrase in [
            "friday 5pm", "friday 5 pm", "friday 5:30", "friday 5 o'clock", "next friday 5", "friday 25",
            "friday 5 9", "friday monday 5", "friday at at 5", "friday", "5", "tomorrow 9", "may 5"
        ] {
            #expect(MomentPhrase.weekdayAndHour(phrase) == nil, "\(phrase)")
        }
        #expect(MomentPhrase.weekdayAndHour("Fri 5")?.phrase == "friday at 5")
        #expect(MomentPhrase.weekdayAndHour("monday 10")?.phrase == "monday at 10")
    }

    @Test("the detector is handed the phrase with its 'at'")
    func theDetectorReadsTheAt() {
        // Deterministic half of the live test above: whatever the detector
        // makes of "tomorrow at 9" is what "tomorrow 9" becomes.
        let nine = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 9, minute: 0))!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12, minute: 0))!
        let detector: (String) -> Date? = { $0 == "tomorrow at 9" || $0 == "at 9 tomorrow" ? nine : noon }
        for phrase in ["tomorrow 9", "9 tomorrow"] {
            #expect(MomentPhrase.resolve(phrase, now: now, calendar: calendar, detector: detector) == .moment(nine, hasTime: true), "\(phrase)")
        }
    }

    // MARK: - "Call mom at 6pm", asked at 2:33 PM

    /// The zone this machine is in, which is the zone the simulator runs in;
    /// the zone the wrong reminder was seen in; and UTC.
    static let zones: [String] = [TimeZone.current.identifier, "Asia/Kolkata", "UTC"]
        .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

    private func afternoon(in zone: String) -> (Calendar, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return (calendar, calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 33))!)
    }

    @Test("6pm said at 2:33 in the afternoon is six o'clock today, in any zone", arguments: MomentPhraseTests.zones)
    func sixPMIsToday(zone: String) {
        // Asked "Remind me to call mom at 6pm" at 2:33 PM, the app filed it for
        // 6 PM tomorrow. The model had written "tomorrow at 18:00" — fixed in
        // the tool's argument guidance — and this holds the half that is this
        // file's: handed "6pm", the answer is today.
        //
        // Against the real detector, not a stub. The detector reads in the
        // system zone; a calendar in another one used to get its hour, so
        // under UTC on a machine in Kolkata, "6pm" came back as 12:30 UTC —
        // already gone at 14:33 — and was moved to tomorrow.
        let (calendar, now) = afternoon(in: zone)
        for phrase in ["6pm", "at 6pm", "6 pm", "6 PM", "6:00 pm", "18:00", "at 18:00"] {
            guard case let .moment(date, hasTime) = MomentPhrase.resolve(phrase, now: now, calendar: calendar) else {
                Issue.record("\(phrase) did not resolve in \(zone)"); continue
            }
            let wall = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
            #expect(hasTime)
            #expect(wall.month == 10 && wall.day == 21, "\(phrase) in \(zone) landed on \(wall)")
            #expect(wall.hour == 18 && wall.minute == 0, "\(phrase) in \(zone) landed at \(wall)")
        }
    }

    @Test("2am said at 2:33 in the afternoon is two tomorrow morning, in any zone", arguments: MomentPhraseTests.zones)
    func twoAMIsTomorrow(zone: String) {
        // The rule this fix keeps: a time already gone today means the next one.
        let (calendar, now) = afternoon(in: zone)
        for phrase in ["2am", "at 2am", "2 AM"] {
            guard case let .moment(date, _) = MomentPhrase.resolve(phrase, now: now, calendar: calendar) else {
                Issue.record("\(phrase) did not resolve in \(zone)"); continue
            }
            let wall = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
            #expect(wall.day == 22 && wall.hour == 2 && wall.minute == 0, "\(phrase) in \(zone) landed at \(wall)")
        }
    }

    /// Wednesday 21 October 2026 at `hour:minute`, in `zone`.
    private func wednesday(at hour: Int, _ minute: Int, in zone: String) -> (Calendar, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return (calendar, calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: hour, minute: minute))!)
    }

    @Test("a whole hour from one to six is the afternoon; seven to twelve is the next one round", arguments: MomentPhraseTests.zones)
    func bareHourHalves(zone: String) {
        // "Remind me to call the plumber at 5", asked at 7:33 PM, was filed for
        // 5:00 AM tomorrow: the next five o'clock, and nobody's five o'clock.
        let cases: [(phrase: String, at: (Int, Int), day: Int, hour: Int)] = [
            ("at 5", (19, 33), 22, 17),
            ("at 5", (14, 0), 21, 17),
            ("at 9", (14, 0), 21, 21),
            ("at 7", (21, 0), 22, 7),
            ("5am", (19, 0), 22, 5),
            // The same five o'clock, written the other ways a person writes it.
            ("5", (19, 33), 22, 17),
            ("5 o'clock", (19, 33), 22, 17),
            ("at 5 o'clock", (19, 33), 22, 17),
            ("at 1", (9, 0), 21, 13),
            // One to six is the afternoon even in the morning: "at 6" at 5 AM.
            ("at 6", (5, 0), 21, 18),
            ("at 12", (14, 0), 22, 0)
        ]
        for (phrase, at, day, hour) in cases {
            let (calendar, now) = wednesday(at: at.0, at.1, in: zone)
            // None of these may reach the detector: one with a wrong answer.
            guard case let .moment(date, hasTime) = MomentPhrase.resolve(phrase, now: now, calendar: calendar, detector: { _ in .distantPast }) else {
                Issue.record("\(phrase) did not resolve in \(zone)"); continue
            }
            let wall = calendar.dateComponents([.day, .hour, .minute], from: date)
            #expect(hasTime)
            #expect(wall.day == day && wall.hour == hour && wall.minute == 0, "\(phrase) at \(at.0):\(at.1) in \(zone) landed at \(wall)")
        }
    }

    @Test("a morning that is said always wins", arguments: ["Asia/Kolkata", "UTC"])
    func saidMorningWins(zone: String) {
        let (calendar, now) = wednesday(at: 19, 0, in: zone)
        // The detector has no match for these, as the real one has none.
        for phrase in ["5am", "at 5am", "5 am", "5 in the morning", "at 5 in the morning", "morning at 5"] {
            guard case let .moment(date, _) = MomentPhrase.resolve(phrase, now: now, calendar: calendar, detector: { _ in nil }) else {
                Issue.record("\(phrase) did not resolve in \(zone)"); continue
            }
            let wall = calendar.dateComponents([.day, .hour], from: date)
            #expect(wall.day == 22 && wall.hour == 5, "\(phrase) in \(zone) landed at \(wall)")
        }
        // And "05:00", which the detector reads as the morning.
        let five = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 5, minute: 0))!
        guard case let .moment(date, _) = MomentPhrase.resolve("05:00", now: now, calendar: calendar, detector: { _ in five }) else {
            Issue.record("05:00 did not resolve"); return
        }
        let wall = calendar.dateComponents([.day, .hour], from: date)
        #expect(wall.day == 22 && wall.hour == 5, "05:00 in \(zone) landed at \(wall)")
    }

    @Test("an hour on its own is the next one round, as 'at 9' is")
    func aLoneHour() {
        // What Apple's model passes for "remind me to call mum at 9", four
        // times in five. Refused, the user was asked when "9" was.
        let (calendar, now) = afternoon(in: "UTC")
        guard case let .moment(date, hasTime) = MomentPhrase.resolve("9", now: now, calendar: calendar, detector: { _ in nil }) else {
            Issue.record("9 did not resolve"); return
        }
        let wall = calendar.dateComponents([.day, .hour, .minute], from: date)
        #expect(hasTime)
        #expect(wall.day == 21 && wall.hour == 21 && wall.minute == 0, "landed at \(wall)")
        // A number among other words is still not a time.
        #expect(MomentPhrase.resolve("in 20 bananas", now: now, calendar: calendar, detector: { _ in nil }) == .unresolved)
    }

    @Test("only a clock time that names its half of the day skips the detector")
    func whatSkipsTheDetector() {
        for phrase in ["6pm", "at 6pm", "6 pm", "6:30 pm", "18:00", "at 18:00", "12am"] {
            #expect(MomentPhrase.isUnambiguousClockTime(phrase), "\(phrase)")
        }
        // A day word, a part of the day, a second number, or no am or pm on an
        // hour that could be either: the detector's, as it always was.
        for phrase in ["at 9", "09:00", "9", "tomorrow at 3pm", "6pm today", "today at 6pm", "6 this evening", "1800", "6pm or 7pm", "in 20 minutes", "at", ""] {
            #expect(!MomentPhrase.isUnambiguousClockTime(phrase), "\(phrase)")
        }
        // And it really is skipped: a detector with a wrong answer is not asked.
        let (calendar, now) = afternoon(in: "UTC")
        guard case let .moment(date, _) = MomentPhrase.resolve("6pm", now: now, calendar: calendar, detector: { _ in .distantPast }) else {
            Issue.record("did not resolve"); return
        }
        #expect(calendar.component(.hour, from: date) == 18)
    }

    @Test("6pm on the days the clocks change is six on the wall, not seven or five")
    func clockTimesAcrossDaylightSaving() {
        // Britain's clocks go forward on 29 March 2026 and back on 25 October.
        // The start of either day plus eighteen hours is 19:00 on the first and
        // 17:00 on the second, which is how this used to build a clock time.
        let (calendar, _) = afternoon(in: "Europe/London")
        for (month, day) in [(3, 29), (10, 25)] {
            let now = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 14, minute: 33))!
            for (phrase, hour) in [("6pm", 18), ("at 9", 21), ("23:15", 23)] {
                guard case let .moment(date, _) = MomentPhrase.resolve(phrase, now: now, calendar: calendar, detector: { _ in nil }) else {
                    Issue.record("\(phrase) did not resolve on \(day)/\(month)"); continue
                }
                let wall = calendar.dateComponents([.day, .hour], from: date)
                #expect(wall.day == day && wall.hour == hour, "\(phrase) on \(day)/\(month) landed at \(wall)")
            }
        }
    }
}
