import Foundation
import Testing
@testable import PocketdKit

/// What happens to a routine somebody already has when this build reads it.
///
/// The case worth the most is the first one: every v2 user who finished the
/// intro has a "Morning brief" on disk that is a free-text prompt, and from
/// this build on the morning brief is Today's brief announced at the hour they
/// chose. If the migration missed that file, the person would keep getting
/// "Tap to run it — Pocketd can only think while it is open" every morning and
/// a second paragraph about their day on a screen that no longer shows one.
@Suite("Routine migration")
struct RoutineMigrationTests {

    static let created = Date(timeIntervalSince1970: 1_789_400_000)

    static let morningPrompt = """
        Write my brief for today in two or three sentences: what is next on my calendar, \
        what is due, and how I slept. Warm and plain. No lists and no headings. \
        Only mention things you actually found.
        """

    static let eveningPrompt = """
        Look back over today and ahead to tomorrow. In two or three sentences: what was on \
        today, what is still open on my list, and what tomorrow starts with. \
        Warm and plain. No lists and no headings. Only mention things you actually found.
        """

    static func encode(_ task: ScheduledTask) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(task)
    }

    static func decode(_ data: Data) throws -> ScheduledTask {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScheduledTask.self, from: data)
    }

    /// A task exactly as v2 saved it. `ScheduledTask.init` does not migrate —
    /// only reading does — so encoding this produces the bytes an older build
    /// wrote.
    static func legacy(
        title: String = "Morning brief",
        prompt: String = morningPrompt,
        runs: [TaskRun] = []
    ) -> ScheduledTask {
        ScheduledTask(
            title: title,
            body: .prompt(prompt),
            recurrence: .weekdays(at: TimeOfDay(hour: 7, minute: 30)),
            createdAt: created,
            runs: runs
        )
    }

    // MARK: - The two briefs

    @Test("a stored morning brief prompt is read back as a brief")
    func morningBriefBecomesABrief() throws {
        let original = Self.legacy()
        let read = try Self.decode(try Self.encode(original))
        #expect(read.body == .brief)
        #expect(read.body.needsModel == false)
        // Nothing else about the routine moves: same file, same name, same
        // hour, same days, same place in the schedule.
        #expect(read.id == original.id)
        #expect(read.title == "Morning brief")
        #expect(read.recurrence == original.recurrence)
        #expect(read.settledThrough == original.settledThrough)
        #expect(read.isEnabled)
    }

    @Test("the evening wrap-up prompt is a brief too, under whatever name it has now")
    func eveningWrapUpBecomesABriefEvenRenamed() throws {
        // Matched on the words, not the title: somebody who renamed it "Night
        // check" still has the template's prompt, and still wants the brief.
        let read = try Self.decode(try Self.encode(Self.legacy(title: "Night check", prompt: Self.eveningPrompt)))
        #expect(read.body == .brief)
        #expect(read.title == "Night check")
    }

    @Test("a file written by the v2 build, byte for byte, is migrated")
    func literalV2FileIsMigrated() throws {
        // Written out rather than produced by today's encoder, so a change to
        // how `TaskBody` or `Recurrence` encode cannot quietly stop old files
        // from matching.
        let json = """
            {"id":"7A0B2D2C-1111-4C3B-9F00-000000000001","title":"Morning brief",
             "body":{"prompt":{"_0":"\(Self.morningPrompt)"}},
             "recurrence":{"weekly":{"days":[2,3,4,5,6],"at":{"hour":7,"minute":30}}},
             "isEnabled":true,"createdAt":"2026-09-14T20:00:00Z",
             "updatedAt":"2026-09-14T20:00:00Z","settledThrough":"2026-09-15T07:30:00Z"}
            """
        let read = try Self.decode(Data(json.utf8))
        #expect(read.body == .brief)
        #expect(read.recurrence == .weekdays(at: TimeOfDay(hour: 7, minute: 30)))
    }

    @Test("whitespace a text editor added does not stop the match")
    func whitespaceIsForgiven() throws {
        let folded = "  " + Self.morningPrompt.replacingOccurrences(of: ". ", with: ".\n") + "\n"
        let read = try Self.decode(try Self.encode(Self.legacy(prompt: folded)))
        #expect(read.body == .brief)
    }

    @Test("promises to write the old paragraph are dropped, and real history is kept")
    func promisesAreDroppedHistoryKept() throws {
        let monday = Self.created.addingTimeInterval(86_400)
        let tuesday = monday.addingTimeInterval(86_400)
        let runs: [TaskRun] = [
            .reported(firing: monday, ranAt: monday, context: .foreground, output: Untrusted("Standup at 9:30 is next.")),
            .failed(.noModelLoaded, firing: monday.addingTimeInterval(1), ranAt: monday, context: .foreground),
            .awaitingForeground(firing: tuesday, ranAt: tuesday, context: .backgroundRefresh),
        ]
        let read = try Self.decode(try Self.encode(Self.legacy(runs: runs)))
        #expect(read.body == .brief)
        #expect(read.runs.contains(where: \.isAwaitingForeground) == false)
        #expect(read.runs.count == 2)
        #expect(read.lastCompletedRun?.outcome == .failed(.noModelLoaded))
        // Nothing left to collect, so nothing waits on the widget or the card.
        #expect(read.pendingRun(now: tuesday.addingTimeInterval(60)) == nil)
    }

    // MARK: - What is left alone

    @Test("a prompt the user edited stays theirs")
    func editedPromptIsUntouched() throws {
        let edited = Self.morningPrompt + " Mention the weather."
        let read = try Self.decode(try Self.encode(Self.legacy(prompt: edited)))
        #expect(read.body == .prompt(edited))
    }

    @Test("the weekly review and every other question are left as questions")
    func otherPromptsAreUntouched() throws {
        guard case let .prompt(review) = RoutineTemplate.weeklyReview.body else {
            Issue.record("the weekly review should be a prompt")
            return
        }
        let read = try Self.decode(try Self.encode(Self.legacy(title: "Weekly review", prompt: review)))
        #expect(read.body == .prompt(review))
        let mine = try Self.decode(try Self.encode(Self.legacy(title: "Brief", prompt: "What is on this weekend?")))
        #expect(mine.body == .prompt("What is on this weekend?"))
    }

    @Test("v1's calendar rule called Morning briefing stays a rule")
    func v1RuleStaysARule() throws {
        // It already works while the app is closed, which is what the brief
        // migration is for; turning it into something else would change what
        // somebody's 07:00 says without them asking.
        let rule = ScheduledTask(
            title: "Morning briefing",
            body: .watcher(rule: .events(.today), notifyWhenEmpty: false),
            recurrence: .daily(at: TimeOfDay(hour: 7, minute: 0)),
            createdAt: Self.created
        )
        let read = try Self.decode(try Self.encode(rule))
        #expect(read == rule)
    }

    // MARK: - The rename

    @Test("Overdue watcher is now Overdue nudge, when it is still the template's rule")
    func overdueWatcherIsRenamed() throws {
        var task = RoutineTemplate.overdueWatcher.task(now: Self.created)
        task.title = "Overdue watcher"
        let read = try Self.decode(try Self.encode(task))
        #expect(read.title == "Overdue nudge")
        #expect(read.body == .watcher(rule: .reminders(.overdue), notifyWhenEmpty: false))
    }

    @Test("a routine of the user's own that happens to share the old name keeps it")
    func ownOverdueWatcherKeepsItsName() throws {
        var task = RoutineTemplate.overdueWatcher.task(now: Self.created)
        task.title = "Overdue watcher"
        task.body = .watcher(rule: .reminders(.today), notifyWhenEmpty: true)
        let read = try Self.decode(try Self.encode(task))
        #expect(read.title == "Overdue watcher")
    }

    // MARK: - Safety

    @Test("migrating twice is migrating once")
    func idempotent() throws {
        let once = try Self.decode(try Self.encode(Self.legacy()))
        let twice = try Self.decode(try Self.encode(once))
        #expect(once == twice)
        #expect(RoutineMigration.migrated(once) == once)
    }

    @Test("a brief round-trips, and the store hands back migrated routines")
    func storeReadsMigrated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = Self.legacy()
        try Self.encode(old).write(to: directory.appendingPathComponent("\(old.id.uuidString).json"))
        let store = ScheduledTaskStore(directory: directory)

        let all = await store.all()
        #expect(all.count == 1)
        #expect(all.first?.body == .brief)

        // Written back the first time anything settles it, and read back as a
        // brief from then on with no migration left to do.
        try await store.update(old.id) { $0.updatedAt = $0.updatedAt.addingTimeInterval(1) }
        let raw = try String(contentsOf: directory.appendingPathComponent("\(old.id.uuidString).json"), encoding: .utf8)
        #expect(raw.contains("\"brief\""))
        #expect(!raw.contains("Write my brief"))
        #expect(await store.task(old.id)?.body == .brief)
    }
}
