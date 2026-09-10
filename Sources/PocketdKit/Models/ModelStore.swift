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
        try? FileManager.default.removeItem(at: fileURL(for: model))
        try? FileManager.default.removeItem(at: resumeDataURL(for: model))
        if let projector = projectorURL(for: model) {
            try? FileManager.default.removeItem(at: projector)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(model.id).mmproj.resume"))
        }
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

        let downloader = FileDownloader(
            destination: destination,
            resumeDataURL: resumeURL
        ) { received, expected in
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
                onProgress(DownloadProgress(
                    modelID: id,
                    receivedBytes: received,
                    totalBytes: expected > 0 ? expected + model.projectorSizeBytes : declaredSize + model.projectorSizeBytes
                ))
            }
            try await run(retry, for: model, resumeData: nil)
        }

        // The projector is useless on its own and the weights are useless
        // without it for a vision model, so the model is not marked installed
        // until both are on disk.
        if let remote = model.projectorURL, let local = projectorURL(for: model) {
            let projectorResume = directory.appendingPathComponent("\(model.id).mmproj.resume")
            let total = declaredSize + model.projectorSizeBytes
            let downloader = FileDownloader(destination: local, resumeDataURL: projectorResume) { received, _ in
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
        }

        // The file exists now, so the memory estimate stops being a guess. Read
        // once, here: the header never changes, and every fit badge and refusal
        // from this point on is computed from the model's real shape rather
        // than from a flat percentage of its file size.
        manifest[model.id] = model.readingDimensions(fromFileAt: fileURL(for: model))
        persist()
        let total = declaredSize + model.projectorSizeBytes
        onProgress(DownloadProgress(modelID: id, receivedBytes: total, totalBytes: total))
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
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else { return }
        let free = Int64(capacity)
        guard free > model.sizeBytes else {
            throw ModelStoreError.insufficientDisk(needed: model.sizeBytes, free: free)
        }
    }

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
