import Foundation

/// A file in the models directory that no installed model claims.
public struct OrphanedModelFile: Sendable, Equatable, Identifiable {
    public var file: StoredFile
    public var explanation: String

    public var id: String { file.path }

    public init(file: StoredFile, explanation: String) {
        self.file = file
        self.explanation = explanation
    }
}

/// Which files in the models directory are genuinely abandoned.
///
/// The whole value of this type is what it refuses to call an orphan.
/// `ModelStore.performDownload` writes the manifest entry only after *both* the
/// weights and the projector have arrived and been verified, so for the entire
/// projector phase of a vision model `<id>.gguf` is a complete, multi-gigabyte
/// file that the manifest does not list. Deciding from the manifest alone —
/// which is what an inspector is tempted to do, since checking the manifest is
/// the whole point of finding orphans — labels a running download as garbage
/// and offers a Delete button for it on a screen about freeing space.
///
/// Two states have to be excluded, and they are not the same state:
///
/// - **In flight.** Known only from the app's live download map, which is why
///   the ids are a parameter and not something this file can work out.
/// - **Paused, or interrupted by a force-quit.** The live map is gone, but a
///   resume blob is sitting in the directory naming the id. `ModelStore` keeps
///   that blob deliberately so the next attempt resumes; deleting the weights
///   beside it would silently turn a resumable download into a fresh one.
public enum ModelDirectoryAudit {
    public static func orphans(
        files: [StoredFile],
        installedIDs: Set<String>,
        downloadingIDs: Set<String>
    ) -> [OrphanedModelFile] {
        // Computed from the listing rather than passed in: after a force-quit
        // the blob on disk is the only surviving evidence that these bytes
        // belong to something.
        let pausedIDs = Set(files.compactMap { file in
            ModelFileRole.of(fileNamed: file.name).resumingModelID
        })
        func isAbandoned(_ id: String) -> Bool {
            !installedIDs.contains(id) && !downloadingIDs.contains(id) && !pausedIDs.contains(id)
        }

        return files.compactMap { file -> OrphanedModelFile? in
            switch ModelFileRole.of(fileNamed: file.name) {
            case .manifest:
                return nil
            case .resumeBlob:
                // A paused download, which is a category of its own and is
                // reported as one. Calling it an orphan would tell someone
                // their app is broken when they simply stopped a download.
                return nil
            case let .weights(id):
                guard isAbandoned(id) else { return nil }
                return OrphanedModelFile(
                    file: file,
                    explanation: "Weights for \"\(id)\", which is not in the list of installed models and is not downloading. Nothing in this app can load it or free it."
                )
            case let .projector(id):
                guard isAbandoned(id) else { return nil }
                return OrphanedModelFile(
                    file: file,
                    explanation: "An image projector for \"\(id)\", which is not in the list of installed models and is not downloading. Nothing in this app can load it or free it."
                )
            case .unrecognised:
                return OrphanedModelFile(
                    file: file,
                    explanation: "Not a file this app knows how to write."
                )
            }
        }
    }
}

public extension ModelFileRole {
    /// The model a *resume blob* names, and nothing else.
    ///
    /// Separate from `modelID` because the question being asked is different:
    /// `modelID` is "whose bytes are these", this is "is there an unfinished
    /// transfer for this id", and answering the second with the first would
    /// make every weights file vouch for itself.
    var resumingModelID: String? {
        if case let .resumeBlob(id) = self { return id }
        return nil
    }
}

/// What "delete everything Pocketd can delete" will actually remove, right now.
///
/// The quote and the deed come from one value on purpose. They used to be
/// computed separately — the footer summed every area whose disposal was
/// `.here`, while the delete skipped unfinished downloads whenever one was
/// running — so with a 3 GB transfer in flight the confirmation dialog promised
/// to free 3 GB it then deliberately left on disk, and the "freed" line
/// afterwards reported a smaller number with no explanation. On a screen whose
/// entire argument is that its numbers are checkable, a total that includes
/// bytes the same button skips is the one bug that discredits everything else
/// on the page.
public struct DeletionPlan: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var name: String
        public var byteCount: Int64
        /// Why these bytes stay, for the entries that are staying. `nil` means
        /// this entry is being deleted.
        public var skippedBecause: String?

        public var id: String { name }

        public init(name: String, byteCount: Int64, skippedBecause: String? = nil) {
            self.name = name
            self.byteCount = byteCount
            self.skippedBecause = skippedBecause
        }
    }

    /// The names entries carry, so a caller can pick one out without restating
    /// the literal. The footer needs to know whether the network cache is in
    /// the total — it carries a caveat of its own — and a string compare
    /// against a copy of the wording would stop matching, silently, the day
    /// the wording changed.
    public enum EntryName {
        public static let models = "every model"
        public static let orphans = "model files nothing can load"
        public static let conversations = "every conversation"
        public static let partialDownloads = "every unfinished download"
        public static let networkCache = "the network cache"
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Only what is actually going. This is the number the button is allowed
    /// to quote.
    public var byteCount: Int64 {
        entries.filter { $0.skippedBecause == nil }.reduce(0) { $0 + $1.byteCount }
    }

    /// Named in the footer so the sentence lists what the number is made of.
    /// Empty categories are dropped: "every conversation" reads as a promise
    /// about something when there is nothing.
    public var included: [Entry] {
        entries.filter { $0.skippedBecause == nil && $0.byteCount > 0 }
    }

    /// Deletable in principle, staying today, with the reason attached.
    public var skipped: [Entry] {
        entries.filter { $0.skippedBecause != nil && $0.byteCount > 0 }
    }

    public var isEmpty: Bool { byteCount == 0 }

    /// Builds the plan from measured bytes.
    ///
    /// Every figure here is what the corresponding delete step reaches, not
    /// what the containing area weighs. `installedModelBytes` is the sum of the
    /// model rows rather than the size of the models directory, because the
    /// directory also holds the manifest (rewritten, not removed) and any
    /// download in flight (excluded from `orphanBytes` by `ModelDirectoryAudit`
    /// and not deletable through a manifest entry that does not exist yet).
    public static func deleteEverything(
        installedModelBytes: Int64,
        orphanBytes: Int64,
        conversationBytes: Int64,
        partialDownloadBytes: Int64,
        networkCacheBytes: Int64,
        downloadInFlight: Bool
    ) -> DeletionPlan {
        DeletionPlan(entries: [
            Entry(name: EntryName.models, byteCount: installedModelBytes),
            Entry(name: EntryName.orphans, byteCount: orphanBytes),
            Entry(name: EntryName.conversations, byteCount: conversationBytes),
            Entry(
                name: EntryName.partialDownloads,
                byteCount: partialDownloadBytes,
                // Same refusal as the dedicated button, for the same reason: a
                // live transfer owns one of those files.
                skippedBecause: downloadInFlight
                    ? "a download is running and one of those files belongs to it"
                    : nil
            ),
            Entry(name: EntryName.networkCache, byteCount: networkCacheBytes),
        ])
    }
}
