import Foundation
import Testing
import FlyingFox
@testable import PocketdKit

/// Downloads real bytes over real HTTP from a real server.
///
/// The suite exists because the first implementation of this path iterated
/// `URLSession.bytes` one `UInt8` at a time. It was correct, it compiled, it
/// passed review, and it ran at 0.15 MB/s — 42 minutes for the smallest model in
/// the catalogue. Nothing short of moving actual megabytes catches that.
@Suite("Model downloads")
struct DownloadTests {

    /// Eight megabytes of deterministic bytes, served once.
    private static func makeBlob(megabytes: Int) -> Data {
        var data = Data(capacity: megabytes << 20)
        for index in 0..<(megabytes << 20) {
            data.append(UInt8(index % 251))
        }
        return data
    }

    private func withServer(
        serving blob: Data,
        _ body: (URL) async throws -> Void
    ) async throws {
        let server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: 0))
        await server.appendRoute("GET /weights.gguf") { _ in
            HTTPResponse(statusCode: .ok, headers: [.contentType: "application/octet-stream"], body: blob)
        }
        let task = Task { try? await server.run() }
        try await server.waitUntilListening(timeout: 5)
        defer {
            task.cancel()
        }
        guard let port = await server.resolvedPort() else {
            Issue.record("server did not report a port")
            return
        }
        try await body(URL(string: "http://127.0.0.1:\(port)/weights.gguf")!)
        await server.stop(timeout: 1)
    }

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
            id: "test-weights",
            displayName: "Test Weights",
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

    @Test("downloads a file byte-for-byte and installs it")
    func downloadsCorrectly() async throws {
        let blob = Self.makeBlob(megabytes: 2)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: blob) { url in
            let model = record(at: url, size: Int64(blob.count))
            var progressReports: [DownloadProgress] = []
            for try await progress in await store.download(model) {
                progressReports.append(progress)
            }

            #expect(await store.isInstalled(model))
            let written = try Data(contentsOf: store.fileURL(for: model))
            #expect(written == blob, "the installed file must match the served bytes exactly")
            #expect(progressReports.last?.fraction == 1.0)
            #expect(await store.installed().map(\.id) == ["test-weights"])
        }
    }

    /// The regression guard. A local server moves 8 MB in well under a second;
    /// the per-byte loop this replaced took 52 seconds for exactly this payload.
    /// Ten seconds is loose enough never to flake and tight enough that any
    /// return to per-element iteration fails here.
    @Test("moves 8 MB in seconds, not minutes", .timeLimit(.minutes(1)))
    func throughput() async throws {
        let blob = Self.makeBlob(megabytes: 8)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: blob) { url in
            let model = record(at: url, size: Int64(blob.count))
            let started = ContinuousClock.now
            for try await _ in await store.download(model) {}
            let elapsed = started.duration(to: .now)

            #expect(elapsed < .seconds(10), "8 MB took \(elapsed); a per-byte loop would take ~52s")
            #expect(try Data(contentsOf: store.fileURL(for: model)).count == blob.count)
        }
    }

    @Test("reports progress that advances toward the total")
    func progressAdvances() async throws {
        let blob = Self.makeBlob(megabytes: 4)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: blob) { url in
            let model = record(at: url, size: Int64(blob.count))
            var received: [Int64] = []
            for try await progress in await store.download(model) {
                received.append(progress.receivedBytes)
                #expect(progress.totalBytes > 0, "a total of zero renders as a bar stuck at 0%")
            }
            #expect(received == received.sorted(), "progress must be monotonic")
            #expect(received.last == Int64(blob.count))
        }
    }

    @Test("a cancelled download leaves nothing installed")
    func cancellation() async throws {
        let blob = Self.makeBlob(megabytes: 8)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: blob) { url in
            let model = record(at: url, size: Int64(blob.count))
            let task = Task {
                for try await _ in await store.download(model) {}
            }
            task.cancel()
            _ = await task.result

            #expect(await store.isInstalled(model) == false)
            #expect(await store.installed().isEmpty)
        }
    }

    @Test("surfaces an HTTP error instead of installing an error page")
    func httpFailure() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: 0))
        await server.appendRoute("GET /weights.gguf") { _ in
            HTTPResponse(statusCode: .notFound, body: Data("nope".utf8))
        }
        let task = Task { try? await server.run() }
        try await server.waitUntilListening(timeout: 5)
        defer { task.cancel() }
        let port = try #require(await server.resolvedPort())

        let model = record(at: URL(string: "http://127.0.0.1:\(port)/weights.gguf")!, size: 4)
        await #expect(throws: (any Error).self) {
            for try await _ in await store.download(model) {}
        }
        // The danger here is installing a 404 body as if it were weights.
        #expect(await store.isInstalled(model) == false)
        await server.stop(timeout: 1)
    }
}
