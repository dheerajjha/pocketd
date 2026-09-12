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
///
/// Serialized because these are real background transfers now. The system's
/// transfer daemon runs four of them at a time and then staggers the rest by
/// ten seconds and more, so fourteen download tests racing each other turned a
/// twenty-second package run into a fifty-second one. Nothing here needs to run
/// beside itself to be true.
@Suite("Model downloads", .serialized)
struct DownloadTests {

    /// Eight megabytes of deterministic bytes, served once.
    private static func makeBlob(megabytes: Int) -> Data {
        var data = Data(capacity: megabytes << 20)
        for index in 0..<(megabytes << 20) {
            data.append(UInt8(index % 251))
        }
        return data
    }

    /// Serialised against every other download suite. See DownloadSerialization.
    private func withServer(
        serving blob: Data,
        _ body: (URL) async throws -> Void
    ) async throws {
        await DownloadSerialization.shared.acquire()
        do {
            try await unlockedWithServer(serving: blob, body)
        } catch {
            await DownloadSerialization.shared.release()
            throw error
        }
        await DownloadSerialization.shared.release()
    }

    private func unlockedWithServer(
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

    /// The regression guard, expressed as throughput rather than wall clock.
    ///
    /// What it defends is real and specific: this download path once iterated
    /// `URLSession.bytes` one `UInt8` at a time and measured 0.15 MB/s, which
    /// is 52 seconds for this 8 MB payload and 42 minutes for the smallest
    /// model in the catalogue.
    ///
    /// It used to assert `elapsed < 10 seconds`, and that assertion measured
    /// the wrong thing twice over. The suite runs 113 suites in parallel, so
    /// the number it produced was mostly a statement about machine load — it
    /// passed at 8.6s run alone and failed at 15.7s run with everything else,
    /// on identical code. And the transfer now goes through a background
    /// URLSession, which hands the work to a system daemon and is legitimately
    /// slower to start for reasons that have nothing to do with the defect.
    ///
    /// A floor of 1 MB/s is nearly seven times the speed of the regression and
    /// a small fraction of any healthy result, so it still fails instantly if
    /// anyone returns to per-element iteration, and it stops failing because
    /// another suite happened to be compiling at the time.
    @Test("moves bytes in bulk, not one at a time", .timeLimit(.minutes(1)))
    func throughput() async throws {
        let blob = Self.makeBlob(megabytes: 8)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: blob) { url in
            let model = record(at: url, size: Int64(blob.count))
            let started = ContinuousClock.now
            for try await _ in await store.download(model) {}
            let elapsed = started.duration(to: .now)

            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let megabytesPerSecond = 8.0 / Swift.max(seconds, 0.0001)
            #expect(
                megabytesPerSecond > 1.0,
                "8 MB at \(String(format: "%.2f", megabytesPerSecond)) MB/s; the per-byte loop this guards against measured 0.15 MB/s"
            )
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
