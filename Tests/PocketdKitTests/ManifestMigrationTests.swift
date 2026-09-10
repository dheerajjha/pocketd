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

@Suite("Catalogue promises")
struct CataloguePromiseTests {

    /// Two entries — the first two rows — answered 401 and 404 for weeks. The
    /// 401 was a gated Hugging Face repo, which cannot work without a token
    /// this app has no way to supply. `scripts/verify-catalogue.sh` checks the
    /// URLs over the network; this checks the shape offline so a bad entry
    /// cannot be added silently.
    @Test("no catalogue entry points at a first-party repository that gates")
    func noGatedRepositories() {
        // The rule is not "avoid Google models" — it is "avoid repositories
        // that require accepting terms", which the vendors' own GGUF repos do
        // and the community mirrors do not. A gated repo answers 401 from the
        // API itself, and this app has no token flow for a user to satisfy it.
        // scripts/verify-catalogue.sh proves reachability over the network;
        // this catches a bad entry being added offline.
        let gatingOwners = ["google/", "meta-llama/", "mistralai/"]
        for model in ModelCatalog.all {
            for owner in gatingOwners {
                #expect(model.repoID.hasPrefix(owner) == false,
                        "\(model.id) points at \(model.repoID); use a mirror")
            }
        }
    }

    @Test("the fit badge is computed from the real file size")
    func gemmaSizeIsTheRealOne() throws {
        // This entry previously claimed 1.8 GB, inferred from "2B effective
        // parameters". E2B is a MatFormer: the effective count describes the
        // compute, not the weights, and the file is 3.1 GB. The badge said
        // Fits on a 6 GB phone where it cannot fit even with the entitlement.
        let gemma = try #require(ModelCatalog.model(withID: "gemma-4-e2b"))
        #expect(gemma.sizeBytes > 3_000_000_000)

        let iPhone14 = DeviceBudget(physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
                                    hasIncreasedMemoryLimit: true)
        #expect(iPhone14.fit(for: gemma) == .willNotFit)
    }

    @Test("every entry declares a plausible size")
    func sizesArePlausible() {
        for model in ModelCatalog.all {
            // A size of zero, or a wildly wrong one, makes the memory fit badge
            // a lie — and the badge is what someone trusts before spending
            // gigabytes of bandwidth.
            #expect(model.sizeBytes > 100_000_000, "\(model.id) declares an implausible size")
            #expect(model.sizeBytes < 20_000_000_000)
            if model.projectorFilename != nil {
                #expect(model.projectorSizeBytes > 0, "\(model.id) has a projector with no declared size")
            }
        }
    }

    @Test("a tool-capable model is actually in the catalogue")
    func toolModelExists() {
        // V4 gates the device tools on a tool-capable model. If the only one
        // listed cannot be downloaded, the feature is unreachable.
        #expect(ModelCatalog.all.contains { $0.toolSupport == .yes })
    }
}
