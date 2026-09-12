import Foundation

/// One file this app has written, as it will be shown to the person who owns it.
public struct StoredFile: Sendable, Equatable, Identifiable {
    /// Path relative to the container root, so the value is both a stable
    /// identity and something a user can go and check.
    public var path: String
    public var byteCount: Int64
    public var modifiedAt: Date?

    public var id: String { path }

    public init(path: String, byteCount: Int64, modifiedAt: Date? = nil) {
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// How many files, how many bytes, and how far back they go.
public struct DirectoryTally: Sendable, Equatable {
    public var fileCount: Int
    public var byteCount: Int64
    public var oldest: Date?
    public var newest: Date?

    public static let empty = DirectoryTally(fileCount: 0, byteCount: 0)

    public init(fileCount: Int = 0, byteCount: Int64 = 0, oldest: Date? = nil, newest: Date? = nil) {
        self.fileCount = fileCount
        self.byteCount = byteCount
        self.oldest = oldest
        self.newest = newest
    }

    public var isEmpty: Bool { fileCount == 0 }

    public mutating func add(_ file: StoredFile) {
        fileCount += 1
        byteCount += file.byteCount
        guard let date = file.modifiedAt else { return }
        oldest = min(oldest ?? date, date)
        newest = max(newest ?? date, date)
    }
}

/// What a pile of bytes in the container is, and who is allowed to remove it.
public enum StoredDataKind: String, Sendable, CaseIterable, Codable {
    case models
    case conversations
    /// Tasks the user set up to run later, and what each run produced.
    ///
    /// Its own kind rather than folded into conversations, because the content
    /// is different in the way that matters on this screen: a scheduled task
    /// stores a prompt the user wrote AND the rendered result of reading their
    /// calendar, reminders or health. A briefing that says "dentist at 11" is
    /// personal data at rest, written by a run nobody watched.
    case scheduledTasks
    /// The two halves of a download that stopped: the resume blob the app
    /// wrote, and the multi-gigabyte temporary file URLSession is holding for
    /// it. They are one thing to a user and are counted as one.
    case partialDownloads
    case preferences
    case networkCache
    case shaderCache
    /// Screenshots and window state iOS writes into this app's container
    /// without asking it.
    case systemState
    /// Whatever no rule above claimed. Never merged away, never rounded to
    /// zero: this is the case that stops the screen quietly under-reporting
    /// when a future iOS starts writing somewhere new.
    case other

    public var title: String {
        switch self {
        case .models: "Models"
        case .conversations: "Conversations"
        case .scheduledTasks: "Scheduled tasks"
        case .partialDownloads: "Unfinished downloads"
        case .preferences: "Settings and keys"
        case .networkCache: "Network cache"
        case .shaderCache: "GPU shader cache"
        case .systemState: "What iOS keeps about this app"
        case .other: "Everything else in the container"
        }
    }

    /// What is actually in it, in the terms a person would use.
    public var detail: String {
        switch self {
        case .models:
            "The weights you downloaded, and the file listing them. Nothing here is about you."
        case .conversations:
            "Everything typed in the Chat tab and everything the model replied, one file per conversation, as plain text."
        case .scheduledTasks:
            "Each task you set to run later — its prompt or its rule — and what the last few runs produced. A run that read your calendar or your health stores the sentence it wrote about them, so this is personal data at rest even though no conversation exists for it."
        case .partialDownloads:
            "Bytes of a model that never finished arriving: the resume blob beside the weights, and the part-file URLSession parks in this app's own tmp folder. iOS empties tmp only when the disk comes under pressure, which is why there is a button for it here."
        case .preferences:
            "This app's own settings, including the API key other devices use to reach it."
        case .networkCache:
            // Named for both callers rather than for Hugging Face alone. The
            // analytics SDK reaches the network through the same URLSession
            // machinery, so whatever it leaves behind is counted here too, and
            // a sentence naming only the model search would be describing part
            // of the bytes this screen is showing.
            "What the system's HTTP client kept from the requests this app makes: Hugging Face search results and any cookies its CDN set, plus whatever the analytics SDK's own requests leave behind. Nothing you typed is in here."
        case .shaderCache:
            "Compiled GPU code for running a model on this phone's graphics hardware. It describes the app, not you."
        case .systemState:
            "Snapshots of the last screen you were on, taken when you switch away so the app can reappear instantly, plus the window state to restore. iOS writes these; the app is never asked."
        case .other:
            "Anything in this app's container that this screen does not have a name for. Listed with its real path rather than left out."
        }
    }

    public var disposal: Disposal {
        switch self {
        case .models, .conversations, .partialDownloads, .scheduledTasks:
            .here
        case .networkCache:
            .here
        case .preferences:
            .onlyByDeletingTheApp("Every setting in it can be changed from this app and the API key replaced above. The file itself is written by iOS on the app's behalf and goes when the app does.")
        case .shaderCache:
            .systemManaged("iOS rebuilds it the next time a model loads, so deleting it would cost a slower load and free nothing for long.")
        case .systemState:
            .systemManaged("SpringBoard owns these and writes a fresh snapshot every time you leave the app. No app can delete its own, including this one.")
        case .other:
            .unclassified("This screen has no name for these bytes, so it will not offer to delete them. Deleting the app removes them.")
        }
    }

    /// Who can remove a kind, stated rather than implied.
    ///
    /// This exists so that "delete everything" can be honest about its own
    /// limits. An app that offers the phrase and then leaves three directories
    /// behind has made the same promise the competitor made.
    public enum Disposal: Sendable, Equatable {
        case here
        case onlyByDeletingTheApp(String)
        case systemManaged(String)
        /// Not deleted here because this screen cannot say what it is.
        ///
        /// Distinct from `.systemManaged`, and the distinction is not
        /// pedantry: `.other` used to be filed as system-managed, which put
        /// "Everything else in the container" under a heading reading "Held by
        /// iOS, not by Pocketd" and into a confirmation dialog asserting
        /// "nothing inside this app can" delete it. Both false. `.other` is
        /// this app's own container — the workstream's own test files
        /// `Documents/note.txt` there — and it is never empty, because
        /// `.com.apple.mobile_container_manager.metadata.plist` sits at the
        /// root of every iOS container. So the false sentence rendered on
        /// every device, every time, inside the destructive confirmation.
        case unclassified(String)

        public var isDeletableHere: Bool { self == .here }

        /// Whether iOS, rather than this app, owns the bytes. The heading and
        /// the "nothing inside this app can" sentence are both allowed to say
        /// so only for these.
        public var isSystemOwned: Bool {
            if case .systemManaged = self { return true }
            return false
        }

        /// Why not, for the cases where the answer is no.
        public var limitation: String? {
            switch self {
            case .here: nil
            case let .onlyByDeletingTheApp(reason), let .systemManaged(reason), let .unclassified(reason): reason
            }
        }
    }
}

/// One kind, measured.
public struct StoredDataArea: Sendable, Equatable, Identifiable {
    public var kind: StoredDataKind
    public var tally: DirectoryTally
    /// What is in it. Complete for the kinds this app offers to delete, and
    /// the biggest few for the rest.
    ///
    /// The asymmetry is the point. A delete button that iterates a truncated
    /// list reports success and leaves files behind, which is the same failure
    /// as not counting them — so anything deletable is listed in full and
    /// `isCompleteListing` says which is which rather than leaving a caller to
    /// assume. There is a test that every deletable kind lists everything.
    public var files: [StoredFile]
    public var isCompleteListing: Bool

    public var id: String { kind.rawValue }

    public init(
        kind: StoredDataKind,
        tally: DirectoryTally = .empty,
        files: [StoredFile] = [],
        isCompleteListing: Bool = true
    ) {
        self.kind = kind
        self.tally = tally
        self.files = files
        self.isCompleteListing = isCompleteListing
    }

    /// How many more there are than the listing shows, for a screen that has
    /// to be honest about showing a sample.
    public var unlistedFileCount: Int { max(0, tally.fileCount - files.count) }
}

/// Every byte in the app's container, attributed.
///
/// Exhaustive by construction. Each file is assigned to exactly one area and
/// unclaimed files land in `.other` rather than being skipped, so the areas
/// always sum to the container total — which is the one property that makes
/// this screen an argument instead of a claim. There is a test that walks a
/// tree containing a directory the classifier has never heard of and checks
/// the sum, because the failure this guards against is silent: a directory
/// nobody taught the app about does not raise anything, it just quietly
/// stops being counted.
public struct ContainerSurvey: Sendable, Equatable {
    public var areas: [StoredDataArea]
    /// Directories the walk could not read, named rather than swallowed. A
    /// number derived from a partial walk is a number that lies downward.
    public var unreadablePaths: [String]

    public init(areas: [StoredDataArea], unreadablePaths: [String] = []) {
        self.areas = areas
        self.unreadablePaths = unreadablePaths
    }

    public var totalBytes: Int64 { areas.reduce(0) { $0 + $1.tally.byteCount } }
    public var totalFiles: Int { areas.reduce(0) { $0 + $1.tally.fileCount } }

    public func area(_ kind: StoredDataKind) -> StoredDataArea {
        areas.first { $0.kind == kind } ?? StoredDataArea(kind: kind)
    }

    /// How many of the biggest files a non-deletable area keeps. Enough to
    /// recognise what the bytes are, short enough that the screen stays a
    /// summary.
    public static let sampleLimit = 8

    /// Walks `container` and attributes everything under it.
    ///
    /// Hidden files are counted. `.com.apple.mobile_container_manager.metadata.plist`
    /// sits at the root of every iOS container and skipping it would be a
    /// small lie of exactly the kind this type exists to prevent — it shows up
    /// under `.other` with its real path, which is the honest answer.
    ///
    /// Sizes are the allocated size where the filesystem reports one, because
    /// that is the number iOS shows in Settings and therefore the number the
    /// user can check this screen against.
    public static func survey(
        container: URL,
        fileManager: FileManager = .default
    ) -> ContainerSurvey {
        var tallies: [StoredDataKind: DirectoryTally] = [:]
        var samples: [StoredDataKind: [StoredFile]] = [:]
        var unreadable: [String] = []

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey
        ]
        let enumerator = fileManager.enumerator(
            at: container,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                unreadable.append(relativePath(of: url, under: container))
                // Keep walking. One unreadable subdirectory must not truncate
                // the count for everything after it.
                return true
            }
        )

        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            let path = relativePath(of: url, under: container)
            let file = StoredFile(path: path, byteCount: bytes, modifiedAt: values.contentModificationDate)
            let kind = self.kind(forRelativePath: path)
            tallies[kind, default: .empty].add(file)
            samples[kind, default: []].append(file)
        }

