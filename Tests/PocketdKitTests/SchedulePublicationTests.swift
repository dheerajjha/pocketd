import Foundation
import Testing
@testable import PocketdKit

/// The half of the widget that decides whether it is useful or indiscreet.
///
/// A widget is the most exposed surface this app has. A notification banner is
/// transient and a chat transcript is behind an unlock; a home screen is
/// permanent, lands in screenshots, and is read by people standing next to the
/// owner who were never shown a permission prompt. `NotificationCentre` already
/// refused to put a watcher's per-item lines on a lock screen for that reason,
/// and everything below is that argument applied to the harder case.
@Suite("Schedule publication")
struct SchedulePublicationTests {

    private static let calendar = Calendar(identifier: .gregorian)
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let seven = TimeOfDay(hour: 7, minute: 0)

    private static func prompt(_ text: String = "What is on today?") -> ScheduledTask {
        ScheduledTask(title: "Morning briefing", body: .prompt(text),
                      recurrence: .daily(at: seven), createdAt: now.addingTimeInterval(-86_400))
    }

    private static func watcher() -> ScheduledTask {
        ScheduledTask(title: "Anything due today",
                      body: .watcher(rule: .reminders(.today), notifyWhenEmpty: false),
                      recurrence: .daily(at: seven), createdAt: now.addingTimeInterval(-86_400))
    }

