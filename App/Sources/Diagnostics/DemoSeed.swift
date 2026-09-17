#if DEBUG
import EventKit
import Foundation
import PocketdKit

// Stages a realistic calendar and a realistic reminders list on a simulator,
// so screenshots and UI testing have something believable to show without a
// real phone's data ever being near this machine.
//
// Every title below is invented — no real person, no real company beyond one
// made-up café, nothing medical. That restraint matters here specifically:
// this writes straight into the simulator's own Calendar and Reminders apps,
// the same stores a real install would use, and "it's only a screenshot" is
// not licence to put something in there this app would not want its own
// privacy promises measured against.
//
// The event set (Standup, Dentist, lunch at a café called The Arches) matches
// what ../../../pocketd-store/seed stages for the App Store screenshots,
// minus the one change that had to be made: that package's lunch event was
// "Lunch with Sam", and this file also seeds the profile name "Sam" — a
// calendar inviting the user to lunch with themselves is a worse screenshot
// than a mismatched one, so here the event is "Lunch at The Arches" instead.
//
// Compiled only into Debug — this whole file, imports included, is inside
// `#if DEBUG`, so a Release build has no path through any of it at all, not
// even a dead `if` branch.

/// Entry point for `-pocketd.seedDemo`. See `scripts/sim-demo.sh`.
enum DemoSeed {

