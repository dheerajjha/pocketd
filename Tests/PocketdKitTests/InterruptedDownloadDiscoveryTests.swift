import Foundation
import Testing
@testable import PocketdKit

struct InterruptedDownloadDiscoveryTests {
    @Test("a saved catalogue resume blob is discovered after a fresh store loads")
    func restoresCatalogueCandidate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try #require(ModelCatalog.model(withID: "smollm2-360m"))
        let store = ModelStore(directory: directory, budget: DeviceBudget(physicalMemoryBytes: 8 << 30, hasIncreasedMemoryLimit: false))
        #expect(await store.interruptedDownloads().isEmpty)

        // Discovery only: URLSession, not this test, validates the blob on resume.
        try Data([1]).write(to: directory.appendingPathComponent("\(model.id).resume"))
        await store.load()
        #expect(await store.interruptedDownloads().map(\.id) == [model.id])
        #expect(await store.installed().isEmpty)
    }

    @Test("a stale resume sidecar does not make an installed model look paused")
    func installedModelIsExcluded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try #require(ModelCatalog.model(withID: "smollm2-360m"))
        let store = ModelStore(directory: directory, budget: DeviceBudget(physicalMemoryBytes: 8 << 30, hasIncreasedMemoryLimit: false))
        try Data([1]).write(to: store.fileURL(for: model))
        try Data([1]).write(to: directory.appendingPathComponent("\(model.id).resume"))
        try JSONEncoder().encode([model.id: model]).write(to: directory.appendingPathComponent("manifest.json"))
        await store.load()
        #expect(await store.isInstalled(model))
        #expect(await store.interruptedDownloads().isEmpty)
    }
}
