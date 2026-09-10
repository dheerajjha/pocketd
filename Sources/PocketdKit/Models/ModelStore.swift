import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public var modelID: String
    public var receivedBytes: Int64
    public var totalBytes: Int64

    public init(modelID: String, receivedBytes: Int64, totalBytes: Int64) {
        self.modelID = modelID
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
    }
}

public enum ModelStoreError: Error, Sendable, Equatable {
    case insufficientMemory(model: String)
    case insufficientDisk(needed: Int64, free: Int64)
    case httpStatus(Int)
    case notInstalled(String)
    /// The bytes on disk are not the bytes that were promised. Carries both
    /// numbers because "incomplete" on its own is not something a user can act
    /// on, and because the gap is the evidence that this was truncation rather
    /// than a wrong catalogue entry.
    case incompleteDownload(model: String, expected: Int64, actual: Int64)
}

extension ModelStoreError: LocalizedError {
    /// Without this the UI printed `httpStatus(401)` at the user. The 401 in
    /// particular needs explaining rather than showing: it means the Hugging
    /// Face repository is gated, which no amount of retrying will fix.
    public var errorDescription: String? {
        switch self {
        case .insufficientMemory(let model):
            "\(model) is larger than this device can hold."
        case let .insufficientDisk(needed, free):
            "Needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) and only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is free."
        case .httpStatus(401), .httpStatus(403):
            "This model's repository requires a Hugging Face account. Pocketd cannot download it."
        case .httpStatus(404):
            "This model is no longer published at that address."
        case .httpStatus(let code):
            "The download server answered \(code)."
        case .notInstalled(let model):
            "\(model) is not downloaded."
        case let .incompleteDownload(model, expected, actual):
            """
            \(model) did not download completely — \
            \(ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)) of \
            \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)) arrived. \
            The partial file has been removed; download it again.
            """
        }
    }
}

/// A download that stopped for a reason that will pass.
public enum DownloadInterruption: Sendable, Equatable {
    case connectionLost
    case offline

    /// iOS suspends the app the moment the user switches away, which drops the
    /// transfer. That is documented platform behaviour, not a failure, and the
    /// resume data on disk means the bytes are not lost — so it must not be
    /// reported as an error, least of all by printing the NSError, whose
    /// userInfo carries the signed CDN URL and the whole resume blob.
    public static func from(_ error: any Error) -> DownloadInterruption? {
        switch (error as NSError).code {
        case NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut:
            return .connectionLost
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
            return .offline
        default:
            return nil
        }
    }

    public var message: String {
        switch self {
        case .connectionLost: "Paused — Pocketd has to stay open to download. Tap to resume."
        case .offline: "Paused — no network. Tap to resume."
        }
    }
}

/// What the server said this transfer would deliver, watched as it happens.
///
/// The size to check a finished download against is a genuine choice, and the
/// catalogue is the wrong end of it. `ModelRecord.sizeBytes` is metadata typed
/// by hand and it has been wrong in this project by 1.3 GB on a Gemma entry —
/// checking against it makes a typo indistinguishable from a truncated file and
/// turns a cosmetic bug into a model nobody can ever install. `Content-Length`
/// is what *this* transfer promised, from the CDN that is actually serving the
/// object, and truncation is by definition "fewer bytes arrived than were
/// promised". So the announcement wins wherever there is one, and the catalogue
/// is only the fallback for a server that sends no length at all — which is
/// also the one case where URLSession itself cannot notice a short read.
///
/// `expected` is tracked against `written` because a resumed transfer can
/// report the length of the *range* rather than of the file. An announcement
/// smaller than the bytes that actually landed is not a statement about the
/// file's size, so it is discarded rather than used to reject a complete
/// download for being too long.
// The delegate calls in on URLSession's queue while the actor reads the result,
// so the lock is doing real work — the same arrangement, and the same reason,
// as `FileDownloader`'s.
private final class AnnouncedSize: @unchecked Sendable {
    private let lock = NSLock()
    private var expected: Int64 = 0
    private var written: Int64 = 0

    func observe(written bytes: Int64, expected total: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if total > expected { expected = total }
        if bytes > written { written = bytes }
    }

    /// The announced total, or `nil` when there was none or it contradicts the
    /// transfer.
    var bytes: Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard expected > 0, expected >= written else { return nil }
        return expected
    }
}

