import Foundation

/// A brief that has been written, and the day it was written about.
///
/// The snapshot travels with the text rather than being thrown away, and that is
/// what makes the Today tab honest after a relaunch. The paragraph is a
/// rendering of a moment — "Standup at 09:30 is next" — and without the numbers
/// beside it there is no way to tell, an hour later, whether the tiles under it
/// are describing the same day the sentence is. Carrying both means the whole
/// card is one value: either it is today's or it is not.
public struct DailyBrief: Sendable, Codable, Equatable {

    /// Who wrote it.
    ///
    /// Not a `Bool`, and not dropped, because the two differ in a way the user
    /// can see. The template brief is short and always the same shape; a model's
    /// is not. When somebody asks why this morning's brief reads differently
    /// from yesterday's, this field is the answer, and the model id is what says
    /// *which* brain — a person who switched models is entitled to know that the
    /// brief in front of them came from the old one.
    public enum Source: Sendable, Codable, Equatable {
        case template
        case model(id: String)

        public var modelID: String? {
            if case let .model(id) = self { return id }
            return nil
        }
    }

    public var text: String
    public var generatedAt: Date
    public var source: Source
    public var snapshot: TodaySnapshot

    public init(text: String, generatedAt: Date, source: Source, snapshot: TodaySnapshot) {
        self.text = text
        self.generatedAt = generatedAt
        self.source = source
        self.snapshot = snapshot
    }

    /// Whether this is still the brief for the day the reader is in.
    ///
    /// A calendar day and not an age in hours, because that is what the word
    /// "today" means to the person looking at the tab. A brief written at 23:50
    /// is ten minutes old at 00:10 and is about yesterday; one written at 06:00
    /// is fourteen hours old at 20:00 and is still about today. An age test gets
    /// both of those backwards.
    public func isForToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(generatedAt, inSameDayAs: now)
    }
}

extension DailyBrief.Source {
    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case template, model }

    /// Written by hand so the file stays legible on the Data screen.
    ///
    /// The synthesised encoding for an enum with an associated value nests an
    /// object per case — `{"model":{"id":"qwen3-1.7b"}}` — and this file is one
    /// a user is invited to go and read. `{"kind":"model","id":"qwen3-1.7b"}` is
    /// the same fact in a shape somebody can scan. The exhaustive switch is the
    /// other half: a third source breaks this build rather than silently
    /// encoding as something else.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .template: self = .template
        case .model: self = .model(id: try container.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .template:
            try container.encode(Kind.template, forKey: .kind)
        case let .model(id):
            try container.encode(Kind.model, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

// MARK: - Storage

/// Keeps the brief, in the app's own container and in the one the widget reads.
///
/// Two files, written together, because they answer to two different processes
/// and there is no third place that could keep them in step. The app-group copy
/// is not a cache of the first one: it is a *narrower* value, built by
/// `WidgetBrief.make`, and the narrowing is the privacy boundary rather than an
/// optimisation. Writing them in one call is what stops a refactor from keeping
/// one up to date and forgetting the other, which on a home screen means a
/// stranger reading yesterday's meeting off somebody's lock screen.
///
/// Both paths are injectable. Not for tidiness: `containerURL(forSecurity…)`
/// returns nil in every unit test and on any device build signed without the
/// group, so a store that could only find its own directories would be a store
/// with no tests.
public struct DailyBriefStore: Sendable {

    /// Named in `ContainerSurvey.kind(forRelativePath:)`, which is what puts it
    /// on the Data screen. Changing it here without changing it there files the
    /// user's brief under "Everything else in the container".
    public static let filename = "brief.json"

    private let directory: URL
    private let widget: WidgetBriefStore

    public init(directory: URL, widget: WidgetBriefStore = WidgetBriefStore()) {
        self.directory = directory
        self.widget = widget
    }

    /// The shorthand tests use: a real directory for the brief, a fake one for
    /// the mirror.
    public init(directory: URL, widgetDirectory: URL?) {
        self.init(directory: directory, widget: WidgetBriefStore(directory: widgetDirectory))
    }

    /// Application Support itself, not a subdirectory of it.
    ///
    /// There is one brief, it is replaced rather than accumulated, and a folder
    /// holding a single file is a folder somebody has to explain on the Data
    /// screen. `ScheduledTasks/` earns its directory by holding one file per
    /// task; this does not.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    public var fileURL: URL {
        directory.appendingPathComponent(Self.filename, isDirectory: false)
    }

    public func read() -> DailyBrief? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DailyBrief.self, from: data)
    }

    /// Stores the brief and republishes the widget's copy of it.
    ///
    /// Returns whether the brief itself landed. The mirror deliberately does not
    /// enter into that answer: on a build with no App Group there is no mirror
    /// to write, and reporting a failure the app cannot act on would push a
    /// pointless error path through the whole Today tab.
    @discardableResult
    public func write(
        _ brief: DailyBrief,
        name: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(brief) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic, because a background refresh and the foreground tab can
            // both be writing, and a half-written brief decodes as nothing
            // rather than as half a day.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return false
        }

        // Kept out of iCloud Backup, for the reason `ScheduledTaskStore` gives:
        // this file holds the rendered contents of the user's calendar,
        // reminders and sleep, which is personal data at rest in exactly the way
        // a transcript is. Set on the file rather than on Application Support,
        // which is shared with directories that make this decision for
        // themselves. Set on every write rather than at creation, because a file
        // that already exists from an older build would otherwise be backed up
        // forever.
        var mutable = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)

        // Last, and only once the brief itself is safely down. Published first,
        // a failed local write would leave the home screen showing a brief the
        // app does not have and cannot reproduce.
        widget.write(.make(from: brief, name: name, now: now, calendar: calendar, locale: locale))
        return true
    }

    /// Removes both copies.
    ///
    /// Both, in one call, because "delete everything" is a promise and a widget
    /// still showing this morning's greeting is that promise visibly unkept.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        widget.clear()
    }

    /// What the two files weigh, for the Data screen's total.
    ///
    /// Measured rather than estimated, and it includes the app-group copy — the
    /// container walk cannot see that one, because it is in a different
    /// container. A screen whose whole argument is that its numbers are
    /// checkable does not get to leave out the file it is hardest to find.
    public func byteCount(fileManager: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        for url in [fileURL, widget.fileURL].compactMap({ $0 }) {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
