import Foundation
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
