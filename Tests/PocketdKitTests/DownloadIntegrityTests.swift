import Foundation
import Testing
import FlyingFox
import FlyingSocks
@testable import PocketdKit

/// A truncated GGUF does not fail politely at the reader — it takes llama.cpp,
/// and on a phone that is serving there is no crash dialog to see. So these run
/// over real HTTP against a real server, the same way `DownloadTests` does, and
/// they check the one thing that used to be checked nowhere: that the bytes
/// which arrived are the bytes that were promised.
///
/// Serialized for the reason `DownloadTests` is: four concurrent background
/// transfers is all the system will run at once.
@Suite("Download integrity", .serialized)
struct DownloadIntegrityTests {

    /// Deterministic filler. Byte-for-byte correctness is `DownloadTests`'
    /// job; here only the length matters, so this does not build it a byte at
    /// a time.
    private static func blob(bytes: Int) -> Data {
        Data(repeating: 0xA5, count: bytes)
    }

    /// A body FlyingFox cannot count, and therefore serves chunked with no
    /// `Content-Length`.
    ///
    /// This is the case that matters. When a server *does* announce a length,
    /// URLSession itself refuses to report success on a short read — the
    /// transfer errors and nothing reaches the manifest. The hole this closes
    /// is the server that announces nothing, where a dropped connection ends a
    /// chunked response cleanly and a half-written file looks finished.
    private struct UncountedBytes: AsyncBufferedSequence {
        typealias Element = UInt8
        let data: Data

        func makeAsyncIterator() -> Iterator { Iterator(remaining: data) }

        struct Iterator: AsyncBufferedIteratorProtocol {
            var remaining: Data

            mutating func nextBuffer(suggested count: Int) async throws -> Data? {
                guard !remaining.isEmpty else { return nil }
                // Qualified: an unqualified `max` inside an AsyncSequence
                // iterator resolves to `AsyncSequence.max()`.
                let chunk = remaining.prefix(Swift.max(1, count))
                remaining = remaining.dropFirst(chunk.count)
                return Data(chunk)
            }

            mutating func next() async throws -> UInt8? {
                guard let first = remaining.first else { return nil }
                remaining = remaining.dropFirst()
                return first
            }
        }
    }

