import Foundation
import Testing
@testable import PocketdKit

/// Two files, written together, one of which ends up on a home screen.
///
/// The round trip is the cheap half. The half worth the file is what crosses
/// into the App Group copy and what does not: `SchedulePublication` refused to
/// publish a single word of a run's output because a home screen is permanent,
/// sits in screenshots and is read by people who were never shown a permission
/// prompt, and the Today widget cannot be allowed to quietly undo that argument
/// by shipping the whole brief, the reminder list and last night's sleep into
/// the same folder.
@Suite("Daily brief store")
struct DailyBriefStoreTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ hour: Int, _ minute: Int = 0, day: Int = 17) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    static func snapshot() -> TodaySnapshot {
        TodaySnapshot(
            generatedAt: date(7, 30),
            calendar: .connected,
            reminders: .connected,
            health: .connected,
            events: [
                BriefEvent(title: "Oncology follow-up", start: date(9, 30), end: date(10, 30)),
                BriefEvent(title: "Dentist", start: date(14), end: date(15)),
            ],
            dueToday: [BriefReminder(title: "Collect prescription"), BriefReminder(title: "Call Mum")],
            overdue: [BriefReminder(title: "Renew passport")],
            sleepLastNight: 6 * 3600 + 36 * 60,
            sleepUsual: 8 * 3600,
            stepsToday: 4_120,
            stepsUsual: 6_100,
            restingHeartRate: 58
        )
    }

    static func brief(
        text: String = "Good morning, Dheeraj. Oncology follow-up at 09:30 is next, and you slept 6h 36m.",
        source: DailyBrief.Source = .model(id: "qwen3-1.7b")
    ) -> DailyBrief {
        DailyBrief(text: text, generatedAt: date(7, 30), source: source, snapshot: snapshot())
    }

    /// A pair of throwaway directories standing in for Application Support and
    /// the shared container. The real ones are unavailable in a test — there is
    /// no App Group without a provisioning profile — which is exactly why both
    /// paths are injectable.
    static func directories() throws -> (app: URL, group: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-brief-\(UUID().uuidString)")
        let app = root.appendingPathComponent("app")
        let group = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        return (app, group)
    }

    // MARK: - Round trip

    @Test("a brief written is a brief read back")
    func roundTrip() throws {
        let (app, group) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let store = DailyBriefStore(directory: app, widgetDirectory: group)
        #expect(store.read() == nil)
        #expect(store.write(Self.brief(), name: "Dheeraj", now: Self.date(7, 30), calendar: Self.calendar))
        #expect(store.read() == Self.brief())
        #expect(store.fileURL.lastPathComponent == "brief.json")
    }

    @Test("the source survives, so a brief can be attributed to the brain that wrote it")
    func sourceRoundTrips() throws {
        let (app, group) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let store = DailyBriefStore(directory: app, widgetDirectory: group)

        store.write(Self.brief(source: .template), now: Self.date(7, 30), calendar: Self.calendar)
        #expect(store.read()?.source == .template)
        #expect(store.read()?.source.modelID == nil)

        store.write(Self.brief(source: .model(id: "qwen3-1.7b")), now: Self.date(7, 30), calendar: Self.calendar)
        #expect(store.read()?.source.modelID == "qwen3-1.7b")

        // Legible on the Data screen, which is a file a user is invited to read.
        let json = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        #expect(json.contains(#""kind":"model""#))
        #expect(json.contains(#""id":"qwen3-1.7b""#))
    }

    @Test("an unreadable file is nothing, not a crash")
    func corruptFileReadsAsNil() throws {
        let (app, group) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let store = DailyBriefStore(directory: app, widgetDirectory: group)
        try Data("half a brie".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)
    }

    // MARK: - The mirror

    @Test("the widget copy is written beside the brief, in the shared folder")
    func mirrorIsWritten() throws {
        let (app, group) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let store = DailyBriefStore(directory: app, widgetDirectory: group)
        store.write(Self.brief(), name: "Dheeraj", now: Self.date(7, 30), calendar: Self.calendar)

        let widget = WidgetBriefStore(directory: group)
        let published = try #require(widget.read())
        #expect(published.greetingLine == "Good morning, Dheeraj")
        #expect(published.firstSentence == "Good morning, Dheeraj.")
        #expect(published.nextEventTitle == "Oncology follow-up")
        #expect(published.nextEventTime == Self.date(9, 30))
        #expect(published.dueCount == 2)
        #expect(published.generatedAt == Self.date(7, 30))
        #expect(FileManager.default.fileExists(atPath: group.appendingPathComponent("today-brief.json").path))
    }

    @Test("what the home screen is told stops well short of what the app knows")
    func mirrorWithholdsTheRest() throws {
        let (app, group) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let store = DailyBriefStore(directory: app, widgetDirectory: group)
        store.write(
            Self.brief(text: "Good morning, Dheeraj. Oncology follow-up at 09:30 is next. Collect your prescription and renew your passport, and you slept 6h 36m against a usual of 8h."),
            name: "Dheeraj", now: Self.date(7, 30), calendar: Self.calendar
        )
        let json = String(decoding: try Data(contentsOf: group.appendingPathComponent("today-brief.json")), as: UTF8.self)

        // The first sentence crosses because the widget exists to show it. The
        // rest of the paragraph does not.
        #expect(json.contains("Good morning, Dheeraj."))
        #expect(!json.contains("prescription"))
        #expect(!json.contains("passport"))
        // Reminder titles never cross — a count discloses nothing and answers
        // the whole of what a glance wants.
        #expect(!json.contains("Call Mum"))
        // Nor do the body numbers. They are the most sensitive figures this app
        // holds and a widget is the least private surface it has.
        #expect(!json.contains("6h 36m"))
        #expect(!json.contains("4120"))
        #expect(!json.contains("58"))
    }

    @Test("a switched-off calendar publishes nothing rather than an empty day")
    func mirrorDistinguishesOffFromClear() throws {
        let (app, group) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        var snapshot = Self.snapshot()
        snapshot.calendar = .off
        snapshot.reminders = .off
        let store = DailyBriefStore(directory: app, widgetDirectory: group)
        store.write(
            DailyBrief(text: "Good evening.", generatedAt: Self.date(20), source: .template, snapshot: snapshot),
            name: nil, now: Self.date(20), calendar: Self.calendar
        )

        let published = try #require(WidgetBriefStore(directory: group).read())
        // Nil rather than a title, so the widget can tell "your day is clear"
        // from "I cannot see your day".
        #expect(published.nextEventTitle == nil)
        #expect(published.nextEventTime == nil)
        #expect(published.dueCount == 0)
        #expect(published.greetingLine == "Good evening")
    }

    @Test("the first sentence is the brief's own, and a decimal point does not end it")
    func firstSentence() {
        #expect(WidgetBrief.firstSentence(of: "One. Two. Three.") == "One.")
        #expect(WidgetBrief.firstSentence(of: "You walked 4.2 km today. Nice.") == "You walked 4.2 km today.")
        #expect(WidgetBrief.firstSentence(of: "A brief with no stop") == "A brief with no stop")
        #expect(WidgetBrief.firstSentence(of: "  Padded. ") == "Padded.")
    }

    @Test("no shared container is not an error the app has to handle")
    func missingAppGroupIsSilent() throws {
        // `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil on
        // any build signed without the group. Refusing to save the brief over it
        // would be an app that cannot brief you because a widget could not be
        // fed.
        let (app, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let store = DailyBriefStore(directory: app, widgetDirectory: nil)
        #expect(store.write(Self.brief(), now: Self.date(7, 30), calendar: Self.calendar))
        #expect(store.read() == Self.brief())
        #expect(WidgetBriefStore(directory: nil).isAvailable == false)
    }

    // MARK: - Deletion

    @Test("clearing removes the home screen's copy as well")
    func clearRemovesBoth() throws {
        let (app, group) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let store = DailyBriefStore(directory: app, widgetDirectory: group)
        store.write(Self.brief(), name: "Dheeraj", now: Self.date(7, 30), calendar: Self.calendar)
        #expect(store.byteCount() > 0)

        store.clear()
        // A widget still greeting somebody by name after they deleted their data
        // is the deletion having visibly not happened.
        #expect(store.read() == nil)
        #expect(WidgetBriefStore(directory: group).read() == nil)
        #expect(store.byteCount() == 0)
    }

    @Test("the byte total counts the copy the container walk cannot see")
    func byteCountIncludesTheSharedFolder() throws {
        let (app, group) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let store = DailyBriefStore(directory: app, widgetDirectory: group)
        store.write(Self.brief(), name: "Dheeraj", now: Self.date(7, 30), calendar: Self.calendar)

        let local = DailyBriefStore(directory: app, widgetDirectory: nil).byteCount()
        #expect(store.byteCount() > local)
    }

    @Test("both files are named on the Data screen rather than filed under everything else")
    func filesAreClassified() {
        #expect(ContainerSurvey.kind(forRelativePath: "Library/Application Support/brief.json") == .dailyBrief)
        #expect(ContainerSurvey.kind(forRelativePath: "today-brief.json") == .dailyBrief)
        #expect(StoredDataKind.dailyBrief.disposal.isDeletableHere)
        // And a file that merely shares a name somewhere else is not claimed —
        // silently misfiling is what `.other` exists to prevent.
        #expect(ContainerSurvey.kind(forRelativePath: "Library/Caches/x/brief.json") == .networkCache)
    }

    @Test("delete everything names the brief and counts it")
    func deletionPlanCountsTheBrief() {
        let plan = DeletionPlan.deleteEverything(
            installedModelBytes: 0, orphanBytes: 0, conversationBytes: 0,
            scheduledTaskBytes: 0, dailyBriefBytes: 900,
            partialDownloadBytes: 0, networkCacheBytes: 0, downloadInFlight: false
        )
        #expect(plan.byteCount == 900)
        #expect(plan.included.map(\.name) == [DeletionPlan.EntryName.dailyBrief])
    }

    // MARK: - Which day it is

    @Test("a brief belongs to a calendar day, not to the last N hours")
    func isForTodayAcrossMidnight() {
        let lateLastNight = DailyBrief(
            text: "…", generatedAt: Self.date(23, 50, day: 17), source: .template, snapshot: Self.snapshot()
        )
        // Ten minutes old and about yesterday. An age test gets this backwards.
        #expect(lateLastNight.isForToday(now: Self.date(23, 55, day: 17), calendar: Self.calendar))
        #expect(!lateLastNight.isForToday(now: Self.date(0, 10, day: 18), calendar: Self.calendar))

        let thisMorning = DailyBrief(
            text: "…", generatedAt: Self.date(6, day: 18), source: .template, snapshot: Self.snapshot()
        )
        // Fourteen hours old and still about today.
        #expect(thisMorning.isForToday(now: Self.date(20, day: 18), calendar: Self.calendar))
        #expect(!thisMorning.isForToday(now: Self.date(6, day: 19), calendar: Self.calendar))
    }

    @Test("the day is the reader's day, in the reader's zone")
    func isForTodayFollowsTheCalendar() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 22:00 UTC on the 17th is already the 18th in Tokyo, so a brief written
        // then is today's there and yesterday's here.
        let brief = DailyBrief(
            text: "…", generatedAt: Self.date(22, day: 17), source: .template, snapshot: Self.snapshot()
        )
        #expect(brief.isForToday(now: Self.date(23, day: 17), calendar: Self.calendar))
        #expect(brief.isForToday(now: Self.date(23, day: 17), calendar: tokyo))
        // 10:00 UTC is 19:00 the previous Tokyo day, so the same brief and the
        // same instant answer differently in the two zones.
        #expect(!brief.isForToday(now: Self.date(10, day: 17), calendar: tokyo))
    }
}
