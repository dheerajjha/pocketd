import CryptoKit
import Foundation

/// A durable fingerprint independent of whether the file is reachable today.
struct ModelFileIntegrity: Codable, Equatable, Sendable {
    var weightsSize: Int64
    var weightsSHA256: String
    var projectorSize: Int64?
    var projectorSHA256: String?

    static func read(model: ModelRecord, weights: URL, projector: URL?) throws -> Self {
        let weightsSize = try size(of: weights)
        guard matches(weightsSize, declared: model.sizeBytes) else { throw Unavailable() }
        var result = Self(weightsSize: weightsSize, weightsSHA256: try hash(weights))
        if model.projectorFilename != nil {
            guard let projector else { throw Unavailable() }
            let bytes = try size(of: projector)
            guard matches(bytes, declared: model.projectorSizeBytes) else { throw Unavailable() }
            result.projectorSize = bytes
            result.projectorSHA256 = try hash(projector)
        }
        return result
    }

    private static func matches(_ actual: Int64, declared: Int64) -> Bool {
        guard actual > 0 else { return false }
        // Older records may have rounded catalogue sizes. Once fingerprinted,
        // every subsequent comparison is exact, against the observed bytes.
        return declared <= 0 || abs(Double(actual) - Double(declared)) / Double(declared) <= ModelStore.sizeTolerance
    }

    private static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw Unavailable() }
        return size
    }

    private static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Unavailable: Error {}
}
