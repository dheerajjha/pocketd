import Foundation
import Testing
@testable import PocketdKit

/// The data inspector's whole claim is that its numbers can be checked, so the
/// thing under test here is completeness rather than correctness of any one
/// figure. A privacy screen that misses a directory is worse than no screen,
/// and missing a directory is silent: nothing throws, a number is just quietly
/// smaller than the truth.
@Suite("Stored data inventory")
struct StoredDataInventoryTests {

    /// Builds a container with the shape a real one has on a device — the
    /// paths below were copied from a Pocketd container pulled off a
    /// simulator, including the two nobody would have guessed.
    private func makeContainer() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-container-\(UUID().uuidString)")
        let files: [String: Int] = [
            "Library/Application Support/Models/qwen3-1.7b.gguf": 4096,
            "Library/Application Support/Models/smolvlm-500m.mmproj.gguf": 512,
            "Library/Application Support/Models/manifest.json": 128,
            "Library/Application Support/Models/qwen3-4b.resume": 64,
            "Library/Application Support/Conversations/\(UUID().uuidString).json": 256,
            "Library/Preferences/dev.pocketd.app.plist": 300,
            "Library/Caches/dev.pocketd.app/Cache.db": 700,
            "Library/Caches/dev.pocketd.app/fsCachedData/9B8F9C93": 900,
            "Library/Caches/dev.pocketd.app/com.apple.metal/libraries.data": 1200,
            "Library/Caches/dev.pocketd.app/com.apple.gpuarchiver/archive": 90,
            "Library/HTTPStorages/dev.pocketd.app/httpstorages.sqlite": 200,
            "Library/SplashBoard/Snapshots/dev.pocketd.app - {DEFAULT GROUP}/A@2x.ktx": 150,
            "Library/Saved Application State/dev.pocketd.app.savedState/data.data": 110,
            "tmp/CFNetworkDownload_YbXpdH.tmp": 2048,
            ".com.apple.mobile_container_manager.metadata.plist": 42,
            // Nothing in this app writes here and nothing classifies it. That
            // is the point: this is what a future iOS starting to write
            // somewhere new looks like.
            "Library/SomethingAppleAddsInTwoYears/state.bin": 333,
        ]
        for (path, size) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: size).write(to: url)
        }
        return root
    }

    /// Independent of the classifier on purpose. If both walks shared a code
    /// path the test would only prove the code agrees with itself.
    private func totalAllocatedBytes(under root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    @Test("every byte in the container is attributed to exactly one area")
    func surveyIsExhaustive() throws {
        let root = try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }

        let survey = ContainerSurvey.survey(container: root)
        #expect(survey.totalBytes == totalAllocatedBytes(under: root))
        #expect(survey.totalFiles == 16)
        // Every directory here is readable, so this says the total above is a
        // figure rather than a floor. It is not cover for the reporting itself
        // — no fixture here could ever make it fail — which is what
        // `unreadableDirectoriesAreNamed` below is for.
        #expect(survey.unreadablePaths.isEmpty)
    }

    @Test(
        "a directory the walk cannot enter is named, and does not stop the walk",
        // Root bypasses POSIX permissions, so on a runner that is root there is
        // no such thing as an unreadable directory and this would prove nothing.
        .enabled(if: getuid() != 0, "needs a user that chmod 000 actually restricts")
    )
    func unreadableDirectoriesAreNamed() throws {
        // `unreadablePaths` is the only thing standing between "this screen
        // counts every byte" and "this screen counts every byte it happened to
        // be able to read", and the survey's own doc comment says a number from
        // a partial walk is a number that lies downward. Nothing tested it: the
        // line that records the path could be deleted and the whole suite
        // stayed green.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-unreadable-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("Library/Caches/dev.pocketd.app/aa-locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        for (path, size) in [
            ("Library/Caches/dev.pocketd.app/aa-locked/hidden.bin", 4_096),
            ("Library/Caches/dev.pocketd.app/zz-after/Cache.db", 700),
            ("Library/Application Support/Models/qwen3-1.7b.gguf", 512),
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: size).write(to: url)
        }
        let openTotal = ContainerSurvey.survey(container: root).totalBytes
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let survey = ContainerSurvey.survey(container: root)

        // Named, with the path a person could go and check.
        #expect(survey.unreadablePaths == ["Library/Caches/dev.pocketd.app/aa-locked"])
        // And the rest of the container is still counted rather than the walk
        // ending at the error. This is an assertion about the survey's output,
        // not about the `return true` in the error handler: on Darwin that
        // return value turns out to change nothing observable here, because the
        // enumerator raises the error while descending into the last directory
        // it visits. Returning false leaves every number below identical.
        #expect(survey.area(.networkCache).files.contains { $0.path.hasSuffix("zz-after/Cache.db") })
        #expect(survey.area(.models).tally.fileCount == 1)
        // The total really is short by what could not be read, which is exactly
        // why the screen calls it a floor when this list is not empty.
        #expect(survey.totalBytes < openTotal)
        #expect(survey.totalFiles == 2)
    }

    @Test("a directory nothing knows about is shown, not dropped")
    func unknownDirectorySurvives() throws {
        let root = try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }

        let other = ContainerSurvey.survey(container: root).area(.other)
        // The container manager's own hidden plist and the invented directory.
        #expect(other.tally.fileCount == 2)
        #expect(other.files.contains { $0.path == "Library/SomethingAppleAddsInTwoYears/state.bin" })
        #expect(other.files.contains { $0.path == ".com.apple.mobile_container_manager.metadata.plist" })
    }

    @Test("what this screen never offers to delete is what it cannot name")
    func unclassifiedIsNeverDeletable() {
        // The rule that keeps "delete everything" honest: an area whose
        // contents the app cannot describe must not be swept up by a button
        // that claims to know what it is removing.
        #expect(StoredDataKind.other.disposal.isDeletableHere == false)
        #expect(StoredDataKind.systemState.disposal.isDeletableHere == false)
        #expect(StoredDataKind.shaderCache.disposal.isDeletableHere == false)
        for kind in StoredDataKind.allCases where !kind.disposal.isDeletableHere {
            // Every refusal states a reason, because "cannot be deleted" with
            // no explanation is indistinguishable from hiding it.
            #expect(kind.disposal.limitation?.isEmpty == false)
        }
    }

    @Test("refusing to delete something is not the same as iOS owning it")
    func unclassifiedIsNotSystemOwned() {
        // `.other` was filed as `.systemManaged`, which put this app's own
        // container under a heading reading "Held by iOS, not by Pocketd" and
        // into a destructive confirmation asserting "nothing inside this app
        // can" remove it. Both false, and both rendered on every device —
        // every iOS container has a metadata plist at its root, so `.other` is
        // never empty.
        #expect(StoredDataKind.other.disposal.isSystemOwned == false)
        #expect(ContainerSurvey.kind(forRelativePath: "Documents/note.txt") == .other)

        #expect(StoredDataKind.systemState.disposal.isSystemOwned)
        #expect(StoredDataKind.shaderCache.disposal.isSystemOwned)
        // The preferences file goes with the app rather than with iOS's own
        // bookkeeping, so it is not in the system-owned list either.
        #expect(StoredDataKind.preferences.disposal.isSystemOwned == false)
        for kind in StoredDataKind.allCases where kind.disposal.isDeletableHere {
            #expect(kind.disposal.isSystemOwned == false)
        }
    }

    @Test("a paused download is counted as a download, not as a model")
    func resumeBlobsAreNotModels() throws {
        let root = try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let survey = ContainerSurvey.survey(container: root)

        // The resume blob sits inside the models directory and the temporary
        // file it points at sits in tmp, which is why every other surface in
        // this app reports one of them and neither reports both.
        #expect(survey.area(.partialDownloads).tally.fileCount == 2)
        #expect(survey.area(.models).tally.fileCount == 3)
        #expect(survey.area(.models).files.allSatisfy { !$0.name.hasSuffix(".resume") })
    }

    @Test("the shader cache is separated from what Hugging Face left behind")
    func cachesAreSplit() throws {
        let root = try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let survey = ContainerSurvey.survey(container: root)

        #expect(survey.area(.shaderCache).tally.fileCount == 2)
        // Cache.db, fsCachedData and HTTPStorages: the search results and the
        // cookies, which are a record of what someone looked for.
        #expect(survey.area(.networkCache).tally.fileCount == 3)
    }

    @Test("paths are classified by shape, not by the bundle identifier")
    func classification() {
        #expect(ContainerSurvey.kind(forRelativePath: "Library/Application Support/Models/a.gguf") == .models)
        #expect(ContainerSurvey.kind(forRelativePath: "Library/Application Support/Conversations/a.json") == .conversations)
        #expect(ContainerSurvey.kind(forRelativePath: "Library/Preferences/anything.plist") == .preferences)
        #expect(ContainerSurvey.kind(forRelativePath: "Library/Caches/com.other.app/Cache.db") == .networkCache)
        #expect(ContainerSurvey.kind(forRelativePath: "Library/Caches/com.other.app/com.apple.metal/x") == .shaderCache)
        #expect(ContainerSurvey.kind(forRelativePath: "Library/HTTPStorages/x/y.sqlite") == .networkCache)
        #expect(ContainerSurvey.kind(forRelativePath: "Library/SplashBoard/Snapshots/a@2x.ktx") == .systemState)
        #expect(ContainerSurvey.kind(forRelativePath: "tmp/CFNetworkDownload_ab.tmp") == .partialDownloads)
        #expect(ContainerSurvey.kind(forRelativePath: "Documents/note.txt") == .other)
    }

    @Test("a projector is not filed as weights for a model that does not exist")
    func modelFileRoles() {
        // `.mmproj.gguf` also ends in `.gguf`. Matching the short suffix first
        // yields the id "smolvlm-500m.mmproj", which matches no manifest entry,
        // so the projector would be reported as an orphan on every launch.
        #expect(ModelFileRole.of(fileNamed: "smolvlm-500m.mmproj.gguf") == .projector(id: "smolvlm-500m"))
        #expect(ModelFileRole.of(fileNamed: "smolvlm-500m.mmproj.resume") == .resumeBlob(id: "smolvlm-500m"))
        #expect(ModelFileRole.of(fileNamed: "qwen3-1.7b.gguf") == .weights(id: "qwen3-1.7b"))
        #expect(ModelFileRole.of(fileNamed: "qwen3-4b.resume") == .resumeBlob(id: "qwen3-4b"))
        #expect(ModelFileRole.of(fileNamed: "manifest.json") == .manifest)
        #expect(ModelFileRole.of(fileNamed: "notes.txt") == .unrecognised)
        #expect(ModelFileRole.of(fileNamed: ".gguf") == .unrecognised)
        #expect(ModelFileRole.of(fileNamed: "qwen3-1.7b.gguf").modelID == "qwen3-1.7b")
        #expect(ModelFileRole.manifest.modelID == nil)
    }

    @Test("everything the screen offers to delete is listed in full")
    func deletableAreasListEverything() throws {
        // Its own fixture, and the reason is the whole test. Run against
        // `makeContainer()` this assertion could not fail: the deletable areas
        // there hold three files at most, all of them under `sampleLimit`, so
        // reintroducing the truncation bug left the suite green. A test that
        // cannot fail is worse than no test, because it is counted as cover.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-deletable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = root.appendingPathComponent("Library/Application Support/Conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let written = ContainerSurvey.sampleLimit + 4
        for index in 0..<written {
            // Varying sizes so the listing is genuinely sorted rather than
            // incidentally ordered, since truncation keeps the biggest few.
            try Data(repeating: 0x41, count: 16 * (index + 1))
                .write(to: conversations.appendingPathComponent("\(index).json"))
        }

        let survey = ContainerSurvey.survey(container: root)
        let deletable = survey.areas.filter { $0.kind.disposal.isDeletableHere }

        // Guards the guard: if a future edit shrinks this fixture below the
        // sample limit, this fails rather than quietly proving nothing.
        #expect(deletable.contains { $0.tally.fileCount > ContainerSurvey.sampleLimit })

        // The bug this is here for: a delete that iterates a truncated sample
        // removes the biggest few, reports success and leaves the rest on
        // disk. Silent, and indistinguishable from working —
        // `deletePartialDownloads` and the conversations sweep both iterate
        // `area.files` to decide what to remove.
        for area in deletable {
            #expect(area.isCompleteListing)
            #expect(area.files.count == area.tally.fileCount)
            #expect(area.unlistedFileCount == 0)
        }
        #expect(survey.area(.conversations).files.count == written)
    }

    @Test("a sampled area admits that it is a sample")
    func sampledAreasSaySo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-sample-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("Library/SplashBoard/Snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        for index in 0..<(ContainerSurvey.sampleLimit + 5) {
            try Data([0x41]).write(to: snapshots.appendingPathComponent("\(index).ktx"))
        }

        let area = ContainerSurvey.survey(container: root).area(.systemState)
        #expect(area.tally.fileCount == ContainerSurvey.sampleLimit + 5)
        #expect(area.files.count == ContainerSurvey.sampleLimit)
        #expect(area.isCompleteListing == false)
        #expect(area.unlistedFileCount == 5)
    }

    @Test("a tally reports the span of what it counted")
    func tallySpan() {
        var tally = DirectoryTally.empty
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 9_000)
        tally.add(StoredFile(path: "b", byteCount: 20, modifiedAt: new))
        tally.add(StoredFile(path: "a", byteCount: 10, modifiedAt: old))
        // A file with no readable date must not become a date of nil for the
        // whole group: "oldest: unknown" is what an empty history looks like.
        tally.add(StoredFile(path: "c", byteCount: 5, modifiedAt: nil))

        #expect(tally.fileCount == 3)
        #expect(tally.byteCount == 35)
        #expect(tally.oldest == old)
        #expect(tally.newest == new)
    }

    @Test("the API key is recognisable without being usable")
    func redaction() {
        let key = "pk-abcdefghijklmnopqrstuvwxyz012345"
        let shown = redactedSecret(key)
        #expect(shown == "pk-a…2345")
        #expect(!shown.contains("mnop"))
        // A short secret has no safe middle to hide, so none of it is shown.
        #expect(redactedSecret("pk-1234") == "••••••••")
    }
}
