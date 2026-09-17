import Foundation
import Testing
@testable import PocketdKit

/// The four numbers on the home tab, and the three ways each of them can have
/// nothing to say.
///
/// The happy paths here are cheap and the states around them are where the lies
/// live: a Sleep tile reading "0" when Health is switched off, an Up next tile
/// reading "Free" for a calendar that was never connected, a Steps tile tinted
/// as a warning at nine in the morning because a third of a day is smaller than
/// a whole one. None of that is visible in a screenshot and none of it can be
/// tested inside a `body`.
@Suite("Today tiles")
struct TodayTilesTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A locale that groups with commas, so "4,120" is a fact about the
    /// formatter rather than about the machine running the test.
    static let locale = Locale(identifier: "en_US")

    static func date(_ hour: Int, _ minute: Int = 0, day: Int = 17) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    static func snapshot(
        calendar: TodaySnapshot.Availability = .connected,
        reminders: TodaySnapshot.Availability = .connected,
        health: TodaySnapshot.Availability = .connected
    ) -> TodaySnapshot {
        TodaySnapshot(
            generatedAt: date(8),
            calendar: calendar,
            reminders: reminders,
            health: health,
            events: [BriefEvent(title: "Standup", start: date(10, 10), end: date(10, 40))],
            dueToday: [BriefReminder(title: "a"), BriefReminder(title: "b"), BriefReminder(title: "c")],
            overdue: [BriefReminder(title: "d")],
            sleepLastNight: 6 * 3600 + 36 * 60,
            sleepUsual: 7 * 3600 + 5 * 60,
            stepsToday: 4_120,
            stepsUsual: 6_100
        )
    }

    // MARK: - Up next

    @Test("the next event shows its name and how long there is")
    func upNext() {
        let tile = TodayTiles.upNext(Self.snapshot(), now: Self.date(8), calendar: Self.calendar, locale: Self.locale)
        #expect(tile.value == "Standup")
        // Rendered rather than left to a relative style: "in 2 hours" rounds
        // away the ten minutes that decide whether somebody leaves now.
        #expect(tile.footnote == "in 2h 10m")
        #expect(tile.tone == .neutral)
    }

    @Test("an empty afternoon is good news, not a blank")
    func upNextWithNothingLeft() {
        let tile = TodayTiles.upNext(Self.snapshot(), now: Self.date(18), calendar: Self.calendar, locale: Self.locale)
        #expect(tile.value == "Free")
        #expect(tile.footnote == "Nothing more today")
    }

    @Test("an event more than a day out gets a day and a time, not a count")
    func upNextFarAhead() {
        var snapshot = Self.snapshot()
        snapshot.events = [BriefEvent(title: "Flight", start: Self.date(8, day: 19), end: Self.date(11, day: 19))]
        let tile = TodayTiles.upNext(snapshot, now: Self.date(8), calendar: Self.calendar, locale: Self.locale)
        // "in 48h 0m" is a number nobody converts in their head.
        #expect(tile.footnote?.hasPrefix("Sat") == true)
        #expect(tile.footnote?.contains("in ") == false)
    }

    @Test("an event starting now says so")
    func upNextRightNow() {
        var snapshot = Self.snapshot()
        snapshot.events = [BriefEvent(title: "Standup", start: Self.date(10), end: Self.date(10, 30))]
        let tile = TodayTiles.upNext(snapshot, now: Self.date(9, 59, day: 17), calendar: Self.calendar, locale: Self.locale)
        #expect(tile.footnote == "in 1m")
    }

    @Test("an unconnected calendar is never reported as a free day")
    func upNextWhenNotConnected() {
        // "Free" for a calendar nobody ever granted is the tile telling somebody
        // their day is clear on the strength of having not looked.
        let off = TodayTiles.upNext(Self.snapshot(calendar: .off), now: Self.date(8), calendar: Self.calendar, locale: Self.locale)
        #expect(off.value == "Off")
        #expect(off.footnote == "Connect calendar")
        #expect(off.tone == .neutral)

        let refused = TodayTiles.upNext(Self.snapshot(calendar: .refused), now: Self.date(8), calendar: Self.calendar, locale: Self.locale)
        #expect(refused.footnote == "Allow calendar in Settings")
        #expect(refused.tone == .caution)

        let absent = TodayTiles.upNext(Self.snapshot(calendar: .unavailable), now: Self.date(8), calendar: Self.calendar, locale: Self.locale)
        #expect(absent.value == "—")
        #expect(absent.footnote == "Not on this iPhone")
    }

    @Test("a long event name is clipped rather than allowed to wrap off the tile")
    func upNextClipsLongTitles() {
        var snapshot = Self.snapshot()
        snapshot.events = [BriefEvent(
            title: "Quarterly planning working session with the platform group",
            start: Self.date(10), end: Self.date(11)
        )]
        let tile = TodayTiles.upNext(snapshot, now: Self.date(8), calendar: Self.calendar, locale: Self.locale)
        #expect(tile.value.count <= 29)
        #expect(tile.value.hasSuffix("…"))
    }

    // MARK: - Due

    @Test("the count is due today and the footnote is what has slipped")
    func due() {
        let tile = TodayTiles.due(Self.snapshot())
        #expect(tile.value == "3")
        #expect(tile.unit == "due")
        #expect(tile.footnote == "1 overdue")
        #expect(tile.tone == .caution)
    }

    @Test("nothing overdue gets no footnote about it")
    func dueWithoutOverdue() {
        var snapshot = Self.snapshot()
        snapshot.overdue = []
        let tile = TodayTiles.due(snapshot)
        // "0 overdue" under a count is two zeroes describing the same nothing.
        #expect(tile.footnote == nil)
        #expect(tile.tone == .neutral)
    }

    @Test("an empty list is a good state and reads like one")
    func dueWithNothingAtAll() {
        var snapshot = Self.snapshot()
        snapshot.dueToday = []
        snapshot.overdue = []
        let tile = TodayTiles.due(snapshot)
        #expect(tile.value == "0")
        #expect(tile.footnote == "All clear")
        #expect(tile.tone == .positive)
    }

    @Test("reminders that are off do not report a count of zero")
    func dueWhenNotConnected() {
        let tile = TodayTiles.due(Self.snapshot(reminders: .off))
        #expect(tile.value == "Off")
        #expect(tile.footnote == "Connect reminders")
    }

    // MARK: - Sleep

    @Test("sleep reads as hours and minutes against a usual")
    func sleep() {
        let tile = TodayTiles.sleep(Self.snapshot())
        #expect(tile.value == "6h 36m")
        // Zero-padded, so a column of these does not jitter between 5 and 55.
        #expect(tile.footnote == "usual 7h 05m")
        // Within the band, so nothing to warn about.
        #expect(tile.tone == .positive)
    }

    @Test("a genuinely short night is the only thing that gets a caution")
    func sleepTone() {
        var short = Self.snapshot()
        short.sleepUsual = 8 * 3600
        #expect(TodayTiles.sleep(short).tone == .caution)

        var long = Self.snapshot()
        long.sleepLastNight = 9 * 3600
        long.sleepUsual = 7 * 3600
        // A lie-in is not a warning. A tile that frowns at a good night's sleep
        // is a tile people learn to ignore.
        #expect(TodayTiles.sleep(long).tone == .positive)
    }

    @Test("a reading with no baseline says so rather than inventing one")
    func sleepWithoutUsual() {
        var snapshot = Self.snapshot()
        snapshot.sleepUsual = nil
        let tile = TodayTiles.sleep(snapshot)
        #expect(tile.value == "6h 36m")
        #expect(tile.footnote == "No usual yet")
        #expect(tile.tone == .neutral)
    }

    @Test("Health connected with nothing recorded is a dash, not a zero")
    func sleepWithNoReading() {
        var snapshot = Self.snapshot()
        snapshot.sleepLastNight = nil
        let tile = TodayTiles.sleep(snapshot)
        #expect(tile.value == "—")
        #expect(tile.footnote == "No sleep recorded")
    }

    @Test("Health switched off never shows a duration")
    func sleepWhenNotConnected() {
        let tile = TodayTiles.sleep(Self.snapshot(health: .off))
        #expect(tile.value == "Off")
        #expect(tile.footnote == "Connect Health")
    }

    // MARK: - Steps

    @Test("steps are grouped for a person to read")
    func steps() {
        let tile = TodayTiles.steps(Self.snapshot(), locale: Self.locale)
        #expect(tile.value == "4,120")
        #expect(tile.unit == nil)
        #expect(tile.footnote == "usual 6,100")
    }

    @Test("steps are never tinted, however far behind the usual they are")
    func stepsAreAlwaysNeutral() {
        // Steps-so-far is a partial day and `stepsUsual` is a whole one, so
        // comparing them would put a caution on this tile every single morning
        // and take it off again at teatime. Sleep does not have that problem: a
        // night is finished when it is measured.
        var barelyStarted = Self.snapshot()
        barelyStarted.stepsToday = 200
        #expect(TodayTiles.steps(barelyStarted, locale: Self.locale).tone == .neutral)

        var busy = Self.snapshot()
        busy.stepsToday = 20_000
        #expect(TodayTiles.steps(busy, locale: Self.locale).tone == .neutral)
    }

    @Test("no baseline means no footnote rather than a comparison with nothing")
    func stepsWithoutUsual() {
        var snapshot = Self.snapshot()
        snapshot.stepsUsual = nil
        #expect(TodayTiles.steps(snapshot, locale: Self.locale).footnote == nil)
    }

    // MARK: - Formatting

    @Test("the display formatter is not the one the model reads")
    func formatsDifferFromHealthFormat() {
        // Deliberately two spellings. `HealthFormat` strips digit grouping and
        // spaces out its units because a 1.7B model reads "12.000" as twelve;
        // a 44-point tile is read by a person, and the space is measured in
        // characters.
        #expect(BriefFormat.duration(6 * 3600 + 36 * 60) == "6h 36m")
        #expect(HealthFormat.duration(6 * 3600 + 36 * 60) == "6 h 36 m")
        #expect(BriefFormat.duration(7 * 3600 + 5 * 60) == "7h 05m")
        #expect(BriefFormat.duration(45 * 60) == "45m")
        #expect(BriefFormat.duration(0) == "0m")
        #expect(BriefFormat.duration(.nan) == "0m")

        #expect(BriefFormat.count(4_120, locale: Self.locale) == "4,120")
        #expect(HealthFormat.value(4_120, metric: .steps, locale: Self.locale) == "4120")
        #expect(BriefFormat.count(.nan, locale: Self.locale) == "—")
    }
}
