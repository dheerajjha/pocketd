import Testing
import Foundation
@testable import PocketdKit

@Suite("Model transfers")
struct ModelTransferTests {

    private func searched(_ id: String = "unsloth-qwen3-1.7b-q4-k-m") -> ModelRecord {
        // Exactly what the search screen builds: an id derived from the
        // repository and filename, which by construction is nothing the
        // curated catalogue has ever heard of.
        HuggingFaceSearch.record(
            repository: "unsloth/Qwen3-1.7B-GGUF",
            file: try! JSONDecoder().decode(
                HuggingFaceSearch.File.self,
                from: Data(#"{"path":"Qwen3-1.7B-Q4_K_M.gguf","sizeBytes":1117000000}"#.utf8)
            )
        )
    }

    // MARK: The regression

    @Test("a model downloading from search appears in the listing")
    func searchDownloadIsVisible() {
        // The bug this suite exists for. Every list on the device was built by
        // walking `ModelCatalog.all` plus what the manifest said was installed
        // — and a download in flight is in neither. So a model pulled from
        // Hugging Face had no row on the Models tab, no banner above the tabs,
        // no percentage and no cancel button, for the entire several minutes it
        // was running. The app was working and completely silent about it.
        let record = searched()
        #expect(ModelCatalog.all.contains { $0.id == record.id } == false,
                "precondition: a searched model is not a catalogue model")

        let listing = ModelCatalog.listing(installed: [], transferring: [record])
        #expect(listing.contains { $0.id == record.id })
    }

    @Test("a curated model keeps its written name once installed")
    func catalogueWinsOnID() {
        // The manifest stores whatever was downloaded, including a display
        // name. For a catalogue model that name should stay the one someone
        // wrote, not the filename.
        var installed = ModelCatalog.all[0]
        let curatedName = installed.displayName
        installed.displayName = "qwen3-1.7b-q4_k_m"

        let listing = ModelCatalog.listing(installed: [installed], transferring: [])
        #expect(listing.first { $0.id == installed.id }?.displayName == curatedName)
        #expect(listing.count == ModelCatalog.all.count, "no duplicate row")
    }

    @Test("a model that is both installed and re-downloading appears once")
    func noDuplicateRows() {
        let record = searched()
        let listing = ModelCatalog.listing(installed: [record], transferring: [record])
        #expect(listing.filter { $0.id == record.id }.count == 1)
    }

    @Test("listing order puts curated models first")
    func order() {
        let record = searched()
        let listing = ModelCatalog.listing(installed: [], transferring: [record])
        #expect(listing.prefix(ModelCatalog.all.count).map(\.id) == ModelCatalog.all.map(\.id))
        #expect(listing.last?.id == record.id)
    }

    // MARK: Lifecycle

    @Test("a started transfer is active before any byte arrives")
    func waitingIsActive() {
        let transfer = ModelTransfer(record: searched(), state: .waiting)
        #expect(transfer.isActive)
        #expect(transfer.fraction == 0)
        #expect(transfer.isWorthShowing())
    }

    @Test("a pause keeps the bytes it got to")
    func pauseKeepsProgress() {
        // The bar snapping to empty on a pause says the 500 MB is gone, which
        // is the one thing that is not true: they are on disk and the next tap
        // resumes them.
        var transfer = ModelTransfer(record: searched(), state: .waiting)
        transfer.advance(to: .running(DownloadProgress(
            modelID: transfer.id, receivedBytes: 500_000_000, totalBytes: 1_000_000_000
        )))
        #expect(transfer.fraction == 0.5)

        transfer.advance(to: .paused("Paused — 477 MB kept."))
        #expect(transfer.isActive == false)
        #expect(transfer.fraction == 0.5, "a paused download has not lost its bytes")
        #expect(transfer.bytesSoFar?.receivedBytes == 500_000_000)
    }

    @Test("a failure keeps the bytes too")
    func failureKeepsProgress() {
        var transfer = ModelTransfer(record: searched(), state: .running(
            DownloadProgress(modelID: "x", receivedBytes: 300, totalBytes: 1_200)
        ))
        transfer.advance(to: .failed("The download failed."))
        #expect(transfer.fraction == 0.25)
    }

    @Test("stopping keeps its bytes and offers nothing yet")
    func stoppingIsNotYetPaused() {
        // The state that exists because URLSession answers "can this resume?"
        // seconds after the cancel, not at it. Anything that treats stopping
        // as active gets it deleted by the download task's own cancellation
        // callback a moment later.
        var transfer = ModelTransfer(record: searched(), state: .running(
            DownloadProgress(modelID: "x", receivedBytes: 500, totalBytes: 1_000)
        ))
        transfer.advance(to: .stopping)
        #expect(transfer.isActive == false, "bytes have stopped moving")
        #expect(transfer.isWorthShowing(), "the user just tapped Stop; say something")
        #expect(transfer.fraction == 0.5, "the bytes are still there to show")
    }

    @Test("a finished transfer reads as full")
    func finishedIsFull() {
        let transfer = ModelTransfer(record: searched(), state: .finished(at: Date()))
        #expect(transfer.fraction == 1)
        #expect(transfer.isActive == false)
    }

    @Test("the finished notice expires but a failure does not")
    func noticeExpiry() {
        let now = Date()
        let done = ModelTransfer(record: searched(), state: .finished(at: now.addingTimeInterval(-30)))
        #expect(done.isWorthShowing(now: now) == false)

        let justDone = ModelTransfer(record: searched(), state: .finished(at: now.addingTimeInterval(-1)))
        #expect(justDone.isWorthShowing(now: now))

        // A failure has to be read to be acted on, and the person may be in
        // another app when it happens. It waits.
        let failed = ModelTransfer(record: searched(), state: .failed("No network."))
        #expect(failed.isWorthShowing(now: now.addingTimeInterval(3600)))
    }

    @Test("a transfer's total counts the projector a vision model needs")
    func visionTotalIncludesProjector() {
        // Two files, one download. Sizing the bar against the weights alone
        // meant a vision model's bar hit 100% and then kept going.
        var record = searched()
        record.projectorFilename = "mmproj-F16.gguf"
        record.projectorSizeBytes = 300_000_000
        #expect(record.totalDownloadBytes == record.sizeBytes + 300_000_000)
    }
}
