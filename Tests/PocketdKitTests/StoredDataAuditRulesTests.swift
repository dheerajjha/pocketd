import Foundation
import Testing
@testable import PocketdKit

/// The rules the data inspector uses to decide what it will delete and what it
/// will claim.
///
/// Every test here is about a screen telling the truth. The orphan rules exist
/// because the worst thing this app can do is delete a running download from a
/// button labelled "free up space"; the plan exists because the second worst is
/// quoting a byte total it then silently skips part of.
@Suite("Stored data audit rules")
struct StoredDataAuditRulesTests {

    private func file(_ name: String, _ bytes: Int64) -> StoredFile {
        StoredFile(path: name, byteCount: bytes)
    }

    // MARK: - What is not an orphan

    @Test("the finished half of a running download is never called an orphan")
    func downloadInFlightIsNotAnOrphan() {
        // The exact sequence from `ModelStore.performDownload`: the weights
        // land and are verified, the projector starts, and the manifest entry
        // is written only after *both* finish. For the whole projector phase —
        // minutes, on gigabytes — `smolvlm-500m.gguf` is a complete file that
        // the manifest does not list.
        let files = [file("smolvlm-500m.gguf", 1_800_000_000), file("manifest.json", 128)]

        let whileDownloading = ModelDirectoryAudit.orphans(
            files: files,
            installedIDs: [],
            downloadingIDs: ["smolvlm-500m"]
        )
        #expect(whileDownloading.isEmpty)

        // And the same file with nothing downloading is exactly what an orphan
        // is, so the guard above cannot be a blanket "never report anything".
        let abandoned = ModelDirectoryAudit.orphans(
            files: files,
            installedIDs: [],
            downloadingIDs: []
        )
        #expect(abandoned.count == 1)
        #expect(abandoned.first?.file.name == "smolvlm-500m.gguf")
    }

    @Test("a paused download's weights survive a force-quit without becoming an orphan")
    func resumeBlobProtectsItsWeights() {
        // After a force-quit there is no live download map to consult, and the
        // resume blob `ModelStore` deliberately kept is the only evidence left
        // that these bytes are wanted. Deleting the weights beside it turns a
        // download that would have resumed into one that starts from zero.
        let files = [
            file("smolvlm-500m.gguf", 1_800_000_000),
            file("smolvlm-500m.mmproj.resume", 4_096),
        ]
        let orphans = ModelDirectoryAudit.orphans(
            files: files,
            installedIDs: [],
            downloadingIDs: []
        )
        #expect(orphans.isEmpty)
    }

