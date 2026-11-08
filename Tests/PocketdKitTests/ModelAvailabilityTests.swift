import Foundation
import FlyingFox
import FlyingSocks
import Testing
@testable import PocketdKit

struct ModelAvailabilityTests {
    private func fixture() throws -> (URL, ModelRecord, Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data(repeating: 42, count: 4096)
        var model = ModelCatalog.model(withID: "smollm2-360m")!
        model.sizeBytes = Int64(bytes.count)
        try bytes.write(to: directory.appendingPathComponent("\(model.id).gguf"))
        try JSONEncoder().encode([model.id: model]).write(to: directory.appendingPathComponent("manifest.json"))
        return (directory, model, bytes)
    }

    private func store(_ directory: URL) -> ModelStore {
        ModelStore(directory: directory, budget: DeviceBudget(physicalMemoryBytes: 8 << 30, hasIncreasedMemoryLimit: false, environment: .device))
    }

    @Test("missing for one launch never rewrites the manifest and matching bytes return as installed")
    func temporarilyMissing() async throws {
        let (directory, model, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifest)
        let first = store(directory)
        await first.load()
        #expect(await first.isInstalled(model))
        let parked = directory.appendingPathComponent("parked.gguf")
        try FileManager.default.moveItem(at: first.fileURL(for: model), to: parked)
        let missing = store(directory)
        await missing.load()
        #expect(await missing.installed().isEmpty)
        #expect(await missing.unavailable().map(\.id) == [model.id])
        #expect(await missing.localURL(forID: model.id) == nil)
        #expect(try Data(contentsOf: manifest) == original)
        try FileManager.default.moveItem(at: parked, to: first.fileURL(for: model))
        let restored = store(directory)
        await restored.load()
        #expect(await restored.isInstalled(model))
        #expect(await restored.unavailable().isEmpty)
        #expect(try Data(contentsOf: manifest) == original)
    }

