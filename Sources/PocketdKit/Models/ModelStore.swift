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

/// Owns the model files on disk and the manifest that describes them.
///
/// Downloads resume. This is not a nicety: the files are gigabytes, the device
/// is a phone on a cellular-or-wifi boundary, and iOS will suspend the app the
/// moment the user switches away. A download that restarts from zero every time
/// the screen locks never finishes.
public actor ModelStore {
    private let directory: URL
    private let session: URLSession
    private let budget: DeviceBudget
    private var manifest: [String: ModelRecord] = [:]

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

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

        manifest[model.id] = model
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
