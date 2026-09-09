import Foundation

/// A model the server can serve. `id` is the string clients send as `"model"`,
/// so it is deliberately short, lowercase and stable across reinstalls.
public struct ModelRecord: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    /// Hugging Face repository, e.g. `"google/gemma-4-E2B-it-GGUF"`.
    public var repoID: String
    /// File within the repository, e.g. `"gemma-4-E2B-it-Q4_K_M.gguf"`.
    public var filename: String
    public var parameters: String
    public var quantization: String
    /// On-disk size. Used for the download UI and, more importantly, to refuse
    /// a download that cannot fit in this device's memory budget.
    public var sizeBytes: Int64
    /// Maximum context the weights support. The *served* context is capped
    /// separately, because KV cache is what actually exhausts a phone.
    public var contextLength: Int
    public var license: String
    /// Overrides the Hugging Face location. Set for weights served from a
    /// mirror or a machine on the same network, and by the test suite.
    public var sourceURL: URL?

    public init(
        id: String,
        displayName: String,
        repoID: String,
        filename: String,
        parameters: String,
        quantization: String,
        sizeBytes: Int64,
        contextLength: Int,
        license: String,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.repoID = repoID
        self.filename = filename
        self.parameters = parameters
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.contextLength = contextLength
        self.license = license
        self.sourceURL = sourceURL
    }

    public var downloadURL: URL {
        sourceURL ?? URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(filename)?download=true")!
    }

    /// Weights plus a working allowance for the KV cache and the runtime. The
    /// 1.25 multiplier is empirical, not a promise — it is what keeps a 2B Q4
    /// model from being reported as "fits" on a device where it will be jetsammed
    /// two thousand tokens into the first conversation.
    public var estimatedResidentBytes: Int64 {
        Int64(Double(sizeBytes) * 1.25) + 192 * 1024 * 1024
    }

    public static let echo = ModelRecord(
        id: "echo",
        displayName: "Echo (test)",
        repoID: "pocketd/echo",
        filename: "echo.gguf",
        parameters: "0B",
        quantization: "none",
        sizeBytes: 0,
        contextLength: 8192,
        license: "MIT"
    )
}