    @Test("same-sized changed bytes remain unavailable without replacing the expected fingerprint")
    func hashMismatch() async throws {
        let (directory, model, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = store(directory)
        await first.load()
        let integrity = directory.appendingPathComponent("integrity.json")
        let expected = try Data(contentsOf: integrity)
        try Data(repeating: 43, count: original.count).write(to: first.fileURL(for: model))
        let changed = store(directory)
        await changed.load()
        #expect(await changed.installed().isEmpty)
        #expect(try Data(contentsOf: integrity) == expected)
        try original.write(to: first.fileURL(for: model))
        await changed.load()
        #expect(await changed.isInstalled(model))
    }

    @Test("unreadable integrity metadata never becomes an empty replacement ledger")
    func unreadableLedger() async throws {
        let (directory, model, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let integrity = directory.appendingPathComponent("integrity.json")
        let broken = Data("not json".utf8)
        try broken.write(to: integrity)
        let library = store(directory)
        await library.load()
        #expect(await library.installed().isEmpty)
        #expect(await library.unavailable().map(\.id) == [model.id])
        do { try await library.delete(model); Issue.record("unreadable metadata allowed deletion") }
        catch {}
        #expect(try Data(contentsOf: integrity) == broken)
        #expect(FileManager.default.fileExists(atPath: library.fileURL(for: model).path))
        #expect(ModelFileRole.of(fileNamed: "integrity.json") == .manifest)
    }
}

@Suite("Unavailable model recovery", .serialized)
struct ModelRecoveryTests {
    private let bytes = Data(repeating: 42, count: 4096)

    private func withStore(_ body: (ModelStore, URL, ModelRecord) async throws -> Void) async throws {
        await DownloadSerialization.shared.acquire()
        do { try await runWithStore(body) }
        catch {
            await DownloadSerialization.shared.release()
            throw error
        }
        await DownloadSerialization.shared.release()
    }

    private func runWithStore(_ body: (ModelStore, URL, ModelRecord) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: 0))
        let payload = bytes
        await server.appendRoute("GET /weights.gguf") { _ in HTTPResponse(statusCode: .ok, body: payload) }
        let task = Task { try? await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening(timeout: 5)
        let port = try #require(await server.resolvedPort())
        let store = ModelStore(directory: directory, budget: DeviceBudget(
            physicalMemoryBytes: 8 << 30, hasIncreasedMemoryLimit: false, environment: .device
        ))
        var model = try #require(ModelCatalog.model(withID: "smollm2-360m"))
        model.sizeBytes = Int64(bytes.count)
        model.sourceURL = URL(string: "http://127.0.0.1:\(port)/weights.gguf")!
        for try await _ in await store.download(model) {}
        try await body(store, directory, model)
        await server.stop(timeout: 1)
    }

    private func manifest(_ directory: URL) throws -> [String: ModelRecord] {
        try JSONDecoder().decode([String: ModelRecord].self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    @Test("a rejected truncated model downloads again into the same saved entry and source")
    func downloadAgainAfterTruncation() async throws {
        try await withStore { store, directory, model in
            try bytes.prefix(100).write(to: store.fileURL(for: model))
            await store.load()
            #expect(await store.installed().isEmpty)
            #expect(await store.unavailable().map(\.id) == [model.id])
            #expect(!ProAccess.brainNeedsPro(id: model.id, recommendedID: "another-model",
                onPhone: Set(await store.unavailable().map(\.id))))
            var catalogueCopy = model
            catalogueCopy.sourceURL = URL(string: "http://127.0.0.1:1/wrong-source")!
            for try await _ in await store.download(catalogueCopy, restarting: true) {}
            #expect(try Data(contentsOf: store.fileURL(for: model)) == bytes)
            #expect(await store.isInstalled(model))
            #expect(await store.unavailable().isEmpty)
            #expect(try manifest(directory).keys.sorted() == [model.id])
            #expect(try manifest(directory)[model.id]?.sourceURL == model.sourceURL)
            await store.load()
            #expect(await store.isInstalled(model), "replacement fingerprint survives a reload")
        }
    }

    @Test("download again recovers even after the rejected file was manually deleted")
    func downloadAgainAfterDeletingBadFile() async throws {
        try await withStore { store, directory, model in
            try Data(repeating: 43, count: bytes.count).write(to: store.fileURL(for: model))
            await store.load()
            #expect(await store.installed().isEmpty)
            try FileManager.default.removeItem(at: store.fileURL(for: model))
            await store.load()
            for try await _ in await store.download(model, restarting: true) {}
            #expect(await store.isInstalled(model))
            #expect(try Data(contentsOf: store.fileURL(for: model)) == bytes)
            #expect(try manifest(directory).count == 1)
        }
    }

    @Test("remove clears a rejected entry, weights, resume metadata and its staging file")
    func removeRejectedModel() async throws {
        try await withStore { store, directory, model in
            try bytes.prefix(100).write(to: store.fileURL(for: model))
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("CFNetworkDownload-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            try bytes.write(to: staged)
            let resume = directory.appendingPathComponent("\(model.id).resume")
            try PropertyListSerialization.data(fromPropertyList: [
                "NSURLSessionResumeInfoTempFileName": staged.lastPathComponent
            ], format: .binary, options: 0).write(to: resume)
            await store.load()
            #expect(await store.unavailable().map(\.id) == [model.id])
            try await store.delete(model)
            #expect(try manifest(directory).isEmpty)
            #expect(await store.installed().isEmpty)
            #expect(await store.unavailable().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: model).path))
            #expect(!FileManager.default.fileExists(atPath: resume.path))
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            let ledger = try JSONDecoder().decode([String: ModelFileIntegrity].self,
                from: Data(contentsOf: directory.appendingPathComponent("integrity.json")))
            #expect(ledger[model.id] == nil)
            await store.load()
            #expect(await store.unavailable().isEmpty)
        }
    }

    @Test("remove also forgets an entry whose file is already missing")
    func removeMissingModel() async throws {
        try await withStore { store, directory, model in
            try FileManager.default.removeItem(at: store.fileURL(for: model))
            await store.load()
            try await store.delete(model)
            #expect(try manifest(directory).isEmpty)
            #expect(await store.unavailable().isEmpty)
            #expect(await store.localURL(forID: model.id) == nil)
        }
    }

    @Test("remove clears rejected vision weights, projector and both resume blobs")
    func removeRejectedVisionModel() async throws {
        try await withStore { store, directory, original in
            var model = original
            model.projectorFilename = "projector.gguf"
            model.projectorSizeBytes = Int64(bytes.count)
            let projector = try #require(store.projectorURL(for: model))
            try bytes.write(to: projector)
            try bytes.prefix(100).write(to: store.fileURL(for: model))
            try JSONEncoder().encode([model.id: model]).write(to: directory.appendingPathComponent("manifest.json"))
            let weightsResume = directory.appendingPathComponent("\(model.id).resume")
            let projectorResume = directory.appendingPathComponent("\(model.id).mmproj.resume")
            try bytes.write(to: weightsResume)
            try bytes.write(to: projectorResume)
            await store.load()
            #expect(await store.unavailable().map(\.id) == [model.id])
            try await store.delete(original)
            #expect(try manifest(directory).isEmpty)
            for file in [store.fileURL(for: model), projector, weightsResume, projectorResume] {
                #expect(!FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    @Test("a failed clean replacement retains the owned entry and its recovery actions")
    func failedReplacementKeepsEntry() async throws {
        try await withStore { store, directory, original in
            var model = original
            model.sourceURL = original.sourceURL!.deletingLastPathComponent().appendingPathComponent("missing.gguf")
            try JSONEncoder().encode([model.id: model]).write(to: directory.appendingPathComponent("manifest.json"))
            try bytes.prefix(100).write(to: store.fileURL(for: model))
            await store.load()
            do {
                for try await _ in await store.download(model, restarting: true) {}
                Issue.record("a missing remote file was accepted")
            } catch {
                #expect(error as? ModelStoreError == .httpStatus(404))
            }
            #expect(try manifest(directory)[model.id] != nil)
            #expect(await store.unavailable().map(\.id) == [model.id])
            #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: model).path))
            try await store.delete(model)
            #expect(try manifest(directory).isEmpty)
        }
    }
}
