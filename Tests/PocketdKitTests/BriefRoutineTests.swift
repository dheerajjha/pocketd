import Foundation
import Testing
@testable import PocketdKit

/// What a brief routine puts on the lock screen.
///
/// The headline is this feature's own. The sentence under it is the brief's —
/// `BriefPrompt.notificationSentence` — and the tests here are the routine's
/// contract with it rather than a second copy of its tests: whatever the brief
/// says, the banner must never carry a title somebody else wrote, must say
/// nothing rather than advertise when nothing is connected, and must count
/// overdue things the way the Due tile does.
@Suite("Brief routines")
struct BriefRoutineTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let locale = Locale(identifier: "en_US")

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// Thursday 17 September 2026, 07:30 — the morning brief's own minute.
    static let now = date(17, 7, 30)

    static func sentence(_ snapshot: TodaySnapshot, now: Date = now) -> String? {
        BriefPrompt.notificationSentence(snapshot: snapshot, now: now, calendar: calendar, locale: locale)
    }

    static func fullDay() -> TodaySnapshot {
        TodaySnapshot(
            generatedAt: now,
            calendar: .connected,
            reminders: .connected,
            health: .connected,
            events: [
                BriefEvent(title: "Lunch with Priya at The Arches", start: date(17, 13), end: date(17, 14)),
                BriefEvent(title: "Standup", start: date(18, 9, 30), end: date(18, 10)),
            ],
            dueToday: [BriefReminder(title: "Pay Sam back", due: date(17, 18), dueHasTime: true)],
            overdue: [BriefReminder(title: "Send the signed lease", due: date(16, 18), dueHasTime: true)],
            sleepLastNight: 23_760,
            sleepUsual: 25_500
        )
    }

    // MARK: - The headline

    @Test("the two templates are announced by name, anything else by its own title")
    func headlines() {
        let morning = RoutineTemplate.morningBrief.task(now: Self.now)
        #expect(BriefRoutine.headline(for: morning) == "Your morning brief is ready.")
        let evening = RoutineTemplate.eveningWrapUp.task(now: Self.now)
        #expect(BriefRoutine.headline(for: evening) == "Your evening wrap-up is ready.")

        var mine = morning
        mine.title = "Lunch check"
        #expect(BriefRoutine.headline(for: mine) == "Lunch check is ready.")
        mine.title = "   "
        #expect(BriefRoutine.headline(for: mine) == "Your brief is ready.")
    }

    // MARK: - The sentence under it

    @Test("no event title or reminder name ever reaches the lock screen")
    func noTitlesReachTheLockScreen() throws {
        let text = try #require(Self.sentence(Self.fullDay()))
        for word in ["Priya", "Arches", "Lunch", "Standup", "Sam", "lease"] {
            #expect(!text.contains(word), "the banner said \(word)")
        }
        // The shape of the day is still there: a time and the counts.
        #expect(text.contains(Format.time(Self.date(17, 13), calendar: Self.calendar, locale: Self.locale)))
        #expect(text.contains("1 overdue"))
    }

    @Test("nothing readable means no sentence, not an invitation to connect")
    func nothingReadable() {
        #expect(Self.sentence(TodaySnapshot(generatedAt: Self.now)) == nil)
        let refused = TodaySnapshot(generatedAt: Self.now, calendar: .refused, reminders: .off, health: .unavailable)
        #expect(Self.sentence(refused) == nil)
    }

    @Test("a reminder whose time has passed is overdue on the banner, as on the Due tile")
    func passedTimeIsOverdue() throws {
        let snapshot = TodaySnapshot(
            generatedAt: Self.now,
            reminders: .connected,
            dueToday: [
                BriefReminder(title: "Call the plumber", due: Self.date(17, 17), dueHasTime: true),
                BriefReminder(title: "Water the plants", due: Self.date(17, 0), dueHasTime: false),
            ],
            overdue: [BriefReminder(title: "Submit expenses", due: Self.date(16, 18), dueHasTime: true)]
        )
        // At 6 PM "call the plumber at 5 PM" is late on the tile, so it is
        // late on the banner too; at 9 AM it is not yet.
        let evening = try #require(Self.sentence(snapshot, now: Self.date(17, 18)))
        #expect(evening.contains("2 overdue"))
        let morning = try #require(Self.sentence(snapshot, now: Self.date(17, 9)))
        #expect(morning.contains("1 overdue"))
    }
}