/// Owns the model files on disk and the manifest that describes them.
///
/// Downloads resume. This is not a nicety: the files are gigabytes, the device
/// is a phone on a cellular-or-wifi boundary, and iOS will suspend the app the
/// moment the user switches away. A download that restarts from zero every time
/// the screen locks never finishes.
public actor ModelStore {
    private let directory: URL
    private let session: URLSession
    private var budget: DeviceBudget
    private var manifest: [String: ModelRecord] = [:]

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    /// Keeps the download gate honest when the context limit changes.
    ///
    /// The gate refuses a model that will not fit, and what fits depends on the
    /// context being served — raising the limit in Settings can turn a model
    /// that was downloadable into one that is not, and the store has to hear
    /// about it or it will keep answering from a stale budget.
    public func updateBudget(_ budget: DeviceBudget) {
        self.budget = budget
    }

    public init(directory: URL, budget: DeviceBudget, session: URLSession = .shared) {
        self.directory = directory
        self.budget = budget
        self.session = session
    }

    /// Default location: Application Support, excluded from iCloud backup.
    /// Multi-gigabyte weights that can be re-downloaded have no business in a
    /// user's backup, and Apple will reject an app that puts them there.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutable = dir
            try mutable.setResourceValues(resourceValues)
        }
        return dir
    }

    public func load() async {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([String: ModelRecord].self, from: data)
        else { return }
        // Drop entries whose file vanished — a manifest that lies about what is
        // installed produces a `/v1/models` list the server cannot actually serve.
        manifest = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0.value).path) }
        if manifest.count != decoded.count { persist() }
    }

    public func installed() -> [ModelRecord] {
        manifest.values.sorted { $0.displayName < $1.displayName }
    }

    public func isInstalled(_ model: ModelRecord) -> Bool {
        manifest[model.id] != nil
    }

    public nonisolated func fileURL(for model: ModelRecord) -> URL {
        directory.appendingPathComponent("\(model.id).gguf")
    }

    /// Where the multimodal projector lives, when the model has one.
    public nonisolated func projectorURL(for model: ModelRecord) -> URL? {
        guard model.projectorFilename != nil else { return nil }
        return directory.appendingPathComponent("\(model.id).mmproj.gguf")
    }

    public func localURL(forID id: String) -> URL? {
        manifest[id].map { fileURL(for: $0) }
    }

    /// Discards a paused download's resume data. The partial bytes live in
    /// URLSession's own temporary storage, which the system reclaims once
    /// the resume blob that references them is gone.
    public func discardPartial(_ model: ModelRecord) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: model))
        if model.projectorFilename != nil {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(model.id).mmproj.resume")
            )
        }
    }

    public func delete(_ model: ModelRecord) throws {
        discardFiles(for: model)
        manifest[model.id] = nil
        persist()
    }

    /// Streams progress until the file is on disk and in the manifest.
    ///
    /// `allowingOversized` exists because the fit estimate is an estimate. It is
    /// right often enough to be worth a warning and wrong often enough that
    /// refusing outright would be the app overruling someone who knows their own
    /// device better than a heuristic does.
    public func download(
        _ model: ModelRecord,
        allowingOversized: Bool = false
    ) -> AsyncThrowingStream<DownloadProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performDownload(model, allowingOversized: allowingOversized) { progress in
                        continuation.yield(progress)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performDownload(
        _ model: ModelRecord,
        allowingOversized: Bool,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        guard allowingOversized || budget.fit(for: model).allowsDownload else {
            throw ModelStoreError.insufficientMemory(model: model.id)
        }
        try checkDiskSpace(for: model)

        let destination = fileURL(for: model)
        let resumeURL = resumeDataURL(for: model)
        let resumeData = try? Data(contentsOf: resumeURL)
        let declaredSize = model.sizeBytes
        let id = model.id
        let announced = AnnouncedSize()

        let downloader = FileDownloader(
            destination: destination,
            resumeDataURL: resumeURL
        ) { received, expected in
            announced.observe(written: received, expected: expected)
            onProgress(DownloadProgress(
                modelID: id,
                receivedBytes: received,
                // URLSession reports -1 when the server sends no length, which
                // renders as a progress bar stuck at zero. The catalogue size is
                // the better estimate in that case.
                totalBytes: expected > 0 ? expected + model.projectorSizeBytes : declaredSize + model.projectorSizeBytes
            ))
        }

        do {
            try await run(downloader, for: model, resumeData: resumeData)
        } catch {
            // A resume that fails is usually stale validators — the file moved
            // or the CDN rotated. Retrying clean turns "tap Download, watch it
            // fail, tap again" into one working tap.
            guard resumeData != nil, !(error is CancellationError) else { throw error }
            try? FileManager.default.removeItem(at: resumeURL)
            let retry = FileDownloader(destination: destination, resumeDataURL: resumeURL) { received, expected in
                announced.observe(written: received, expected: expected)
                onProgress(DownloadProgress(
                    modelID: id,
                    receivedBytes: received,
                    totalBytes: expected > 0 ? expected + model.projectorSizeBytes : declaredSize + model.projectorSizeBytes
                ))
            }
            try await run(retry, for: model, resumeData: nil)
        }

        // Before anything else touches these bytes. A GGUF that is short by a
        // chunk does not fail politely at the reader — it takes llama.cpp, and
        // with it the process, and on a phone that is serving there is no crash
        // dialog to see: what happens is that a laptop's connection drops
        // mid-answer with no error anywhere.
        let weightsBytes = try verifiedSize(
            of: destination,
            announced: announced.bytes,
            catalogued: declaredSize,
            model: model
        )

        // The projector is useless on its own and the weights are useless
        // without it for a vision model, so the model is not marked installed
        // until both are on disk — and, since this landed, until both are the
        // size they were meant to be.
        var projectorBytes = model.projectorSizeBytes
        if let remote = model.projectorURL, let local = projectorURL(for: model) {
            let projectorResume = directory.appendingPathComponent("\(model.id).mmproj.resume")
            let total = declaredSize + model.projectorSizeBytes
            let projectorAnnounced = AnnouncedSize()
            let downloader = FileDownloader(destination: local, resumeDataURL: projectorResume) { received, expected in
                projectorAnnounced.observe(written: received, expected: expected)
                onProgress(DownloadProgress(
                    modelID: id,
                    receivedBytes: declaredSize + received,
                    totalBytes: total
                ))
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    downloader.start(request: URLRequest(url: remote), resumeData: nil) { result in
                        switch result {
                        case .success: continuation.resume()
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                downloader.cancelSavingResumeData()
            }
            projectorBytes = try verifiedSize(
                of: local,
                announced: projectorAnnounced.bytes,
                catalogued: model.projectorSizeBytes,
                model: model
            )
        }

        // The file exists now, so the memory estimate stops being a guess. Read
        // once, here: the header never changes, and every fit badge and refusal
        // from this point on is computed from the model's real shape rather
        // than from a flat percentage of its file size.
        var installed = model.readingDimensions(fromFileAt: destination)
        // And the sizes stop being a guess too. Verification has just measured
        // both files, so keeping the catalogue's numbers in the manifest would
        // leave every later estimate — and `largestSuccessfulLoad`, which is
        // supposed to be a proof — resting on the same hand-typed figure that
        // was once out by 1.3 GB.
        installed.sizeBytes = weightsBytes
        installed.projectorSizeBytes = projectorBytes
        manifest[model.id] = installed
        persist()
        let total = weightsBytes + projectorBytes
        onProgress(DownloadProgress(modelID: id, receivedBytes: total, totalBytes: total))
    }

    /// The file's real size, or a thrown error and no file at all.
    ///
    /// Deliberately not a hash. PocketPal's comment on the same check
    /// (`src/utils/index.ts`) is that hashing is unreliable and expensive, and
    /// on a phone that is the whole story: SHA-256 over a 4 GB GGUF is tens of
    /// seconds of wall clock and battery at the exact moment the user is
    /// waiting to use the thing, to catch a class of corruption — silently
    /// flipped bytes in an otherwise complete transfer — that TLS and TCP
    /// checksums have already made vanishingly rare. Truncation is the failure
    /// that actually happens, and truncation is visible in the length.
    ///
    /// The 0.1% band is PocketPal's number and it is sized for the fallback
    /// path: a hand-written catalogue figure is off by rounding, not by a
    /// chunk. On a 4 GB model that is 4 MB of slack, orders of magnitude below
    /// any dropped-connection truncation and orders above any rounding.
    ///
    /// The comparison is two-sided. A file that is too *long* is a resume that
    /// went wrong — a server that ignored the Range header and sent the whole
    /// body to be appended to bytes already on disk — and the result is exactly
    /// as unloadable as a short one.
    private func verifiedSize(
        of file: URL,
        announced: Int64?,
        catalogued: Int64,
        model: ModelRecord
    ) throws -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let actual = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        // No reference at all: a server that announced nothing, for a record
        // whose size the catalogue leaves at zero — which is most projectors
        // and every model added at runtime through `/api/models/add`. There is
        // nothing to compare against, and inventing a comparison would refuse
        // downloads that are fine.
        let expected = announced ?? catalogued
        guard expected > 0 else { return actual }

        let drift = abs(Double(actual - expected)) / Double(expected)
        guard drift > Self.sizeTolerance else { return actual }

        // Nothing half-installed survives. The bad file goes, and so does the
        // resume blob beside it: `FileDownloader` already calls a blob that
        // produced a failed transfer poison, because it is replayed on every
        // subsequent attempt and would make the model permanently unreachable.
        // Both files go even when only one was wrong — a weights file the
        // manifest does not list is a multi-gigabyte leak that `delete` can
        // never be called on.
        discardFiles(for: model)
        throw ModelStoreError.incompleteDownload(
            model: model.displayName,
            expected: expected,
            actual: actual
        )
    }

    /// The proportional difference between what was promised and what arrived
    /// that still counts as the same file.
    static let sizeTolerance = 0.001

    /// Removes every byte this model owns, leaving the manifest alone.
    private func discardFiles(for model: ModelRecord) {
        try? FileManager.default.removeItem(at: fileURL(for: model))
        try? FileManager.default.removeItem(at: resumeDataURL(for: model))
        if let projector = projectorURL(for: model) {
            try? FileManager.default.removeItem(at: projector)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(model.id).mmproj.resume"))
        }
    }

    private func run(
        _ downloader: FileDownloader,
        for model: ModelRecord,
        resumeData: Data?
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                downloader.start(request: URLRequest(url: model.downloadURL), resumeData: resumeData) { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            downloader.cancelSavingResumeData()
        }
    }

    private func checkDiskSpace(for model: ModelRecord) throws {
        // A nil capacity is a failed query, not a full disk; a zero capacity is
        // a full disk. Conflating them lets a download start on a full device
        // and die mid-transfer with an opaque CFNetwork error.
        //
        // `forImportantUsage` is the only key worth asking on iOS — plain
        // `volumeAvailableCapacity` reports what is unused right now and
        // ignores the gigabytes of purgeable caches the system will evict when
        // something important needs them, so it under-reports and refuses
        // downloads that would have succeeded.
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else { return }
        let free = Int64(capacity)
        // Weights *and* projector. A vision model downloads two files, and a
        // check that counted only the first passed happily and then ran out of
        // disk partway through the second — after the multi-gigabyte one had
        // already been paid for.
        let needed = model.totalDownloadBytes + Self.diskReserveBytes
        guard free > needed else {
            throw ModelStoreError.insufficientDisk(needed: needed, free: free)
        }
    }

    /// Room left over after the weights land.
    ///
    /// Two reasons it cannot be zero. The number above is the optimistic one by
    /// construction — it counts purgeable space as available, so it is not free
    /// bytes but free-bytes-if-the-system-cooperates, and it can overstate by
    /// more than a rounding error. And a device driven to actually zero free
    /// bytes is its own failure: iOS starts evicting aggressively, writes begin
    /// failing, and the app is a candidate for termination — a download that
    /// technically fits and leaves the phone unusable has not succeeded.
    ///
    /// 512 MB covers the resume blob, the manifest rewrite and the slack the
    /// system wants, and is small next to the models it gates.
    static let diskReserveBytes: Int64 = 512 * 1024 * 1024

    /// Where URLSession's resume data is parked between attempts. This is not a
    /// partial file: it is the opaque blob carrying the validators that let the
    /// server prove the bytes already on disk are still the right ones.
    private func resumeDataURL(for model: ModelRecord) -> URL {
        directory.appendingPathComponent("\(model.id).resume")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}
