import Foundation

/// Reads and writes the one file a widget is allowed to see.
///
/// Three processes touch this: the app on the main actor, a background refresh
/// with no app around it, and the widget extension. None of them coordinate, so
/// the write is atomic and the read tolerates every way a file can fail to be
/// there. A widget that cannot read its file shows the placeholder it already
/// has to have; nothing here is worth an error path in the app.
///
/// Not an actor, unlike `ScheduledTaskStore`. That one guards a read-modify-write
/// against a background refresh settling a firing while the user renames the
/// same task; this one only ever replaces a whole file with a value computed
/// elsewhere, so the atomic write IS the exclusion and an actor would buy
/// nothing but a hop.
public struct SchedulePublicationStore: Sendable {

    private let directory: URL?

    /// The shared container, or `nil` when there isn't one.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil when
    /// the App Group entitlement is missing — which is not hypothetical: it is
    /// what happens on a device build signed without the group registered on
    /// the App ID, and it is what happens in every unit test. Failing soft is
    /// deliberate. The alternative is an app that crashes on launch because a
    /// widget it does not need could not be fed.
    public init() {
        self.directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SchedulePublication.appGroup
        )
    }

    /// For tests, and for anything that wants to prove the encoding without a
    /// provisioning profile.
    public init(directory: URL?) {
        self.directory = directory
    }

    public var isAvailable: Bool { directory != nil }

    private var fileURL: URL? {
        directory?.appendingPathComponent(SchedulePublication.filename, isDirectory: false)
    }

    /// Replaces the published snapshot. Silent on failure, by design.
    @discardableResult
    public func write(_ publication: SchedulePublication) -> Bool {
        guard let fileURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(publication)
            // Atomic, because a widget may read this at any instant and a
            // half-written file decodes as nothing rather than as less.
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The published snapshot, or nil if there isn't a readable one.
    public func read() -> SchedulePublication? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SchedulePublication.self, from: data)
    }

    /// Removes it. Called when the user deletes their scheduled data, because a
    /// widget still showing "Morning briefing, 7:00" after the task behind it
    /// was erased is the deletion having visibly not happened.
    public func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
