import Foundation

/// A named, persisted conversation.
///
/// Transcripts used to live in a single in-memory array, which meant every one
/// of them ended at the next force-quit, iOS memory reclaim, or crash — and
/// this app loads multi-gigabyte models, so reclaim is not hypothetical. The
/// browser chat this same phone serves has kept its history in `localStorage`
/// since V2; the native app, which is where people actually type, kept nothing.
public struct Conversation: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The model that produced it. Shown in the history list because a reply's
    /// quality is meaningless without knowing what wrote it, and on this app
    /// the resident model can change underneath a conversation when a request
    /// arrives from another device.
    public var modelID: String?
    public var messages: [ChatMessage]
    /// Unsent text, kept per conversation so switching away and back does not
    /// silently discard a half-written message.
    public var draft: String

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        modelID: String? = nil,
        messages: [ChatMessage] = [],
        draft: String = ""
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelID = modelID
        self.messages = messages
        self.draft = draft
    }

    public var isEmpty: Bool { messages.isEmpty && draft.isEmpty }

    /// What to show in a list. Falls back to the first thing said, because an
    /// untitled row is indistinguishable from every other untitled row.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        guard let first = messages.first(where: { $0.role == .user || $0.role == .assistant }) else {
            return "New conversation"
        }
        let flattened = first.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.isEmpty { return "New conversation" }
        return flattened.count <= 48 ? flattened : String(flattened.prefix(48)) + "…"
    }
}

/// Reads and writes conversations as one JSON file per conversation.
///
/// One file each rather than a single document: a transcript is appended to on
/// every token, and rewriting every conversation ever held in order to save one
/// of them gets slower the longer someone uses the app. Per-file also means a
/// corrupt write costs one conversation instead of all of them — this runs on a
/// device that can be killed by the kernel mid-write at any moment.
///
/// Deliberately not a database. The whole store is a few hundred kilobytes of
/// text, and the alternative costs a schema, a migration path and a dependency.
public actor ConversationStore {
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
        let directory = support.appendingPathComponent("Conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Every conversation, newest first.
    ///
    /// A file that fails to decode is skipped rather than thrown, and left on
    /// disk rather than deleted: one unreadable transcript must not make the
    /// history list unopenable, and silently destroying the evidence would
    /// remove any chance of recovering it later.
    public func all() -> [Conversation] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        // Must match save()'s encoder. The default strategy expects a bare
        // number and would reject every file this store has ever written.
        decoder.dateDecodingStrategy = .iso8601
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> Conversation? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Conversation.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ conversation: Conversation) throws {
        // An empty conversation is what you are looking at before you have said
        // anything. Writing one would put a "New conversation" row in the
        // history every time the Chat tab is opened.
        guard !conversation.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(conversation)
        // Atomic: the kernel can kill this process at any moment, and a
        // half-written transcript is worse than the previous one.
        try data.write(to: url(for: conversation.id), options: .atomic)
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
