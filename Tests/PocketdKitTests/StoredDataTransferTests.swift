import Foundation
import Testing
import FlyingFox
@testable import PocketdKit

/// Who knows that a download is running.
///
/// The data inspector refuses to delete bytes a transfer is using, and every one
/// of those refusals used to read `AppModel.downloads` — a map only the phone's
/// own Models tab writes. A pull a paired laptop started with `POST /api/pull`
/// goes through `ModelStore.download` and appears in no such map, so the
/// inspector called the growing file a stray, offered a live Delete for it, and
/// its "free up space" button swept the part-file URLSession was still writing.
/// The fix is that the actor both doors go through answers the question.
@Suite("Stored data transfers in flight")
struct StoredDataTransferTests {

    private func makeStore() throws -> (ModelStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ModelStore(
            directory: directory,
            budget: DeviceBudget(physicalMemoryBytes: 16 << 30, hasIncreasedMemoryLimit: true)
        )
        return (store, directory)
    }

    private func record(at url: URL, size: Int64) -> ModelRecord {
        ModelRecord(
            id: "pulled-by-a-laptop",
            displayName: "Pulled By A Laptop",
            repoID: "pocketd/test",
            filename: "weights.gguf",
            parameters: "0B",
            quantization: "none",
            sizeBytes: size,
            contextLength: 2048,
            license: "MIT",
            sourceURL: url
        )
    }

    @Test("a download nothing told the app about is still visible as in flight")
    func serverPullIsVisible() async throws {
        let blob = Data(repeating: 0x41, count: 3 << 20)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: 0))
        // Held open until the test says so, which is what makes "while it is
        // running" a state the assertions can actually observe.
        let gate = Gate()
        await server.appendRoute("GET /weights.gguf") { _ in
            await gate.wait()
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/octet-stream"], body: blob)
        }
        let serving = Task { try? await server.run() }
        try await server.waitUntilListening(timeout: 5)
        defer { serving.cancel() }
        let port = try #require(await server.resolvedPort())
        let model = record(at: URL(string: "http://127.0.0.1:\(port)/weights.gguf")!, size: Int64(blob.count))

        #expect(await store.downloadsInFlight().isEmpty)

        // Exactly the shape `AppModel`'s `puller` closure hands the server: a
        // call straight into the store, with nothing in the app told about it.
        let pull = Task {
            for try await _ in await store.download(model) {}
        }
        // The id has to be registered before the first byte moves, because the
        // window this guards is the whole transfer including its start.
        try await waitUntil { await store.downloadsInFlight().contains(model.id) }
        #expect(await store.downloadsInFlight() == [model.id])

        await gate.open()
        _ = try await pull.value
        #expect(await store.isInstalled(model))
        // And released again, or the screen would refuse every delete forever
        // after one download.
        #expect(await store.downloadsInFlight().isEmpty)
        await server.stop(timeout: 1)
    }

    @Test("a failed pull does not leave the id registered forever")
    func failedPullReleasesTheID() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: 0))
        await server.appendRoute("GET /weights.gguf") { _ in
            HTTPResponse(statusCode: .notFound)
        }
        let serving = Task { try? await server.run() }
        try await server.waitUntilListening(timeout: 5)
        defer { serving.cancel() }
        let port = try #require(await server.resolvedPort())
        let model = record(at: URL(string: "http://127.0.0.1:\(port)/weights.gguf")!, size: 4096)

        await #expect(throws: (any Error).self) {
            for try await _ in await store.download(model) {}
        }
        #expect(await store.downloadsInFlight().isEmpty)
        await server.stop(timeout: 1)
    }

    /// The rule the inspector applies to the answer, with the id sourced from
    /// the store rather than from the app's own map.
    @Test("the store's answer is the one that keeps a pulled model's bytes")
    func orphanRuleUsesTheStoresAnswer() {
        let files = [StoredFile(path: "pulled-by-a-laptop.gguf", byteCount: 1_800_000_000)]

        // What the screen did: ask the app, which never heard about the pull.
        let fromTheApp = ModelDirectoryAudit.orphans(files: files, installedIDs: [], downloadingIDs: [])
        #expect(fromTheApp.count == 1, "this is the state the old guard was in")

        let fromTheStore = ModelDirectoryAudit.orphans(
            files: files, installedIDs: [], downloadingIDs: ["pulled-by-a-laptop"]
        )
        #expect(fromTheStore.isEmpty)
    }

    // MARK: - Helpers

    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
    }

    /// Polls rather than sleeps a fixed amount: the assertion is about a state
    /// being reached, and a fixed sleep either flakes or wastes the time.
    private func waitUntil(
        _ condition: @Sendable () async -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was never met")
    }
}
