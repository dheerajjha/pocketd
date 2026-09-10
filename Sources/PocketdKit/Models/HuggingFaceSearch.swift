import Foundation

/// Finds GGUF models on Hugging Face.
///
/// The curated catalogue is eight models that are known to load on a phone. It
/// is the right default and the wrong ceiling: PocketPal ships four curated
/// models and a `+` that reaches all of Hugging Face, and that `+` is the whole
/// difference between "some models" and "any model".
///
/// Two things this deliberately does that a naive search would not. It reads
/// the real byte size of every file from the tree API rather than guessing from
/// the parameter count — the Gemma 4 entry in our own catalogue was wrong by
/// 1.3 GB that way, and the memory fit badge is computed from that number. And
/// it surfaces `gated`, because a gated repository answers 401 to a download
/// this app has no token flow to satisfy, so it must be visible before someone
/// taps rather than after.
public struct HuggingFaceSearch: Sendable {
    public struct Repository: Sendable, Equatable, Identifiable, Codable {
        public let id: String
        public let downloads: Int
        public let likes: Int
        /// HF returns `false`, `"auto"` or `"manual"`. Anything but false needs
        /// a token, which pocketd cannot supply.
        public let gated: Bool

        public var owner: String { id.split(separator: "/").first.map(String.init) ?? id }
        public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    }

    public struct File: Sendable, Equatable, Identifiable, Codable {
        public let path: String
        public let sizeBytes: Int64

        public var id: String { path }

        /// `Qwen3-1.7B-Q4_K_M.gguf` -> `Q4_K_M`. Best effort: the convention is
        /// the only thing there is, since GGUF quantisation is not in the API.
        public var quantization: String {
            let stem = path.replacingOccurrences(of: ".gguf", with: "")
            let parts = stem.split(separator: "-")
            for part in parts.reversed() where part.first == "Q" || part.hasPrefix("IQ") || part == "BF16" || part == "F16" {
                return String(part)
            }
            return "unknown"
        }

        public var isProjector: Bool { ModelRecord.isProjector(filename: path) }
    }

    private let session: URLSession
    private let host: URL

    public init(session: URLSession = .shared, host: URL = URL(string: "https://huggingface.co")!) {
        self.session = session
        self.host = host
    }

    public enum SearchError: Error, Sendable, Equatable {
        case httpStatus(Int)
        case malformed
    }

    /// Repositories matching `query` that publish GGUF files, most-downloaded
    /// first — popularity is the only quality signal available, and on a phone
    /// an obscure broken quantisation costs gigabytes to discover.
    public func repositories(matching query: String, limit: Int = 20) async throws -> [Repository] {
        var components = URLComponents(url: host.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "search", value: query),
            .init(name: "filter", value: "gguf"),
            .init(name: "sort", value: "downloads"),
            .init(name: "direction", value: "-1"),
            .init(name: "limit", value: String(limit)),
        ]
        let (data, response) = try await session.data(from: components.url!)
        try Self.check(response)

        struct Row: Decodable {
            let id: String
            let downloads: Int?
            let likes: Int?
            let gated: GatedFlag?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw SearchError.malformed
        }
        return rows.map {
            Repository(id: $0.id, downloads: $0.downloads ?? 0, likes: $0.likes ?? 0, gated: $0.gated?.isGated ?? false)
        }
    }

    /// The GGUF files in a repository, with their real sizes.
    public func files(in repository: String) async throws -> [File] {
        let url = host.appendingPathComponent("api/models/\(repository)/tree/main")
        let (data, response) = try await session.data(from: url)
        try Self.check(response)

        struct Row: Decodable {
            let path: String
            let size: Int64?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw SearchError.malformed
        }
        return rows
            .filter { $0.path.hasSuffix(".gguf") }
            .map { File(path: $0.path, sizeBytes: $0.size ?? 0) }
            .sorted { $0.sizeBytes < $1.sizeBytes }
    }

    /// Turns a chosen repository and file into a catalogue entry.
    ///
    /// The projector is paired automatically when the repository has one: a
    /// vision model downloaded without it loads and then cannot see, which is
    /// the confusing failure rather than the obvious one.
    public static func record(
        repository: String,
        file: File,
        projector: File? = nil,
        contextLength: Int = 4096
    ) -> ModelRecord {
        ModelRecord(
            id: Self.identifier(repository: repository, filename: file.path),
            displayName: file.path.replacingOccurrences(of: ".gguf", with: ""),
            repoID: repository,
            filename: file.path,
            parameters: "—",
            quantization: file.quantization,
            sizeBytes: file.sizeBytes,
            contextLength: contextLength,
            license: "See the model card on Hugging Face",
            projectorFilename: projector?.path,
            projectorSizeBytes: projector?.sizeBytes ?? 0,
            // Unknown rather than no: nobody has checked this template, and
            // claiming either way would be a guess.
            toolSupport: .unknown
        )
    }

    /// A stable id from the repository and file, lowercased and URL-safe so it
    /// can be a filename and a model name on the wire.
    public static func identifier(repository: String, filename: String) -> String {
        let stem = filename.replacingOccurrences(of: ".gguf", with: "")
        let owner = repository.split(separator: "/").first.map(String.init) ?? ""
        let combined = "\(owner)-\(stem)".lowercased()
        return String(combined.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw SearchError.httpStatus(http.statusCode)
        }
    }

    /// HF sends `false`, `"auto"` or `"manual"` in the same field.
    private struct GatedFlag: Decodable {
        let isGated: Bool

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                isGated = flag
            } else if let text = try? container.decode(String.self) {
                isGated = text != "false"
            } else {
                isGated = false
            }
        }
    }
}