    private func encoded(_ publication: SchedulePublication) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(publication), as: UTF8.self)
    }

    // MARK: - The invariant the type exists for

    @Test("a run's text never reaches the published file")
    func outputNeverCrosses() throws {
        // Two distinct secrets, because the two task kinds leak differently. A
        // watcher's output is `report.text` — a headline AND per-item lines,
        // which are event titles written by whoever sent the invite and
        // routinely name other people. A prompt task's output is the model's
        // own answer about a calendar, a reminder list or a health record.
        let confidingLine = "Oncology follow-up with Dr Achebe"
        let modelAnswer = "You have a biopsy result review at 14:00."

        var watching = Self.watcher()
        watching.runs = [.reported(firing: Self.now, ranAt: Self.now, context: .deskMode,
                                   output: Untrusted("2 reminders today\n\(confidingLine)"))]
        var asking = Self.prompt()
        asking.runs = [.reported(firing: Self.now, ranAt: Self.now.addingTimeInterval(60),
                                 context: .foreground, output: Untrusted(modelAnswer))]

        let json = try encoded(.make(from: [watching, asking], now: Self.now, calendar: Self.calendar))

        #expect(!json.contains(confidingLine))
        #expect(!json.contains(modelAnswer))
        #expect(!json.contains("biopsy"))
        #expect(!json.contains("Achebe"))
        // And not the headline either. It is defensible on a banner and this is
        // the recoverable direction: a "show the headline" switch can be added
        // later, opt-in; nothing can un-show a home screen.
        #expect(!json.contains("2 reminders today"))
    }

    @Test("the titles that do cross are the user's own words")
    func titlesAreTheUsersOwn() throws {
        var task = Self.prompt()
        task.runs = [.reported(firing: Self.now, ranAt: Self.now, context: .foreground,
                               output: Untrusted("secret"))]
        let published = SchedulePublication.make(from: [task], now: Self.now, calendar: Self.calendar)
        // `TaskBody.prompt` is a plain `String` precisely because it is typed by
        // the phone's owner; everything a task READS is `Untrusted`. A title on
        // a home screen tells a stranger only what its owner chose to put there.
        #expect(published.latest?.title == "Morning briefing")
        #expect(published.next?.title == "Morning briefing")
    }

    // MARK: - What it says

    @Test("every outcome maps to a standing without reading any text")
    func standings() {
        #expect(SchedulePublication.Standing(.reported) == .reported)
        #expect(SchedulePublication.Standing(.nothingToReport) == .nothingToReport)
        #expect(SchedulePublication.Standing(.awaitingForeground) == .waiting)
        #expect(SchedulePublication.Standing(.failed(.noModelLoaded)) == .trouble)
        #expect(SchedulePublication.Standing(.failed(.lapsed)) == .trouble)
        #expect(SchedulePublication.Standing(.unauthorized(.denied)) == .trouble)
    }

    @Test("a paused task is never the next thing up")
    func pausedIsNotNext() {
        var task = Self.prompt()
        task.isEnabled = false
        let published = SchedulePublication.make(from: [task], now: Self.now, calendar: Self.calendar)
        // The widget contradicting the switch the user just turned off is worse
        // than the widget being empty.
        #expect(published.next == nil)
        #expect(published.enabledCount == 0)
    }

    @Test("a paused task's last run still shows")
    func pausedKeepsItsHistory() {
        var task = Self.prompt()
        task.runs = [.failed(.noModelLoaded, firing: Self.now, ranAt: Self.now, context: .deskMode)]
        task.isEnabled = false
        let published = SchedulePublication.make(from: [task], now: Self.now, calendar: Self.calendar)
        // A run that happened, happened. Hiding the last thing a task did
        // because it was paused afterwards loses the reason it was paused.
        #expect(published.latest?.standing == .trouble)
    }

    @Test("an owed firing is counted, not reported as the last run")
    func waitingIsNotARun() {
        var task = Self.prompt()
        task.runs = [.awaitingForeground(firing: Self.now, ranAt: Self.now, context: .backgroundRefresh)]
        let published = SchedulePublication.make(from: [task], now: Self.now, calendar: Self.calendar)
        // Counting a promise as a run describes one firing twice — the mistake
        // `ScheduledTask.settle` goes out of its way to avoid in the record.
        #expect(published.latest == nil)
        #expect(published.waitingCount == 1)
    }

    @Test("the earliest firing wins across tasks")
    func earliestWins() {
        let soon = ScheduledTask(title: "Soon", body: .watcher(rule: .reminders(.today), notifyWhenEmpty: false),
                                 recurrence: .daily(at: TimeOfDay(hour: 6, minute: 0)),
                                 createdAt: Self.now.addingTimeInterval(-86_400))
        let later = Self.prompt()
        let published = SchedulePublication.make(from: [later, soon], now: Self.now, calendar: Self.calendar)
        #expect(published.next?.title == "Soon")
    }

    @Test("a prompt task is published as needing a model")
    func needsModelCrosses() {
        let published = SchedulePublication.make(from: [Self.prompt()], now: Self.now, calendar: Self.calendar)
        // So the widget can say a 7am briefing will not appear by itself,
        // rather than letting the hour arrive and nothing happen.
        #expect(published.next?.needsModel == true)
        let watcherPublished = SchedulePublication.make(from: [Self.watcher()], now: Self.now, calendar: Self.calendar)
        #expect(watcherPublished.next?.needsModel == false)
    }

    // MARK: - The store

    @Test("a publication survives a round trip through the file")
    func roundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SchedulePublicationStore(directory: directory)
        let published = SchedulePublication.make(from: [Self.prompt()], now: Self.now, calendar: Self.calendar)
        #expect(store.write(published))
        #expect(store.read() == published)

        store.clear()
        // A widget still offering "Morning briefing, 7:00" after the task behind
        // it was erased is the deletion having visibly not happened.
        #expect(store.read() == nil)
    }

    @Test("no shared container is a quiet no, not a crash")
    func missingContainerFailsSoft() {
        let store = SchedulePublicationStore(directory: nil)
        // This is what a device build signed without the group registered on the
        // App ID actually does, and what every unit test does. An app that
        // cannot launch because a widget it does not need could not be fed is a
        // far worse failure than a widget that shows its placeholder.
        #expect(!store.isAvailable)
        #expect(!store.write(.empty(at: Self.now)))
        #expect(store.read() == nil)
        store.clear()
    }
}
