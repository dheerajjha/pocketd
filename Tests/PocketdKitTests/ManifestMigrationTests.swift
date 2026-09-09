import Foundation
import Testing
@testable import PocketdKit

@Suite("Manifest compatibility")
struct ManifestMigrationTests {

    /// Adding one non-optional field to ModelRecord made every manifest written
    /// by an older build fail to decode. The files were still on disk; the app
    /// reported nothing installed and offered to download them again.
    @Test("a manifest from before projector support still loads")
    func decodesOlderManifest() throws {
        let old = """
        {"sizeBytes":386000000,"quantization":"Q8_0","filename":"smollm2-360m-instruct-q8_0.gguf",
         "id":"smollm2-360m","displayName":"SmolLM2 360M","contextLength":8192,
         "repoID":"HuggingFaceTB/SmolLM2-360M-Instruct-GGUF","license":"Apache-2.0","parameters":"360M"}
        """
        let record = try JSONDecoder().decode(ModelRecord.self, from: Data(old.utf8))
        #expect(record.id == "smollm2-360m")
        #expect(record.projectorFilename == nil)
        #expect(record.projectorSizeBytes == 0)
    }

    @Test("a current record round-trips")
    func roundTrip() throws {
        let record = try #require(ModelCatalog.model(withID: "smolvlm-500m"))
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ModelRecord.self, from: data) == record)
    }

    @Test("the vision entries declare a projector and count it toward the budget")
    func visionEntries() throws {
        let vision = try #require(ModelCatalog.model(withID: "smolvlm-500m"))
        #expect(vision.projectorFilename != nil)
        #expect(vision.declaredCapabilities.vision == .yes)
        #expect(vision.estimatedResidentBytes > Int64(Double(vision.sizeBytes) * 1.25),
                "the projector is resident too; ignoring it is how someone gets jetsammed")

        let text = try #require(ModelCatalog.model(withID: "smollm2-360m"))
        #expect(text.declaredCapabilities.vision == .no)
        #expect(text.declaredCapabilities.ollamaCapabilities == ["completion"])
    }

    @Test("projector files are recognised by the convention everyone uses")
    func projectorNaming() {
        #expect(ModelRecord.isProjector(filename: "mmproj-model-f16.gguf"))
        #expect(ModelRecord.isProjector(filename: "mmproj-SmolVLM-500M-Instruct-Q8_0.gguf"))
        #expect(ModelRecord.isProjector(filename: "gemma-3-4b-it-Q4_K_M.gguf") == false)
    }
}
