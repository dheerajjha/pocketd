import Foundation

/// Reads and writes the one file the Today widget is allowed to see.
///
/// A line-for-line sibling of `SchedulePublicationStore`, and deliberately a
/// separate type rather than a generic one over both payloads. The two files are
/// written by different code at different moments — the schedule publication
/// after anything that changes a task, this one after a brief is generated — and
/// a shared generic would invite a single "publish everything" call that rewrote
/// both on every change, which is how a widget ends up reloading its timeline
/// for a file whose contents did not move.
///
/// Not an actor, for the same reason that one is not: this only ever replaces a
/// whole file with a value computed elsewhere, so the atomic write IS the
/// exclusion and an actor would buy nothing but a hop.
public struct WidgetBriefStore: Sendable {

    private let directory: URL?

    /// The shared container, or `nil` when there isn't one.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil when
    /// the App Group entitlement is missing, which is what happens on a device
    /// build signed without the group registered on the App ID and what happens
    /// in every unit test. Failing soft is deliberate: the alternative is an app
    /// that cannot write a brief because a widget it does not need could not be
    /// fed.
    public init() {
        self.directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetBrief.appGroup
        )
    }

    /// For tests, and for anything that wants to prove the encoding without a
    /// provisioning profile.
    public init(directory: URL?) {
        self.directory = directory
    }

    public var isAvailable: Bool { directory != nil }

    /// Public so the Data screen can weigh it. The container walk cannot: this
    /// file is in the shared container, which is not the app's own, so it is the
    /// one file the app writes that an inventory of its container will never
    /// find on its own.
    public var fileURL: URL? {
        directory?.appendingPathComponent(WidgetBrief.filename, isDirectory: false)
    }

    /// Replaces the published brief. Silent on failure, by design.
    @discardableResult
    public func write(_ brief: WidgetBrief) -> Bool {
        guard let fileURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(brief)
            // Atomic, because a widget may read this at any instant and a
            // half-written file decodes as nothing rather than as less.
            try data.write(to: fileURL, options: .atomic)
            // The brief quotes the day — event times, sleep — so it stays off
            // iCloud Backup like the app's own copy (`DailyBrief`). Set after
            // every write: an atomic write replaces the file, and the flag
            // belongs to the file it was set on.
            var fileToMark = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? fileToMark.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    public func read() -> WidgetBrief? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetBrief.self, from: data)
    }

    /// Removes it. Called when the user deletes their stored data, because a
    /// widget still greeting them by name after the brief behind it was erased
    /// is the deletion having visibly not happened.
    public func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