        let areas = StoredDataKind.allCases.map { kind in
            let found = (samples[kind] ?? []).sorted { ($0.byteCount, $0.path) > ($1.byteCount, $1.path) }
            let complete = kind.disposal.isDeletableHere
            return StoredDataArea(
                kind: kind,
                tally: tallies[kind] ?? .empty,
                files: complete ? found : Array(found.prefix(sampleLimit)),
                isCompleteListing: complete || found.count <= sampleLimit
            )
        }
        return ContainerSurvey(areas: areas, unreadablePaths: unreadable)
    }

    /// Which area a file belongs to, from its path alone.
    ///
    /// Matched on path components rather than a literal prefix because two of
    /// the interesting directories are named after the bundle identifier,
    /// which this code has no business hardcoding.
    public static func kind(forRelativePath path: String) -> StoredDataKind {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return .other }

        // Before the Models rule, and deliberately: the resume blob lives
        // beside the weights it belongs to, and counting it as a model would
        // hide the one category nothing else in this app admits to.
        if name.hasSuffix(".resume") { return .partialDownloads }
        if name.hasPrefix("CFNetworkDownload") { return .partialDownloads }

        if parts.starts(with: ["Library", "Application Support", "Models"]) { return .models }
        if parts.starts(with: ["Library", "Application Support", "Conversations"]) { return .conversations }
        if parts.starts(with: ["Library", "Application Support", "ScheduledTasks"]) { return .scheduledTasks }
        if parts.starts(with: ["Library", "Preferences"]) { return .preferences }
        if parts.starts(with: ["Library", "Saved Application State"]) { return .systemState }
        if parts.starts(with: ["Library", "SplashBoard"]) { return .systemState }
        if parts.starts(with: ["Library", "HTTPStorages"]) { return .networkCache }
        if parts.starts(with: ["Library", "Caches"]) {
            // llama.cpp's Metal backend compiles shaders on first load and iOS
            // parks the result here. It is the largest thing in Caches by an
            // order of magnitude and it is not a record of anything the user
            // did, so calling it "cache" beside the Hugging Face responses
            // would overstate one and understate the other.
            if parts.contains(where: { $0.hasPrefix("com.apple.metal") || $0.hasPrefix("com.apple.gpuarchiver") }) {
                return .shaderCache
            }
            return .networkCache
        }
        return .other
    }

    private static func relativePath(of url: URL, under container: URL) -> String {
        let full = url.standardizedFileURL.path
        let root = container.standardizedFileURL.path
        guard full.hasPrefix(root) else { return full }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public extension StoredFile {
    /// Every regular file sitting directly in `directory`, measured.
    ///
    /// Not recursive, because the two directories this is asked about — models
    /// and conversations — are flat by construction, and a recursive listing
    /// would let a subdirectory nobody expected be silently folded into a
    /// parent's total instead of standing out.
    static func listing(of directory: URL, fileManager: FileManager = .default) -> [StoredFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: []
        ) else { return [] }
        return contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return StoredFile(
                path: url.lastPathComponent,
                byteCount: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted { ($0.byteCount, $0.path) > ($1.byteCount, $1.path) }
    }
}

/// What one file in the models directory is for.
///
/// Restates `ModelStore`'s naming convention on purpose. The inspector has to
/// be able to name a file the manifest has forgotten — `ModelStore` itself
/// warns that a weights file the manifest does not list is a multi-gigabyte
/// leak `delete` can never be called on — and asking the manifest what is on
/// disk is precisely the assumption this screen exists to stop making.
public enum ModelFileRole: Sendable, Equatable {
    case weights(id: String)
    case projector(id: String)
    case resumeBlob(id: String)
    case manifest
    case unrecognised

    /// The model this file belongs to, for the roles that name one.
    public var modelID: String? {
        switch self {
        case let .weights(id), let .projector(id), let .resumeBlob(id): id
        case .manifest, .unrecognised: nil
        }
    }
}

public extension ModelFileRole {
    /// Longest suffix first. `.mmproj.gguf` also ends in `.gguf`, and matching
    /// the short one first would file every projector as a set of weights for
    /// a model id that does not exist.
    static func of(fileNamed name: String) -> ModelFileRole {
        if name == "manifest.json" { return .manifest }
        if let id = name.stem(droppingSuffix: ".mmproj.gguf") { return .projector(id: id) }
        if let id = name.stem(droppingSuffix: ".mmproj.resume") { return .resumeBlob(id: id) }
        if let id = name.stem(droppingSuffix: ".gguf") { return .weights(id: id) }
        if let id = name.stem(droppingSuffix: ".resume") { return .resumeBlob(id: id) }
        return .unrecognised
    }
}

private extension String {
    func stem(droppingSuffix suffix: String) -> String? {
        guard hasSuffix(suffix), count > suffix.count else { return nil }
        return String(dropLast(suffix.count))
    }
}

/// Shows enough of a secret to recognise it and not enough to use it.
///
/// The API key is on this screen because "what is stored" has to include it,
/// and it is hidden by default because a screen someone opens to show a
/// sceptical friend is the worst possible place to print a working credential.
public func redactedSecret(_ secret: String, visible: Int = 4) -> String {
    guard secret.count > visible * 2 else { return String(repeating: "•", count: max(secret.count, 8)) }
    return secret.prefix(visible) + "…" + secret.suffix(visible)
}
