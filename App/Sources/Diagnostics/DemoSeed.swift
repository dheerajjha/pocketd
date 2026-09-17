#if DEBUG
import CoreGraphics
import EventKit
import Foundation
import PocketdKit

// Stages a realistic calendar and a realistic reminders list on a simulator,
// so screenshots and UI testing have something believable to show without a
// real phone's data ever being near this machine.
//
// Every title below is invented — no real person, no real company beyond one
// made-up café, nothing medical. That restraint matters, but on its own it
// would not be enough: this used to write straight into the simulator's own
// Calendar and Reminders apps, the same stores a real install would use, and
// "it's only a screenshot" is not licence to put something in there this app
// would not want its own privacy promises measured against. It no longer
// does that. Everything below lands in a calendar and a reminders list, both
// titled "Pocketd Demo", that `DemoStore` finds-or-creates the first time
// this runs — never the device's default calendar or list, so seeding this
// cannot add a single row anywhere a real install already keeps real data,
// and `-pocketd.unseedDemo` can remove the whole thing again by deleting
// exactly those two containers.
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

/// Entry point for `-pocketd.seedDemo` and `-pocketd.unseedDemo`. See
/// `scripts/sim-demo.sh`.
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

    /// Whether this launch asked to remove the demo calendar and list
    /// instead.
    ///
    /// Independent of `isRequested` — `sim-demo.sh unseed` passes only this
    /// one — and honoured first when both are present, so that a launch
    /// carrying both arguments ends with one freshly re-seeded calendar
    /// rather than a duplicate-filled one.
    static var isUnseedRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.unseedDemo")
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
        guard isRequested || isUnseedRequested else { return }

        // Ahead of anything else, and unconditionally: a launch carrying both
        // arguments means "start clean", and the only way `seedEvents`/
        // `seedReminders` below can tell they are starting clean is if the
        // old containers are already gone by the time they go looking for
        // one to reuse.
        if isUnseedRequested {
            await DemoStore.shared.unseed()
        }
        guard isRequested else { return }

        await seedEvents()
        await seedReminders()
        seedProfileName()
        if skipsIntro {
            UserDefaults.standard.set(true, forKey: Keys.completedOnboarding)
        }
    }

    // MARK: - Events

    private struct DemoEvent: Sendable {
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

        // The whole span every candidate above falls in, read once inside
        // `DemoStore` rather than once per title — the first launch after
        // install is exactly when the calendar daemon is slowest to answer,
        // and six reads of the same three days would only make that wait
        // longer.
        let windowStart = calendar.startOfDay(for: now)
        let windowEnd = calendar.date(byAdding: .day, value: 3, to: windowStart) ?? dayAfter.addingTimeInterval(86_400)
        await DemoStore.shared.seedEvents(events, windowStart: windowStart, windowEnd: windowEnd)
    }

    // MARK: - Reminders

    private struct DemoReminder: Sendable {
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
            // overdue looks like. Never rolled forward the way
            // `PersonalDataWrites` rolls a same-day past time forward so a
            // spoken "2am" cannot land behind the clock — rolling this one
            // forward would erase the exact state this row exists to show.
            DemoReminder(title: "Submit expenses", due: at(18, 0, on: yesterday, calendar: calendar), dueHasTime: true),
            // A day, not a time — nothing said which hour, so none is
            // invented. Same rule `PersonalDataWrites` applies to any due
            // date with no clock time: "no guessed hour, ever".
            DemoReminder(title: "Water the plants", due: inThreeDays, dueHasTime: false)
        ]

        await DemoStore.shared.seedReminders(reminders)
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

    // MARK: - The store

    /// The one place this file touches EventKit.
    ///
    /// Its own `EKEventStore`, never `EventAccess.shared`'s. Two different
    /// reasons, not one: `EventAccess`'s single-store rule (see that type's
    /// own doc comment) is about keeping one store's authorization cache
    /// honest for the app's real read/write path, and has nothing to say
    /// about a second, unrelated store; and separately, routing through
    /// `EventAccess` would mean routing through
    /// `defaultCalendarForNewEvents`/`defaultCalendarForNewReminders` — the
    /// user's own default calendar and list, exactly what this file exists
    /// to stay out of.
    ///
    /// An actor for the same reason `EventAccess` is one: every call below
    /// blocks on the calendar daemon, and this being its own isolation
    /// domain is what keeps that off the main actor `runIfRequested()` runs
    /// on.
    private actor DemoStore {
        static let shared = DemoStore()

        private let store = EKEventStore()

        private static let demoTitle = "Pocketd Demo"

        /// The app's accent — `Color.pd.accent`'s light value in
        /// `App/Sources/Design/Theme.swift`, restated as a `CGColor`, the
        /// currency `EKCalendar.cgColor` deals in. No dark-mode pair: a
        /// calendar's colour is one fixed value as far as EventKit is
        /// concerned, and the point of setting it is only to make
        /// "Pocketd Demo" recognisable at a glance in Calendar and
        /// Reminders, not to track either theme.
        private static let accentColor = CGColor(
            red: CGFloat(0x39) / 255,
            green: CGFloat(0x64) / 255,
            blue: CGFloat(0x9E) / 255,
            alpha: 1
        )

        // MARK: Permission

        /// Requests full access to both entities through this store, if
        /// neither has been asked of it yet.
        ///
        /// The same status checks `EventAccess.requestReadAccess` uses —
        /// granted, denied and restricted are left alone, since iOS shows its
        /// prompt once; not-determined and write-only (events only) are worth
        /// one attempt, since iOS may still have a prompt to show — aimed at
        /// this store rather than that one, because the grant this store
        /// needs is a grant this instance has to be the one to ask for and
        /// observe.
        private func requestAccess() async {
            for entity in PersonalDataEntity.allCases {
                switch EventAccess.authorization(for: entity) {
                case .granted, .denied, .restricted:
                    continue
                case .notDetermined, .writeOnly:
                    break
                }
                do {
                    switch entity {
                    case .calendar: _ = try await store.requestFullAccessToEvents()
                    case .reminders: _ = try await store.requestFullAccessToReminders()
                    }
                } catch {
                    print("Pocketd demo seed: requesting \(entity.noun) access failed: \(error)")
                }
            }
        }

        // MARK: Container

        /// Finds "Pocketd Demo", creating it — with the safest source this
        /// device has — the first time anything asks for one. Shared by every
        /// write below and by `unseed()`, so there is exactly one place that
        /// decides what "the demo container" means.
        ///
        /// `EKCalendar` backs both a calendar and a reminders list; only its
        /// `entityType` says which, so this one function does both jobs.
        private func demoContainer(for entityType: EKEntityType) -> EKCalendar? {
            if let existing = store.calendars(for: entityType).first(where: { $0.title == Self.demoTitle }) {
                return existing
            }

            let defaultCalendar = entityType == .event
                ? store.defaultCalendarForNewEvents
                : store.defaultCalendarForNewReminders()

            // A local source never syncs — nothing filed under it can leave
            // this device by way of iCloud, Exchange or anything else — so
            // it is tried first whenever one exists. The default calendar's
            // own source is the fallback candidate: not guaranteed local,
            // but at least already proven to hold this entity type on this
            // device. Neither is a guarantee — an Exchange source, for one,
            // typically refuses reminders — so both are attempts, and
            // `makeCalendar` reports failure by returning `nil` rather than
            // throwing.
            let localSource = store.sources.first { $0.sourceType == .local }
            for source in [localSource, defaultCalendar?.source].compactMap({ $0 }) {
                if let created = makeCalendar(for: entityType, source: source) {
                    return created
                }
            }

            let noun = entityType == .event ? "calendar" : "reminders list"
            print("Pocketd demo seed: no source on this device could hold a separate \"\(Self.demoTitle)\" \(noun) — demo data will use the default \(noun) instead.")
            return defaultCalendar
        }

        private func makeCalendar(for entityType: EKEntityType, source: EKSource) -> EKCalendar? {
            let calendar = EKCalendar(for: entityType, eventStore: store)
            calendar.title = Self.demoTitle
            calendar.cgColor = Self.accentColor
            calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: true)
                return calendar
            } catch {
                return nil
            }
        }

        // MARK: Writes

        /// Writes `events` into the demo calendar, skipping any title already
        /// there over `windowStart..<windowEnd`.
        func seedEvents(_ events: [DemoEvent], windowStart: Date, windowEnd: Date) async {
            await requestAccess()
            guard let calendar = demoContainer(for: .event) else {
                print("Pocketd demo seed: no calendar available at all — events were not written.")
                return
            }

            let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
            let existing = Set(store.events(matching: predicate).map { DemoSeed.normalised($0.title ?? "") })

            for event in events where !existing.contains(DemoSeed.normalised(event.title)) {
                let ekEvent = EKEvent(eventStore: store)
                ekEvent.title = event.title
                ekEvent.startDate = event.start
                ekEvent.endDate = event.end
                ekEvent.location = event.location
                ekEvent.calendar = calendar
                do {
                    try store.save(ekEvent, span: .thisEvent, commit: true)
                } catch {
                    print("Pocketd demo seed: could not save event \"\(event.title)\": \(error)")
                }
            }
        }

        /// Writes `reminders` into the demo list, skipping any title already
        /// there — due or not, since "Buy oat milk" has no due date and would
        /// otherwise never be seen by its own duplicate check.
        func seedReminders(_ reminders: [DemoReminder]) async {
            await requestAccess()
            guard let list = demoContainer(for: .reminder) else {
                print("Pocketd demo seed: no reminders list available at all — reminders were not written.")
                return
            }

            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
            let existing = await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
                store.fetchReminders(matching: predicate) { fetched in
                    continuation.resume(returning: Set((fetched ?? []).map { DemoSeed.normalised($0.title ?? "") }))
                }
            }

            for reminder in reminders where !existing.contains(DemoSeed.normalised(reminder.title)) {
                let ekReminder = EKReminder(eventStore: store)
                ekReminder.title = reminder.title
                ekReminder.calendar = list
                if let due = reminder.due {
                    // Date-only stays date-only — the same rule `EventAccess`
                    // applies to a real write, restated here because this
                    // reminder is written directly rather than through it.
                    let fields: Set<Calendar.Component> = reminder.dueHasTime
                        ? [.year, .month, .day, .hour, .minute]
                        : [.year, .month, .day]
                    ekReminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due)
                }
                do {
                    try store.save(ekReminder, commit: true)
                } catch {
                    print("Pocketd demo seed: could not save reminder \"\(reminder.title)\": \(error)")
                }
            }
        }

        // MARK: Unseed

        /// Removes the demo calendar and list entirely, if either exists, and
        /// prints what it removed. `store.removeCalendar(_:commit:)` deletes
        /// everything filed inside it — the events and reminders are not a
        /// separate step.
        func unseed() async {
            await requestAccess()

            var removed: [String] = []
            if let calendar = store.calendars(for: .event).first(where: { $0.title == Self.demoTitle }) {
                do {
                    try store.removeCalendar(calendar, commit: true)
                    removed.append("the \"\(Self.demoTitle)\" calendar")
                } catch {
                    print("Pocketd demo seed: could not remove the \"\(Self.demoTitle)\" calendar: \(error)")
                }
            }
            if let list = store.calendars(for: .reminder).first(where: { $0.title == Self.demoTitle }) {
                do {
                    try store.removeCalendar(list, commit: true)
                    removed.append("the \"\(Self.demoTitle)\" reminders list")
                } catch {
                    print("Pocketd demo seed: could not remove the \"\(Self.demoTitle)\" reminders list: \(error)")
                }
            }

            if removed.isEmpty {
                print("Pocketd demo seed: nothing to remove — no \"\(Self.demoTitle)\" calendar or list exists.")
            } else {
                print("Pocketd demo seed: removed \(removed.joined(separator: " and ")).")
            }
        }
    }
}
#endif