    private func withServer(
        serving blob: Data,
        announcingLength: Bool,
        _ body: (URL) async throws -> Void
    ) async throws {
        let server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: 0))
        await server.appendRoute("GET /weights.gguf") { _ in
            let headers: HTTPHeaders = [.contentType: "application/octet-stream"]
            return announcingLength
                ? HTTPResponse(statusCode: .ok, headers: headers, body: blob)
                : HTTPResponse(
                    statusCode: .ok,
                    headers: headers,
                    body: HTTPBodySequence(from: UncountedBytes(data: blob))
                )
        }
        let task = Task { try? await server.run() }
        try await server.waitUntilListening(timeout: 5)
        defer { task.cancel() }
        let port = try #require(await server.resolvedPort())
        try await body(URL(string: "http://127.0.0.1:\(port)/weights.gguf")!)
        await server.stop(timeout: 1)
    }

    private func makeStore() throws -> (ModelStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            ModelStore(
                directory: directory,
                budget: DeviceBudget(physicalMemoryBytes: 16 << 30, hasIncreasedMemoryLimit: true)
            ),
            directory
        )
    }

    private func record(
        at url: URL,
        size: Int64,
        projectorSize: Int64 = 0,
        projector: String? = nil
    ) -> ModelRecord {
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
            sourceURL: url,
            projectorFilename: projector,
            projectorSizeBytes: projectorSize
        )
    }

    /// The error a download threw, or `nil` if it finished. `#expect(throws:)`
    /// with a bare type would also be satisfied by a connection refusal, which
    /// is not what any of these are testing.
    private func failure(of stream: AsyncThrowingStream<DownloadProgress, any Error>) async -> (any Error)? {
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }

    /// One million, because 0.1% of it is exactly one thousand bytes and the
    /// boundary tests below can then be written in whole bytes rather than in
    /// hope.
    private let expectedSize: Int64 = 1_000_000

    // MARK: Rejection

    @Test("refuses a file that arrived short, and leaves nothing behind")
    func shortFileIsRejected() async throws {
        let payload = Self.blob(bytes: 900_000)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: payload, announcingLength: false) { url in
            let model = record(at: url, size: expectedSize)

            await #expect(throws: ModelStoreError.incompleteDownload(
                model: "Test Weights", expected: expectedSize, actual: 900_000
            )) {
                for try await _ in await store.download(model) {}
            }

            #expect(await store.isInstalled(model) == false,
                    "a truncated GGUF in the manifest is a crash waiting for the next load")
            #expect(await store.installed().isEmpty)
            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: model).path) == false,
                    "the partial must go, or it sits there costing gigabytes with nothing referencing it")
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("test-weights.resume").path
            ) == false)
        }
    }

    @Test("refuses a file that arrived long")
    func overlongFileIsRejected() async throws {
        // What a resume that went wrong produces: a server that ignored the
        // Range header and sent the whole body to be appended to bytes already
        // on disk. Just as unloadable as a short one.
        let payload = Self.blob(bytes: 1_100_000)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: payload, announcingLength: false) { url in
            let model = record(at: url, size: expectedSize)
            let error = await failure(of: await store.download(model))
            guard case .incompleteDownload = error as? ModelStoreError else {
                Issue.record("expected an integrity refusal, got \(String(describing: error))")
                return
            }
            #expect(await store.isInstalled(model) == false)
        }
    }

    @Test("the error tells the user the file is incomplete and to fetch it again")
    func errorIsActionable() {
        let message = ModelStoreError
            .incompleteDownload(model: "Gemma 3n", expected: 1_000_000, actual: 900_000)
            .errorDescription ?? ""
        #expect(message.contains("Gemma 3n"))
        #expect(message.lowercased().contains("did not download completely"))
        #expect(message.lowercased().contains("again"))
    }

    // MARK: Acceptance

    @Test("installs a file whose length is exactly right")
    func exactFileIsAccepted() async throws {
        let payload = Self.blob(bytes: Int(expectedSize))
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: payload, announcingLength: false) { url in
            let model = record(at: url, size: expectedSize)
            for try await _ in await store.download(model) {}
            #expect(await store.isInstalled(model))
            #expect(try Data(contentsOf: store.fileURL(for: model)).count == payload.count)
        }
    }

    // MARK: The 0.1% boundary

    @Test("accepts a file exactly at the edge of the tolerance")
    func toleranceBoundaryAccepts() async throws {
        // 1,000 bytes short of 1,000,000 is a drift of exactly 0.001.
        let payload = Self.blob(bytes: 999_000)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: payload, announcingLength: false) { url in
            let model = record(at: url, size: expectedSize)
            for try await _ in await store.download(model) {}
            #expect(await store.isInstalled(model),
                    "the band exists for a hand-written catalogue figure that rounds; it must not reject at its own edge")
        }
    }

    @Test("refuses a file one byte past the edge of the tolerance")
    func toleranceBoundaryRejects() async throws {
        let payload = Self.blob(bytes: 998_999)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: payload, announcingLength: false) { url in
            let model = record(at: url, size: expectedSize)
            let error = await failure(of: await store.download(model))
            guard case .incompleteDownload = error as? ModelStoreError else {
                Issue.record("expected an integrity refusal, got \(String(describing: error))")
                return
            }
            #expect(await store.isInstalled(model) == false)
        }
    }

    // MARK: Which number to trust

    @Test("believes the server's Content-Length over a catalogue entry that is wrong")
    func announcedLengthBeatsTheCatalogue() async throws {
        // The Gemma case, reproduced: a hand-typed catalogue size out by more
        // than a gigabyte. Checking against it would make the entry permanently
        // uninstallable, and the file that arrived is provably complete —
        // the server said how many bytes it was sending and sent them all.
        let payload = Self.blob(bytes: 4 << 20)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(serving: payload, announcingLength: true) { url in
            let model = record(at: url, size: Int64(payload.count) + 1_300_000_000)
            for try await _ in await store.download(model) {}

            #expect(await store.isInstalled(model))
            // And the manifest keeps the size that was measured, not the one
            // that was typed — every later fit estimate reads this.
            #expect(await store.installed().first?.sizeBytes == Int64(payload.count))
        }
    }

    // MARK: Disk

    @Test("counts the projector's bytes in the disk pre-check")
    func diskCheckIncludesTheProjector() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let free = try #require(
            directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        )
        // Weights that fit on their own; a projector that takes the pair past
        // the end of the disk. Before the projector was counted, this started
        // downloading and died partway through the second file.
        let model = record(
            at: URL(string: "http://127.0.0.1:1/weights.gguf")!,
            size: 1 << 20,
            projectorSize: free,
            projector: "mmproj.gguf"
        )

        // Oversized-allowed so the memory gate, which runs first, does not
        // answer instead of the disk gate.
        let error = await failure(of: await store.download(model, allowingOversized: true))
        guard case .insufficientDisk = error as? ModelStoreError else {
            Issue.record("expected a disk refusal, got \(String(describing: error))")
            return
        }
    }

    @Test("leaves headroom rather than filling the volume to the last byte")
    func diskCheckLeavesHeadroom() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let free = try #require(
            directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        )
        // Fits by the old arithmetic — free space minus a hundred megabytes —
        // and lands the device inside the reserve, where iOS starts evicting
        // and the app becomes a termination candidate.
        let model = record(
            at: URL(string: "http://127.0.0.1:1/weights.gguf")!,
            size: free - (100 << 20)
        )

        let error = await failure(of: await store.download(model, allowingOversized: true))
        guard case .insufficientDisk = error as? ModelStoreError else {
            Issue.record("expected a disk refusal, got \(String(describing: error))")
            return
        }
    }
}
