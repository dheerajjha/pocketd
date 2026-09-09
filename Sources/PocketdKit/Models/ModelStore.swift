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

    public func localURL(forID id: String) -> URL? {
        manifest[id].map { fileURL(for: $0) }
    }

    public func delete(_ model: ModelRecord) throws {
        try? FileManager.default.removeItem(at: fileURL(for: model))
        try? FileManager.default.removeItem(at: partialURL(for: model))
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
        onProgress: @Sendable (DownloadProgress) -> Void
    ) async throws {
        guard allowingOversized || budget.fit(for: model).allowsDownload else {
            throw ModelStoreError.insufficientMemory(model: model.id)
        }
        try checkDiskSpace(for: model)

        let partial = partialURL(for: model)
        var received = fileSize(at: partial)

        var request = URLRequest(url: model.downloadURL)
        if received > 0 {
            request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelStoreError.httpStatus(0)
        }
        // 206 means the server honoured our Range and we append; 200 means it
        // ignored it and is sending the whole file, so the partial is stale.
        switch http.statusCode {
        case 206:
            break
        case 200:
            received = 0
            try? FileManager.default.removeItem(at: partial)
        default:
            throw ModelStoreError.httpStatus(http.statusCode)
        }

        let total = received + max(http.expectedContentLength, 0)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReported = received

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Report at most once per megabyte; a per-byte callback would
                // spend more time updating SwiftUI than writing the file.
                if received - lastReported >= 1 << 20 {
                    onProgress(DownloadProgress(modelID: model.id, receivedBytes: received, totalBytes: total))
                    lastReported = received
                }
            }
            try Task.checkCancellation()
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()

        try? FileManager.default.removeItem(at: fileURL(for: model))
        try FileManager.default.moveItem(at: partial, to: fileURL(for: model))
        manifest[model.id] = model
        persist()
        onProgress(DownloadProgress(modelID: model.id, receivedBytes: received, totalBytes: max(total, received)))
    }

    private func checkDiskSpace(for model: ModelRecord) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        guard free == 0 || free > model.sizeBytes else {
            throw ModelStoreError.insufficientDisk(needed: model.sizeBytes, free: free)
        }
    }

    private func partialURL(for model: ModelRecord) -> URL {
        directory.appendingPathComponent("\(model.id).gguf.partial")
    }

    private func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}
