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
    /// The multimodal projector to pair with these weights, if the model can
    /// see. Downloaded alongside the model and passed to llama.cpp as
    /// mmprojURL; without it a vision model is a text model.
    public var projectorFilename: String?
    /// Size of the projector, counted into the memory budget because it is
    /// resident for as long as the model is.
    public var projectorSizeBytes: Int64
    /// Whether this model's chat template was trained to emit tool calls.
    ///
    /// Tri-state, and `.unknown` is the honest default: a model nobody has
    /// checked is not the same as one known not to work, and treating it as
    /// capable is how someone ends up with a feature that silently never fires.
    /// Unknown is treated as unusable at the gate, but says so differently.
    public var toolSupport: ModelCapabilities.Support

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
        sourceURL: URL? = nil,
        projectorFilename: String? = nil,
        projectorSizeBytes: Int64 = 0,
        toolSupport: ModelCapabilities.Support = .unknown
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
        self.projectorFilename = projectorFilename
        self.projectorSizeBytes = projectorSizeBytes
        self.toolSupport = toolSupport
    }

    /// Decoded leniently so a manifest written by an older build still loads.
    /// The synthesised initialiser requires every non-optional key, so adding
    /// one field silently emptied everyone's installed-model list — the files
    /// were still on disk and the app reported nothing installed.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        repoID = try c.decode(String.self, forKey: .repoID)
        filename = try c.decode(String.self, forKey: .filename)
        parameters = try c.decode(String.self, forKey: .parameters)
        quantization = try c.decode(String.self, forKey: .quantization)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        contextLength = try c.decode(Int.self, forKey: .contextLength)
        license = try c.decode(String.self, forKey: .license)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        projectorFilename = try c.decodeIfPresent(String.self, forKey: .projectorFilename)
        projectorSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .projectorSizeBytes) ?? 0
        toolSupport = try c.decodeIfPresent(ModelCapabilities.Support.self, forKey: .toolSupport) ?? .unknown
    }

    public var downloadURL: URL {
        sourceURL ?? URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(filename)?download=true")!
    }

    /// Where the projector lives. Same repository, by convention.
    public var projectorURL: URL? {
        guard let projectorFilename else { return nil }
        return URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(projectorFilename)?download=true")
    }

    /// Weights plus projector. The projector is a few hundred megabytes and is
    /// resident whenever the model is, so a fit estimate that ignores it is
    /// wrong by exactly the amount that gets someone jetsammed.
    public var totalDownloadBytes: Int64 { sizeBytes + projectorSizeBytes }

    /// Weights plus a working allowance for the KV cache and the runtime. The
    /// 1.25 multiplier is empirical, not a promise — it is what keeps a 2B Q4
    /// model from being reported as "fits" on a device where it will be jetsammed
    /// two thousand tokens into the first conversation.
    public var estimatedResidentBytes: Int64 {
        Int64(Double(sizeBytes + projectorSizeBytes) * 1.25) + 192 * 1024 * 1024
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