    /// Whether this launch asked to be seeded.
    ///
    /// A launch argument, not a build setting: the same Debug binary has to
    /// keep working with a clean, empty calendar for ordinary development, and
    /// only `scripts/sim-demo.sh` — which exists purely to stage screenshots —
    /// ever passes this.
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.seedDemo")
    }

    /// Whether this launch also asked to skip the intro.
    ///
    /// Kept separate from `isRequested` on purpose. A screenshot of the intro
    /// itself still wants a seeded calendar behind it — the two asks are
    /// independent, and folding them into one flag would make that case
    /// unreachable from this script.
    private static var skipsIntro: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.skipIntro")
    }

    private enum Keys {
        /// The literal from `AppModel.Keys.completedOnboarding`. That enum is
        /// private to its own file, so this is a second copy of the string
        /// rather than a shared reference — the two have to be kept in sync by
        /// hand, which is the whole reason this file does not also duplicate
        /// the onboarding logic itself and only ever writes `true`.
        static let completedOnboarding = "pocketd.completedOnboarding"
        /// No `Profile` type exists under `App/Sources/State` yet. This is the
        /// key such a type has already been told to read `name` from, so
        /// writing it now seeds the value a future `Profile` will pick up on
        /// its first launch rather than inventing a second, competing key.
        static let profileName = "pd.profile.name"
    }

    @MainActor
    static func runIfRequested() async {
        guard isRequested else { return }

        // Through the app's own actor, never a second `EKEventStore` — see
        // `EventAccess` for why a store created after the grant would see a
        // stale authorization until reset. Both entities are asked for up
        // front, matching the order Settings uses when the switches are
        // turned on: permission before anything that needs it.
        _ = await EventAccess.shared.requestReadAccess(to: .calendar)
        _ = await EventAccess.shared.requestReadAccess(to: .reminders)

        await seedEvents()
        await seedReminders()
        seedProfileName()
        if skipsIntro {
            UserDefaults.standard.set(true, forKey: Keys.completedOnboarding)
        }
    }

    // MARK: - Events

    private struct DemoEvent {
        let title: String
        let start: Date
        let end: Date
        let location: String?
    }

    private static func seedEvents() async {
        let calendar = Calendar.current
        let now = Date()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: now) ?? now.addingTimeInterval(2 * 86_400)

        let flightStart = at(12, 0, on: dayAfter, calendar: calendar)
        let events = [
            DemoEvent(title: "Standup",
                      start: at(9, 30, on: now, calendar: calendar), end: at(9, 45, on: now, calendar: calendar),
                      location: nil),
            DemoEvent(title: "Lunch at The Arches",
                      start: at(13, 0, on: now, calendar: calendar), end: at(14, 0, on: now, calendar: calendar),
                      location: "The Arches"),
            DemoEvent(title: "Dentist",
                      start: at(16, 30, on: now, calendar: calendar), end: at(17, 15, on: now, calendar: calendar),
                      location: nil),
            DemoEvent(title: "Design review",
                      start: at(10, 0, on: tomorrow, calendar: calendar), end: at(11, 0, on: tomorrow, calendar: calendar),
                      location: nil),
            DemoEvent(title: "Yoga",
                      start: at(18, 30, on: tomorrow, calendar: calendar), end: at(20, 0, on: tomorrow, calendar: calendar),
                      location: nil),
            // No length was specified for this one, so it gets the same
            // default the assistant's own create tool uses for an event
            // nobody gave a duration to — see `PersonalDataWrites.defaultEventMinutes`.
            DemoEvent(title: "Flight to Lisbon",
                      start: flightStart,
                      end: calendar.date(byAdding: .minute, value: PersonalDataWrites.defaultEventMinutes, to: flightStart) ?? flightStart,
                      location: "Terminal 2")
        ]

        // Read once, for the whole span every candidate above falls in,
        // rather than once per title — the first launch after install is
        // exactly when the calendar daemon is slowest to answer, and six
        // reads of the same three days would only make that wait longer.
        let windowStart = calendar.startOfDay(for: now)
        let windowEnd = calendar.date(byAdding: .day, value: 3, to: windowStart) ?? dayAfter.addingTimeInterval(86_400)
        let existing = existingTitles(from: await EventAccess.shared.events(in: DateInterval(start: windowStart, end: windowEnd)))

        for event in events {
            guard !existing.contains(normalised(event.title)) else { continue }
            _ = await EventAccess.shared.createEvent(
                NewEvent(title: event.title, start: event.start, end: event.end, location: event.location)
            )
        }
    }

    private static func existingTitles(from lookup: PersonalDataLookup<CalendarEventRow>) -> Set<String> {
        guard case let .rows(rows, _) = lookup else { return [] }
        return Set(rows.map { normalised($0.title.attackerControlledValue()) })
    }

    // MARK: - Reminders

    private struct DemoReminder {
        let title: String
        let due: Date?
        let dueHasTime: Bool
    }

    private static func seedReminders() async {
        let calendar = Calendar.current
        let now = Date()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        let inThreeDays = calendar.date(byAdding: .day, value: 3, to: now) ?? now.addingTimeInterval(3 * 86_400)

        let reminders = [
            DemoReminder(title: "Renew passport", due: at(9, 0, on: tomorrow, calendar: calendar), dueHasTime: true),
            DemoReminder(title: "Call the plumber", due: at(17, 0, on: now, calendar: calendar), dueHasTime: true),
            DemoReminder(title: "Buy oat milk", due: nil, dueHasTime: false),
            // Deliberately in the past, for the screenshot that shows what
            // overdue looks like. Written through `EventAccess.createReminder`
            // directly rather than `PersonalDataWrites.createReminder`: that
            // higher layer rolls a same-day past time forward so a spoken
            // "2am" can never land behind the clock, and rolling this one
            // forward would erase the exact state this row exists to show.
            DemoReminder(title: "Submit expenses", due: at(18, 0, on: yesterday, calendar: calendar), dueHasTime: true),
            // A day, not a time — nothing said which hour, so none is
            // invented. Same rule `PersonalDataWrites` applies to any due
            // date with no clock time: "no guessed hour, ever".
            DemoReminder(title: "Water the plants", due: inThreeDays, dueHasTime: false)
        ]

        // `DateWindow(start: nil, end: nil)` is the one shape that also
        // returns reminders with no due date — "Buy oat milk" would otherwise
        // never be seen by its own duplicate check on a second run.
        guard case let .rows(existingRows, _) = await EventAccess.shared.reminders(in: DateWindow(start: nil, end: nil)) else {
            return
        }
        let existing = Set(existingRows.map { normalised($0.title.attackerControlledValue()) })

        for reminder in reminders {
            guard !existing.contains(normalised(reminder.title)) else { continue }
            _ = await EventAccess.shared.createReminder(
                NewReminder(title: reminder.title, due: reminder.due, dueHasTime: reminder.dueHasTime)
            )
        }
    }

    // MARK: - Profile

    /// No `Profile` type exists yet — see `Keys.profileName`. Once one does,
    /// this line keeps working unchanged: it writes the value, not the type.
    private static func seedProfileName() {
        UserDefaults.standard.set("Sam", forKey: Keys.profileName)
    }

    // MARK: - Shared

    private static func at(_ hour: Int, _ minute: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// Case- and whitespace-insensitive, and nothing more. `PersonalDataWrites`
    /// strips punctuation too for its own duplicate check, but that function is
    /// internal to PocketdKit and this file is asking a narrower question — do
    /// two titles this file itself chose collide — where an exact-ish match is
    /// the right amount of fuzz.
    private static func normalised(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
#endif