    @Test("an installed model's files are not orphans, and a stranded one's are")
    func installedAndStranded() {
        let files = [
            file("qwen3-1.7b.gguf", 1_000),
            file("smolvlm-500m.gguf", 2_000),
            file("smolvlm-500m.mmproj.gguf", 500),
            file("manifest.json", 128),
            file("notes.txt", 7),
        ]
        let orphans = ModelDirectoryAudit.orphans(
            files: files,
            installedIDs: ["qwen3-1.7b"],
            downloadingIDs: []
        )

        #expect(orphans.map(\.file.name).sorted() == [
            "notes.txt", "smolvlm-500m.gguf", "smolvlm-500m.mmproj.gguf",
        ])
        // A projector is not "weights". Naming it wrongly in the sentence
        // beside a Delete button is a small lie on a screen that has no room
        // for any.
        let projector = orphans.first { $0.file.name == "smolvlm-500m.mmproj.gguf" }
        #expect(projector?.explanation.contains("image projector") == true)
        #expect(orphans.first { $0.file.name == "smolvlm-500m.gguf" }?.explanation.contains("Weights") == true)
    }

    @Test("a resume blob is reported as a paused download, not as junk")
    func resumeBlobsAreNeverOrphans() {
        let orphans = ModelDirectoryAudit.orphans(
            files: [file("qwen3-4b.resume", 64), file("manifest.json", 128)],
            installedIDs: [],
            downloadingIDs: []
        )
        #expect(orphans.isEmpty)
    }

    // MARK: - What "delete everything" promises

    @Test("the total quoted excludes what the delete will skip")
    func planExcludesSkippedDownloads() {
        // With a transfer running, the delete leaves unfinished downloads
        // alone — the dedicated button refuses for the same reason — but the
        // footer summed them anyway, so the dialog promised bytes it then left
        // on disk and the "freed" line afterwards came up short with no
        // explanation.
        let running = DeletionPlan.deleteEverything(
            installedModelBytes: 1_000,
            orphanBytes: 100,
            conversationBytes: 10,
            partialDownloadBytes: 3_000_000_000,
            networkCacheBytes: 1,
            downloadInFlight: true
        )
        #expect(running.byteCount == 1_111)
        #expect(running.included.contains { $0.name == "every unfinished download" } == false)
        let skipped = running.skipped.first { $0.name == "every unfinished download" }
        #expect(skipped?.byteCount == 3_000_000_000)
        #expect(skipped?.skippedBecause?.isEmpty == false)

        let idle = DeletionPlan.deleteEverything(
            installedModelBytes: 1_000,
            orphanBytes: 100,
            conversationBytes: 10,
            partialDownloadBytes: 3_000_000_000,
            networkCacheBytes: 1,
            downloadInFlight: false
        )
        #expect(idle.byteCount == 3_000_001_111)
        #expect(idle.skipped.isEmpty)
    }

    @Test("the quoted total is the sum of the things the sentence names")
    func planNamesWhatItCounts() {
        let plan = DeletionPlan.deleteEverything(
            installedModelBytes: 4_000,
            orphanBytes: 0,
            conversationBytes: 300,
            partialDownloadBytes: 0,
            networkCacheBytes: 20,
            downloadInFlight: false
        )
        // The invariant that makes the footer checkable: a reader adding up the
        // categories in the sentence lands on the number in front of it.
        #expect(plan.included.reduce(0) { $0 + $1.byteCount } == plan.byteCount)
        // Empty categories are not named. "every conversation" beside a zero
        // reads as a promise about something.
        #expect(plan.included.map(\.name) == ["every model", "every conversation", "the network cache"])
        #expect(plan.isEmpty == false)

        let nothing = DeletionPlan.deleteEverything(
            installedModelBytes: 0, orphanBytes: 0, conversationBytes: 0,
            partialDownloadBytes: 0, networkCacheBytes: 0, downloadInFlight: false
        )
        #expect(nothing.isEmpty)
        #expect(nothing.included.isEmpty)
    }

    @Test("orphaned model files are named in the total, because they are deleted")
    func planCountsOrphans() {
        let plan = DeletionPlan.deleteEverything(
            installedModelBytes: 0,
            orphanBytes: 900,
            conversationBytes: 0,
            partialDownloadBytes: 0,
            networkCacheBytes: 0,
            downloadInFlight: false
        )
        #expect(plan.byteCount == 900)
        #expect(plan.included.map(\.name) == ["model files nothing can load"])
    }

    // MARK: - What the freed line is allowed to claim

    @Test("what a sweep freed is measured before it sweeps, not after")
    func sweepReportsWhatItRemoved() throws {
        // `deleteAllConversations` deleted every readable transcript and only
        // then listed the directory to work out the figure, so "freed" counted
        // whatever the first pass had missed — normally nothing. Deleting
        // 1.2 MB rendered "Zero KB freed." on the one line whose stated job is
        // to prove the button was not decorative.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: Int64 = 0
        for index in 0..<5 {
            let bytes = 1_000 * (index + 1)
            try Data(repeating: 0x41, count: bytes)
                .write(to: directory.appendingPathComponent("\(index).json"))
            written += Int64(bytes)
        }
        // The remnant an interrupted atomic save leaves behind. It is in the
        // size the screen quotes, so it has to be in what the sweep reports.
        try Data(repeating: 0x41, count: 640).write(to: directory.appendingPathComponent(".tmp-abc"))
        written += 640

        let freed = DirectorySweep.emptyOfFiles(at: directory)

        #expect(freed >= written, "a sweep that reports less than it removed is the bug")
        #expect(StoredFile.listing(of: directory).isEmpty)
        // And an empty directory frees nothing rather than reporting a figure
        // from the pass before it.
        #expect(DirectorySweep.emptyOfFiles(at: directory) == 0)
    }

    // MARK: - What "delete everything" says about what survives

    @Test("only bytes iOS owns get the sentence about iOS owning them")
    func onlySystemOwnedGetsTheStrongClaim() {
        // The preferences file was appended to this sentence by hand — three
        // rows under a "Replace the API key" button that rewrites it, and
        // beside a section listing every key `removePersistentDomain` clears.
        let sentences = DeletionNarrative.sentences(
            plan: .deleteEverything(
                installedModelBytes: 1_000, orphanBytes: 0, conversationBytes: 0,
                partialDownloadBytes: 0, networkCacheBytes: 0, downloadInFlight: false
            ),
            measured: true,
            systemOwnedTitles: [StoredDataKind.systemState.title],
            preferencesBytes: 4_096,
            unnamedTitles: [],
            unnamedBytes: 0
        )
        let footer = sentences.joined(separator: " ")

        let strong = try? #require(sentences.first { $0.contains("nothing inside this app can") })
        #expect(strong?.contains(StoredDataKind.systemState.title) == true)
        #expect(strong?.contains(StoredDataKind.preferences.title) == false)

        // Named rather than dropped: the section is on the screen, so the
        // footer has to account for it, and it has to say what can be done.
        #expect(footer.contains("It leaves \(StoredDataKind.preferences.title)"))
        #expect(footer.contains("can be changed from this app"))
    }

    @Test("with nothing iOS owns, nothing claims iOS owns it")
    func noSystemOwnedMeansNoClaim() {
        let sentences = DeletionNarrative.sentences(
            plan: .deleteEverything(
                installedModelBytes: 0, orphanBytes: 0, conversationBytes: 0,
                partialDownloadBytes: 0, networkCacheBytes: 0, downloadInFlight: false
            ),
            measured: true,
            systemOwnedTitles: [],
            preferencesBytes: 4_096,
            unnamedTitles: ["Everything else in the container"],
            unnamedBytes: 42
        )
        let footer = sentences.joined(separator: " ")

        #expect(footer.contains("nothing inside this app can") == false)
        #expect(footer.contains("There is nothing here left for this screen to delete."))
        // The unnamed bytes keep their own, weaker claim: this app could remove
        // them and will not, which is not the same statement.
        #expect(footer.contains("has no name for and so will not delete"))
    }

    @Test("an unmeasured screen says so rather than saying there is nothing")
    func unmeasuredDoesNotClaimEmptiness() {
        // `.task` runs after the first body evaluation, so the first rendered
        // frame is deterministic rather than a race: under the headline
        // destructive control, a phone holding 4.63 GB read "There is nothing
        // here left for this screen to delete."
        let sentences = DeletionNarrative.sentences(
            plan: .deleteEverything(
                installedModelBytes: 0, orphanBytes: 0, conversationBytes: 0,
                partialDownloadBytes: 0, networkCacheBytes: 0, downloadInFlight: false
            ),
            measured: false,
            systemOwnedTitles: [],
            preferencesBytes: 0,
            unnamedTitles: [],
            unnamedBytes: 0
        )
        #expect(sentences.first == "Still counting what is here.")
        #expect(sentences.joined(separator: " ").contains("nothing here left") == false)
    }

    @Test("the footer quotes the plan's own number and names its own parts")
    func footerMatchesThePlan() {
        let plan = DeletionPlan.deleteEverything(
            installedModelBytes: 2_000_000, orphanBytes: 0, conversationBytes: 4_000,
            partialDownloadBytes: 900_000, networkCacheBytes: 500,
            downloadInFlight: true
        )
        let footer = DeletionNarrative.sentences(
            plan: plan, measured: true, systemOwnedTitles: [],
            preferencesBytes: 0, unnamedTitles: [], unnamedBytes: 0
        ).joined(separator: " ")

        #expect(footer.contains(formattedByteCount(plan.byteCount)))
        #expect(footer.contains("every model, every conversation and the network cache"))
        // The skipped category is named with its reason rather than folded into
        // a total the button then does not free.
        #expect(footer.contains("It leaves every unfinished download"))
        #expect(footer.contains("a download is running"))
    }

    // MARK: - Permissions

    @Test("local network is reported once, from the key that knows the most")
    func localNetworkIsNotDuplicated() {
        // `NSLocalNetworkUsageDescription` also ends in "UsageDescription", so
        // the generic loop rendered a second row for it: "LocalNetwork",
        // orange, carrying the App Store prompt copy where every other row
        // explains its state — beside the "Local network" row built from
        // `NSBonjourServices`, which also names what is advertised.
        let info: [String: Any] = [
            "NSCalendarsFullAccessUsageDescription": "calendar",
            "NSHealthShareUsageDescription": "health read",
            "NSHealthUpdateUsageDescription": "health write",
            "NSLocalNetworkUsageDescription": "local network",
            "NSRemindersFullAccessUsageDescription": "reminders",
            "NSBonjourServices": ["_pocketd._tcp"],
        ]
        #expect(DeclaredPermissions.rowKeys(in: info) == [
            "NSCalendarsFullAccessUsageDescription",
            "NSHealthShareUsageDescription",
            "NSRemindersFullAccessUsageDescription",
        ])
    }

    @Test("the shipping Info.plist produces one row per permission")
    func realBundleHasNoDuplicateRows() throws {
        // Against the file that actually renders, not a fixture of it. The
        // duplicate row appeared because a key was added to this plist by
        // another workstream and the generic loop picked it up; a synthetic
        // dictionary would never have noticed.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketdKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
        let plist = repository.appendingPathComponent("App/Resources/Info.plist")
        let info = try #require(
            PropertyListSerialization.propertyList(
                from: try Data(contentsOf: plist), format: nil
            ) as? [String: Any],
            "App/Resources/Info.plist must be readable; the permissions section is built from it"
        )

        let keys = DeclaredPermissions.rowKeys(in: info)
        #expect(keys.contains("NSLocalNetworkUsageDescription") == false)
        #expect(info["NSBonjourServices"] != nil)
        // Bonjour is the row that reports local network, so the plist losing
        // it while keeping the usage string would drop the permission entirely
        // rather than duplicate it.
        let titles = keys.map(DeclaredPermissions.title(forInfoKey:)) + ["Local network"]
        #expect(Set(titles).count == titles.count)
    }

    @Test("a permission title loses the prefix, not every NS in the name")
    func permissionTitles() {
        #expect(DeclaredPermissions.title(forInfoKey: "NSCameraUsageDescription") == "Camera")
        #expect(DeclaredPermissions.title(forInfoKey: "NSPhotoLibraryAddUsageDescription") == "Photo Library Add")
        // The mine the blanket `replacingOccurrences(of: "NS")` was leaving
        // behind: the row still renders, just under a word with a hole in it.
        #expect(DeclaredPermissions.title(forInfoKey: "NSSensorNSKitUsageDescription") == "Sensor NSKit")
    }

    // MARK: - Settings, as they are stored

    @Test("a stored 1 is a number, not a switch that is On")
    func integersAreNotBooleans() throws {
        // Round-tripped through a property list because a preferences file is
        // a property list: once the value is on disk the encoding is the only
        // thing still separating `set(1, …)` from `set(true, …)`.
        let stored: [String: Any] = [
            "threads": 1, "verbose": true, "quiet": false,
            "zero": 0, "ratio": 1.0, "contextLength": 3,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0)
        let read = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let threads = try #require(read["threads"])
        let verbose = try #require(read["verbose"])
        let quiet = try #require(read["quiet"])

        // The bug, stated: `case let flag as Bool` matches every one of these.
        #expect((threads as? Bool) == true)
        #expect((read["zero"] as? Bool) == false)
        #expect((read["ratio"] as? Bool) == true)

        #expect(isStoredAsBoolean(verbose))
        #expect(isStoredAsBoolean(quiet))
        #expect(isStoredAsBoolean(threads) == false)
        #expect(isStoredAsBoolean(try #require(read["zero"])) == false)
        #expect(isStoredAsBoolean(try #require(read["ratio"])) == false)
        #expect(isStoredAsBoolean(try #require(read["contextLength"])) == false)
        #expect(isStoredAsBoolean("a string") == false)
    }
}
