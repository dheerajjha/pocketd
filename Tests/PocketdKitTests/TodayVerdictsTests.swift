import Foundation
import Testing
@testable import PocketdKit

/// The four Today tiles as verdicts: a word, then one sentence with the number.
///
/// The words are pinned exactly, because the tile is the first thing anybody
/// reads and "Rested" over a four-hour night, or "All clear" over a reminder
/// that slipped at five, is the kind of wrong that ends trust in the whole
/// screen. The states around the happy path — off, refused, no data, no usual —
/// get as many tests as the happy path does.
@Suite("Today verdicts")
struct TodayVerdictsTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let locale = Locale(identifier: "en_US")

    static func date(_ hour: Int, _ minute: Int = 0, day: Int = 21) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// The seeded demo day, read at 9:41.
    static func demo(now: Date = date(9, 41)) -> TodaySnapshot {
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
            ],
            dueToday: [BriefReminder(title: "Call the plumber", due: date(17), dueHasTime: true)],
            overdue: [BriefReminder(title: "Submit expenses", due: date(18, day: 20), dueHasTime: true)],
            sleepLastNight: 6 * 3600 + 36 * 60,
            sleepUsual: 7 * 3600 + 5 * 60,
            stepsToday: 4_120,
            stepsUsual: 6_100,
            eventsCoverWholeDay: true
        )
    }

    // MARK: - Up next

    @Test("up next is the event, how long until it, and where")
    func upNextWithPlace() {
        let verdict = TodayVerdicts.upNext(Self.demo(), now: Self.date(9, 41), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "Lunch at The Arches")
        #expect(verdict.sentence == "In 3h 19m · The Arches")
        #expect(verdict.tone == .neutral)
        #expect(verdict.action == .openDetail)
    }

    @Test("an event with no place says when instead")
    func upNextWithoutPlace() {
        let verdict = TodayVerdicts.upNext(Self.demo(), now: Self.date(14, 30), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "Dentist")
        #expect(Self.plain(verdict.sentence) == "In 2h · 4:30 PM")
    }

    @Test("nothing left today is Free, and tomorrow is not up next")
    func upNextFree() {
        let verdict = TodayVerdicts.upNext(Self.demo(), now: Self.date(18), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "Free")
        #expect(verdict.sentence == "Nothing else today.")
        #expect(verdict.action == .openDetail)
    }

    @Test("the last thing of the day under way is on now, not Free")
    func upNextUnderWay() {
        let verdict = TodayVerdicts.upNext(Self.demo(), now: Self.date(16, 35), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "Dentist")
        #expect(Self.plain(verdict.sentence) == "On now · until 5:15 PM")
        #expect(verdict.action == .openDetail)
        // With something still to come, the tile is about that.
        let lunch = TodayVerdicts.upNext(Self.demo(), now: Self.date(13, 45), calendar: Self.calendar, locale: Self.locale)
        #expect(lunch.status == "Dentist")
        #expect(Self.plain(lunch.sentence) == "In 2h 45m · 4:30 PM")
    }

    @Test("a day with nothing on it at all says so, but only when the reader saw the whole day")
    func upNextEmptyDay() {
        var empty = Self.demo()
        empty.events = [BriefEvent(title: "Design review", start: Self.date(10, day: 22), end: Self.date(11, day: 22))]
        #expect(TodayVerdicts.upNext(empty, now: Self.date(8), calendar: Self.calendar).sentence == "Nothing on your calendar today.")
        // Read from `now`, the morning is invisible: the cautious wording.
        empty.eventsCoverWholeDay = false
        #expect(TodayVerdicts.upNext(empty, now: Self.date(8), calendar: Self.calendar).sentence == "Nothing else today.")
    }

    @Test("a countdown never says in 0")
    func upNextImminent() {
        let verdict = TodayVerdicts.upNext(Self.demo(), now: Self.date(12, 59, day: 21).addingTimeInterval(40), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.sentence == "In 1 min · The Arches")
    }

    // MARK: - Due

    @Test("overdue outranks due, and the sentence names the one that slipped")
    func dueOverdue() {
        let verdict = TodayVerdicts.due(Self.demo(), now: Self.date(9, 41), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "1 overdue")
        #expect(verdict.sentence == "Submit expenses was due yesterday.")
        #expect(verdict.tone == .warning)
    }

    @Test("a timed reminder is overdue the minute its time passes")
    func dueTimePassed() {
        let verdict = TodayVerdicts.due(Self.demo(), now: Self.date(18), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "2 overdue")
        // Most overdue first: yesterday's beats this afternoon's.
        #expect(verdict.sentence == "Submit expenses was due yesterday.")

        var onlyToday = Self.demo()
        onlyToday.overdue = []
        let late = TodayVerdicts.due(onlyToday, now: Self.date(18), calendar: Self.calendar, locale: Self.locale)
        #expect(late.status == "1 overdue")
        #expect(Self.plain(late.sentence) == "Call the plumber was due at 5:00 PM.")
    }

    @Test("a date-only reminder is not overdue until its day is over")
    func dueDateOnly() {
        var snapshot = Self.demo()
        snapshot.overdue = []
        snapshot.dueToday = [BriefReminder(title: "Water the plants", due: Self.date(0), dueHasTime: false)]
        let verdict = TodayVerdicts.due(snapshot, now: Self.date(23, 30), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "1 today")
        #expect(verdict.sentence == "Water the plants is due today.")
        #expect(verdict.tone == .neutral)
    }

    @Test("due today names the soonest, timed before date-only")
    func dueToday() {
        var snapshot = Self.demo()
        snapshot.overdue = []
        snapshot.dueToday = [
            BriefReminder(title: "Water the plants", due: Self.date(0), dueHasTime: false),
            BriefReminder(title: "Call the plumber", due: Self.date(17), dueHasTime: true),
            BriefReminder(title: "Book flights", due: Self.date(19), dueHasTime: true),
        ]
        let verdict = TodayVerdicts.due(snapshot, now: Self.date(9), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "3 today")
        #expect(Self.plain(verdict.sentence) == "Call the plumber is due at 5:00 PM.")
    }

    @Test("nothing due is all clear, and good news")
    func dueAllClear() {
        var snapshot = Self.demo()
        snapshot.overdue = []
        snapshot.dueToday = []
        let verdict = TodayVerdicts.due(snapshot, now: Self.date(9), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "All clear")
        #expect(verdict.sentence == "Nothing due today.")
        #expect(verdict.tone == .good)
    }

    @Test("an older overdue reminder is named by its day")
    func dueOlder() {
        var snapshot = Self.demo()
        snapshot.overdue = [BriefReminder(title: "Send the invoice", due: Self.date(9, day: 19), dueHasTime: false)]
        let verdict = TodayVerdicts.due(snapshot, now: Self.date(9), calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.sentence == "Send the invoice was due on Monday.")
    }

    // MARK: - Sleep

    @Test("a night within the band of usual is Rested, and still carries the minutes")
    func sleepRested() {
        let verdict = TodayVerdicts.sleep(Self.demo())
        #expect(verdict.status == "Rested")
        #expect(verdict.sentence == "6h 36m — 29 min under your usual.")
        #expect(verdict.tone == .good)
    }

    @Test("a short night is a warning, a long one is not")
    func sleepShortAndLong() {
        var short = Self.demo()
        short.sleepLastNight = 5 * 3600 + 10 * 60
        let shortVerdict = TodayVerdicts.sleep(short)
        #expect(shortVerdict.status == "Short night")
        #expect(shortVerdict.sentence == "5h 10m — 1h 55m under your usual.")
        #expect(shortVerdict.tone == .warning)

        var long = Self.demo()
        long.sleepLastNight = 8 * 3600 + 30 * 60
        let longVerdict = TodayVerdicts.sleep(long)
        #expect(longVerdict.status == "Long night")
        #expect(longVerdict.sentence == "8h 30m — 1h 25m over your usual.")
        #expect(longVerdict.tone == .neutral)
    }

    @Test("a few minutes either way is about your usual")
    func sleepAboutUsual() {
        var snapshot = Self.demo()
        snapshot.sleepLastNight = 7 * 3600 + 2 * 60
        #expect(TodayVerdicts.sleep(snapshot).sentence == "7h 2m — about your usual.")
    }

    @Test("with no usual yet, only the broad band decides")
    func sleepNoUsual() {
        var snapshot = Self.demo()
        snapshot.sleepUsual = nil
        #expect(TodayVerdicts.sleep(snapshot).status == "Rested")
        #expect(TodayVerdicts.sleep(snapshot).sentence == "6h 36m last night.")
        snapshot.sleepLastNight = 4 * 3600
        #expect(TodayVerdicts.sleep(snapshot).status == "Short night")
        snapshot.sleepLastNight = 10 * 3600
        #expect(TodayVerdicts.sleep(snapshot).status == "Long night")
    }

    @Test("no sleep recorded is No data, never zero")
    func sleepNoData() {
        var snapshot = Self.demo()
        snapshot.sleepLastNight = nil
        let verdict = TodayVerdicts.sleep(snapshot)
        #expect(verdict.status == "No data")
        #expect(verdict.sentence == "No sleep recorded last night.")
        #expect(!verdict.sentence.contains("0"))
    }

    // MARK: - Activity

    @Test("against the usual by now: ahead, on track, behind")
    func activityByNow() {
        var snapshot = Self.demo()
        snapshot.stepsUsualByNow = 6_100
        let behind = TodayVerdicts.activity(snapshot, calendar: Self.calendar, locale: Self.locale)
        #expect(behind.status == "Behind")
        #expect(behind.sentence == "4,120 steps — you're usually at 6,100 by now.")
        #expect(behind.tone == .warning)

        snapshot.stepsUsualByNow = 4_000
        #expect(TodayVerdicts.activity(snapshot, calendar: Self.calendar, locale: Self.locale).status == "On track")

        snapshot.stepsUsualByNow = 2_500
        let ahead = TodayVerdicts.activity(snapshot, calendar: Self.calendar, locale: Self.locale)
        #expect(ahead.status == "Ahead")
        #expect(ahead.tone == .good)
    }

    @Test("with only a daily usual the sentence says a day, and the verdict is never a warning")
    func activityDailyOnly() {
        // 9:41 is 19% of the 07:00–21:00 day; 19% of 6,100 is about 1,170.
        let early = TodayVerdicts.activity(Self.demo(), calendar: Self.calendar, locale: Self.locale)
        #expect(early.sentence == "4,120 steps — usually 6,100 a day.")
        #expect(early.status == "Ahead")

        var evening = Self.demo(now: Self.date(20))
        evening.stepsToday = 2_000
        let behind = TodayVerdicts.activity(evening, calendar: Self.calendar, locale: Self.locale)
        #expect(behind.status == "Behind")
        // An estimate does not get to tell anybody off.
        #expect(behind.tone == .neutral)
    }

    @Test("before seven in the morning nothing is behind")
    func activityEarlyMorning() {
        var dawn = Self.demo(now: Self.date(6, 30))
        dawn.stepsToday = 40
        #expect(TodayVerdicts.activity(dawn, calendar: Self.calendar, locale: Self.locale).status == "On track")
        #expect(TodayVerdicts.expectedShare(at: Self.date(6, 30), calendar: Self.calendar) == 0)
        #expect(TodayVerdicts.expectedShare(at: Self.date(14), calendar: Self.calendar) == 0.5)
        #expect(TodayVerdicts.expectedShare(at: Self.date(22), calendar: Self.calendar) == 1)
    }

    @Test("steps with no usual at all are just the count")
    func activityNoUsual() {
        var snapshot = Self.demo()
        snapshot.stepsUsual = nil
        let verdict = TodayVerdicts.activity(snapshot, calendar: Self.calendar, locale: Self.locale)
        #expect(verdict.status == "So far")
        #expect(verdict.sentence == "4,120 steps today.")
        snapshot.stepsToday = nil
        #expect(TodayVerdicts.activity(snapshot, calendar: Self.calendar, locale: Self.locale).status == "No data")
    }

    // MARK: - Off

    @Test("a source that is off says Off and opens the connect door")
    func offStates() {
        let off = TodaySnapshot(generatedAt: Self.date(9))
        let verdicts = TodayVerdicts.all(off, now: Self.date(9), calendar: Self.calendar, locale: Self.locale)
        #expect(verdicts.map(\.tile) == [.upNext, .due, .sleep, .activity])
        #expect(verdicts.allSatisfy { $0.status == "Off" && $0.action == .connect && $0.isOff })
        #expect(verdicts.map(\.sentence) == [
            "Turn on to see what's next.",
            "Turn on to see what's due.",
            "Turn on to see how you slept.",
            "Turn on to see your steps.",
        ])
    }

    @Test("a source iOS refused goes to Settings")
    func refusedStates() {
        let refused = TodaySnapshot(generatedAt: Self.date(9), calendar: .refused, reminders: .refused, health: .refused)
        let verdict = TodayVerdicts.upNext(refused, now: Self.date(9), calendar: Self.calendar)
        #expect(verdict.status == "Off")
        #expect(verdict.sentence == "Turn on in Settings to see what's next.")
        #expect(verdict.action == .openSettings)
        #expect(verdict.tone == .warning)
    }

    @Test("a device with no Health is not a button")
    func unavailableState() {
        let none = TodaySnapshot(generatedAt: Self.date(9), health: .unavailable)
        let verdict = TodayVerdicts.sleep(none)
        #expect(verdict.status == "Not here")
        #expect(verdict.action == .none)
        #expect(!verdict.isOff)
    }

    @Test("VoiceOver hears the label, the verdict and the number")
    func accessibility() {
        let verdict = TodayVerdicts.sleep(Self.demo())
        #expect(verdict.accessibilityLabel == "Sleep: Rested. 6h 36m — 29 min under your usual.")
    }

    @Test("no verdict ever spells a number out")
    func digitsOnly() {
        let words = [" one ", " two ", " three ", "twenty", "thirty", "fifty"]
        for hour in [6, 9, 12, 15, 18, 22] {
            for verdict in TodayVerdicts.all(Self.demo(), now: Self.date(hour), calendar: Self.calendar, locale: Self.locale) {
                let text = " \(verdict.status) \(verdict.sentence) ".lowercased()
                for word in words { #expect(!text.contains(word), "\(text)") }
            }
        }
    }
}
