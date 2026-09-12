import Foundation
import Testing
@testable import PocketdKit

/// What a schedule is allowed to cost when part of it cannot be read.
///
/// `ScheduledTaskStore` is `ConversationStore` with the names changed, and it
/// inherits the failure that file has a comment about: `all()` skips a file it
/// cannot decode, so anything that throws during decoding does not produce an
/// error — it produces a task that has silently disappeared, taking its
/// schedule with it. The tests here pin down which parts of a task are allowed
/// to do that.
///
/// The answer is a deliberate asymmetry. A **run record** is history of
/// something that already happened and can be thrown away; a **body** or a
/// **recurrence** is the task itself, and a build that cannot read one must
/// leave the file alone rather than guess.
@Suite("Scheduled task store")
struct ScheduleStoreTests {

    // MARK: - Fixtures

    private func store() throws -> (ScheduledTaskStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ScheduledTaskStore(directory: directory), directory)
    }

    private func sample(
        title: String = "Anything due today",
        body: TaskBody = .watcher(rule: .reminders(.today), notifyWhenEmpty: false),
        runs: [TaskRun] = []
    ) -> ScheduledTask {
        ScheduledTask(
            title: title,
            body: body,
            recurrence: .daily(at: TimeOfDay(hour: 8, minute: 30)),
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            runs: runs
        )
    }

    /// Encodes a real task, lets the caller corrupt one part of the JSON object,
    /// and writes it where the store will find it.
    ///
    /// Built from a genuine encode rather than from a hand-written literal so
    /// that the file is right in every respect except the one under test — a
    /// literal drifts from the encoder the first time a field is added, and
    /// then the test passes for the wrong reason.
    private func writeCorrupted(
        _ task: ScheduledTask,
        to directory: URL,
        _ corrupt: (inout [String: Any]) -> Void
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(task)
        ) as! [String: Any]
        corrupt(&object)
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent("\(task.id.uuidString).json"))
    }

    // MARK: - The ordinary path

    @Test("a task round-trips through the file it is written to")
    func roundTrip() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = sample()
        try await store.save(task)

        let loaded = try #require(await store.all().first)
        #expect(loaded == task)
        #expect(loaded.recurrence == .daily(at: TimeOfDay(hour: 8, minute: 30)))
    }

    @Test("one file per task, named by its id")
    func onePerTask() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = sample(title: "One")
        let second = sample(title: "Two")
        try await store.save(first)
        try await store.save(second)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names.count == 2)
        #expect(names.contains("\(first.id.uuidString).json"))
        // Per-file is the whole reason a corrupt write costs one task rather
        // than the schedule. A single-document store would make that untrue and
        // this assertion is what notices.
        #expect(await store.all().count == 2)
    }

    @Test("dates are written as ISO strings, because the reader expects them")
    func dateStrategyMatchesOnBothSides() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = sample()
        try await store.save(task)

        let data = try Data(contentsOf: directory.appendingPathComponent("\(task.id.uuidString).json"))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // A bare number here means somebody changed the encoder and not the
        // decoder — at which point every task already on a user's phone stops
        // decoding and the whole schedule vanishes with no error anywhere.
        #expect(object["createdAt"] is String)
        #expect(object["settledThrough"] is String)
    }

    @Test("settledThrough starts at creation, so a new task is not instantly overdue")
    func settledThroughDefaultsToCreation() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = sample()
        try await store.save(task)
        let loaded = try #require(await store.all().first)
        #expect(loaded.settledThrough == loaded.createdAt)
    }

    // MARK: - What survives a file it cannot read

    @Test("an unreadable file is skipped, and the others still load")
    func oneBadFileDoesNotEmptyTheList() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.save(sample(title: "Good"))
        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))

        let loaded = await store.all()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Good")
        // Left on disk, not deleted. Destroying the evidence would remove any
        // chance of recovering it — and a file this build cannot read is
        // exactly what a file written by a NEWER build looks like after a
        // downgrade.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test("a run record this build cannot read does not take the task with it")
    func lossyRunsKeepTheTask() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = sample(runs: [
            .nothingToReport(firing: Date(timeIntervalSince1970: 1_770_100_000), context: .backgroundRefresh)
        ])
        try writeCorrupted(task, to: directory) { object in
            // What a future build's extra outcome looks like from here.
            var runs = object["runs"] as! [[String: Any]]
            runs[0]["outcome"] = ["kind": "summarised"]
            object["runs"] = runs
        }

        let loaded = await store.all()
        // The task is the part the user made and cannot recreate. Before this
        // was lossy the whole row — title, rule and schedule — disappeared
        // because of one history entry.
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Anything due today")
        #expect(loaded.first?.runs.isEmpty == true)
    }

    @Test("one bad run does not discard the good ones beside it")
    func lossIsPerRun() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = Date(timeIntervalSince1970: 1_770_200_000)
        let task = sample(runs: [
            .nothingToReport(firing: Date(timeIntervalSince1970: 1_770_100_000), context: .backgroundRefresh),
            .nothingToReport(firing: good, context: .backgroundRefresh)
        ])
        try writeCorrupted(task, to: directory) { object in
            var runs = object["runs"] as! [[String: Any]]
            runs[0]["outcome"] = ["kind": "summarised"]
            object["runs"] = runs
        }

        let loaded = try #require(await store.all().first)
        #expect(loaded.runs.count == 1)
        #expect(loaded.runs.first?.firing == good)
    }

    @Test("an unknown authorization on a run is dropped rather than guessed at")
    func unknownAuthorizationDropsOnlyTheRun() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = sample(runs: [
            .unauthorized(.denied, firing: Date(timeIntervalSince1970: 1_770_100_000), context: .backgroundRefresh)
        ])
        try writeCorrupted(task, to: directory) { object in
            var runs = object["runs"] as! [[String: Any]]
            var outcome = runs[0]["outcome"] as! [String: Any]
            outcome["detail"] = "partial_access"     // iOS 21, say
            runs[0]["outcome"] = outcome
            object["runs"] = runs
        }

        let loaded = try #require(await store.all().first)
        // Defaulting to `.denied` would have put "turn it on in Settings" on
        // screen for a permission state this build knows nothing about.
        #expect(loaded.runs.isEmpty)
        #expect(loaded.title == "Anything due today")
    }

    @Test("a body this build cannot read skips the task instead of guessing")
    func unknownBodyIsNotLossy() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.save(sample(title: "Readable"))
        let future = sample(title: "From a later build")
        try writeCorrupted(future, to: directory) { object in
            object["body"] = ["digest": ["window": "week"]]
        }

        let loaded = await store.all()
        // The asymmetry with runs, and it is the deliberate half. A task whose
        // rule this build does not understand is not a task it can run;
        // substituting a default would give the user a row that looks scheduled
        // and does the wrong thing at the right time.
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Readable")
        // ...and the file it could not read is still there for the build that can.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test("a recurrence this build cannot read skips the task too")
    func unknownRecurrenceIsNotLossy() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let future = sample(title: "Every other Tuesday")
        try writeCorrupted(future, to: directory) { object in
            object["recurrence"] = ["fortnightly": ["days": ["tuesday"]]]
        }
        #expect(await store.all().isEmpty)
    }

    @Test("a task written before a field existed still loads")
    func missingFieldsAreForwardCompatible() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = sample()
        try writeCorrupted(task, to: directory) { object in
            // What the first release wrote.
            object["isEnabled"] = nil
            object["updatedAt"] = nil
            object["settledThrough"] = nil
            object["runs"] = nil
        }

        let loaded = try #require(await store.all().first)
        #expect(loaded.isEnabled)
        #expect(loaded.updatedAt == loaded.createdAt)
        // Falling back to `createdAt` and not to `.distantPast`: the latter
        // would make every task written by an older build immediately overdue
        // for every firing since it was created.
        #expect(loaded.settledThrough == loaded.createdAt)
    }

    // MARK: - Writing

    @Test("update reads, changes and writes without anyone getting in between")
    func updateIsAtomic() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = sample()
        try await store.save(task)

        let firing = Date(timeIntervalSince1970: 1_770_300_000)
        try await store.update(task.id) { task in
            task.settle(.nothingToReport(firing: firing, context: .backgroundRefresh), at: firing)
        }

        let loaded = try #require(await store.task(task.id))
        #expect(loaded.settledThrough == firing)
        #expect(loaded.runs.count == 1)
    }

    @Test("updating a task that has been deleted is a nil, not a crash")
    func updateOnAMissingTask() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The real race: a background refresh plans a run, the user deletes the
        // task, the refresh comes back to record what happened.
        let result = try await store.update(UUID()) { $0.title = "never" }
        #expect(result == nil)
    }

    @Test("delete removes one task and deleteAll removes them all")
    func deletion() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = sample(title: "One")
        try await store.save(first)
        try await store.save(sample(title: "Two"))

        await store.delete(first.id)
        #expect(await store.all().count == 1)

        await store.deleteAll()
        #expect(await store.all().isEmpty)
    }

    // MARK: - What a run record is holding

    @Test("a stored result comes back wrapped, not as a bare String")
    func outputIsUntrusted() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A watcher's result is built from calendar titles, which are written
        // by whoever sent the invite. It is stored, and stored text gets
        // replayed into later prompts — which is the whole reason `Untrusted`
        // exists.
        let task = sample(runs: [
            .reported(
                firing: Date(timeIntervalSince1970: 1_770_100_000),
                context: .backgroundRefresh,
                output: Untrusted("1 event today\nThu 11 Sep, 14:00 — Dentist")
            )
        ])
        try await store.save(task)

        let run = try #require(await store.all().first?.runs.first)
        let output = try #require(run.output)
        #expect(output.attackerControlledValue().contains("Dentist"))
        // Interpolating it cannot paste the text into a prompt by accident.
        #expect("\(output)" == "Untrusted<String>(redacted)")
    }

    @Test("only a reported run has output; the others have nothing to hand back")
    func nonReportedRunsHaveNoOutput() async throws {
        let firing = Date(timeIntervalSince1970: 1_770_100_000)
        #expect(TaskRun.nothingToReport(firing: firing, context: .backgroundRefresh).output == nil)
        #expect(TaskRun.awaitingForeground(firing: firing, context: .backgroundRefresh).output == nil)
        #expect(TaskRun.failed(.interrupted, firing: firing, context: .deskMode).output == nil)
        // An empty string here would make "nothing to report" and "reported
        // nothing" indistinguishable at every call site.
        #expect(TaskRun.unauthorized(.denied, firing: firing, context: .backgroundRefresh).output == nil)
    }
}
