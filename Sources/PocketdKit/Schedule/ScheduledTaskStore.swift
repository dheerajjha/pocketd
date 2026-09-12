import Foundation

/// Reads and writes scheduled tasks as one JSON file per task.
///
/// Deliberately the same shape as `ConversationStore`, down to the date
/// strategy, and the reasons carry over one for one. One file each because a
/// task is rewritten on every settle — which for a watcher is once a day, from
/// a background wake-up — and rewriting every task in order to save one gets
/// slower the more the user has. Per-file because a corrupt write costs one
/// task instead of the whole schedule, on a device the kernel can kill
/// mid-write at any moment. Not a database, because the whole store is a few
/// kilobytes of text and the alternative costs a schema, a migration path and a
/// dependency.
///
/// One thing is added rather than mirrored: `update`. Two schedulers touch these
/// files — the background refresh handler and the foreground runner — and they
/// can be alive at the same moment, which was never true of the Chat tab. A
/// read-modify-write split across `all()` and `save()` loses one of them to
/// last-writer-wins; done inside the actor, it cannot.
public actor ScheduledTaskStore {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("ScheduledTasks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Kept out of iCloud Backup, for the reason `ConversationStore` gives
        // and one more of its own. A stored run record holds the rendered
        // contents of the user's calendar and reminders — that is the whole
        // point of a watcher — so these files are personal data at rest in
        // exactly the way a transcript is.
        //
        // Set on every call rather than only at creation: an install that
        // already has this directory would otherwise keep backing it up forever.
        var mutable = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
        return directory
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Must match the encoder below. The default strategy expects a bare
        // number and would reject every file this store has ever written.
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Every task, newest first.
    ///
    /// Newest first rather than next-to-fire first, which is what a schedule
    /// screen wants: "next to fire" is a function of `Date()` and a `Calendar`,
    /// and a store that sorted by it would be reading the clock on every call
    /// and returning a different order each time. The caller has both and can
    /// sort on `dueness(now:).next`.
    ///
    /// A file that fails to decode is skipped rather than thrown, and left on
    /// disk rather than deleted: one unreadable task must not make the schedule
    /// list unopenable, and a task written by a newer build is exactly the file
    /// that must survive a downgrade intact.
    public func all() -> [ScheduledTask] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = Self.decoder()
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> ScheduledTask? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ScheduledTask.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func task(_ id: UUID) -> ScheduledTask? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decoder().decode(ScheduledTask.self, from: data)
    }

    public func save(_ task: ScheduledTask) throws {
        // No guard for an "empty" task, and the absence is deliberate rather
        // than an oversight in the mirroring. `ConversationStore` refuses to
        // write an empty conversation because one exists before the user has
        // typed anything and would litter the history on every visit to the
        // tab. A task only exists once somebody has filled in a form and
        // pressed save; a blank title is a task with a blank title, not a draft.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(task)
        // Atomic: the kernel can kill this process at any moment — and for a
        // background refresh handler that has overrun its budget, *will* — and
        // a half-written schedule is worse than the previous one.
        try data.write(to: url(for: task.id), options: .atomic)
    }

    /// Read, change, write, without anyone else getting in between.
    ///
    /// The failure this exists for: a `BGAppRefreshTask` settles the 07:00
    /// watcher firing at the same moment the user, who has just opened the app,
    /// renames the task. Both read the file, both write it back, and whichever
    /// lands second erases the other's change — the rename reappearing under the
    /// old name, or the firing coming due again and notifying twice. Inside the
    /// actor the sequence is indivisible.
    ///
    /// Returns the saved task, or `nil` when there is no such file — a task
    /// deleted between a plan being made and its result being recorded, which
    /// is a normal race and not an error.
    @discardableResult
    public func update(_ id: UUID, _ change: @Sendable (inout ScheduledTask) -> Void) throws -> ScheduledTask? {
        guard var task = task(id) else { return nil }
        change(&task)
        try save(task)
        return task
    }

    public func delete(_ id: UUID) {
        try? fileManager.removeItem(at: url(for: id))
    }

    public func deleteAll() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".json") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
