import Foundation

/// What a model can do, on two independent axes.
///
/// The shape is taken from PocketPal's `resolveModelCaps`, which draws a
/// distinction worth stealing: what the model *declares* is a property of the
/// model and is meaningful for any entry in the catalogue, while what the
/// *loaded session* can do is meaningful only for the resident one. Collapsing
/// them makes a catalogue card borrow the active model's load state, which is
/// how a listing ends up claiming vision for something that was never paired
/// with a projector.
///
/// Tri-state rather than Bool for the same reason PocketPal uses it: for a
/// model nobody has inspected yet, "unknown" is the truth and "no" is a lie.
public struct ModelCapabilities: Sendable, Equatable, Codable {
    public enum Support: String, Sendable, Codable {
        case yes
        case no
        case unknown

        public var isYes: Bool { self == .yes }
    }

    /// Declared: this model can accept images, given a projector.
    public var vision: Support
    /// Live: the resident session was actually built with a projector, so
    /// images sent right now will be understood.
    public var visionActive: Bool
    /// Declared context window, from the catalogue.
    public var contextLength: Int?
    /// What the loaded context was actually allocated with, which is the
    /// smaller of the model's window and the server's cap.
    public var effectiveContextLength: Int?

    public init(
        vision: Support = .unknown,
        visionActive: Bool = false,
        contextLength: Int? = nil,
        effectiveContextLength: Int? = nil
    ) {
        self.vision = vision
        self.visionActive = visionActive
        self.contextLength = contextLength
        self.effectiveContextLength = effectiveContextLength
    }

    public static let unknown = ModelCapabilities()

    /// The Ollama `capabilities` array, which Open WebUI reads to decide which
    /// controls to show.
    ///
    /// This reports the DECLARED axis, not the live one, because the server
    /// loads a model on demand when a request names it: an image sent to a
    /// catalogued vision model will be served, after a load. Reporting only
    /// what is resident right now would hide the image button for every model
    /// except the one already in memory, which is the opposite of useful.
    /// `/health` reports the live axis, for callers that need to know whether
    /// the next request will be fast.
    public var ollamaCapabilities: [String] {
        var list = ["completion"]
        if vision.isYes { list.append("vision") }
        return list
    }
}

public extension ModelRecord {
    /// mmproj files are identified by filename, the same way PocketPal does it
    /// (`MMProjRegex` in its multimodalPatterns module). There is no metadata
    /// flag for this on Hugging Face; the convention is the interface.
    static func isProjector(filename: String) -> Bool {
        filename.range(of: #"[-_.]*mmproj[-_.].+\.gguf$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Declared capabilities. Vision is `yes` only when the catalogue names a
    /// projector to pair with — a vision-capable architecture with no reachable
    /// mmproj file cannot see anything, so claiming otherwise would be false.
    var declaredCapabilities: ModelCapabilities {
        ModelCapabilities(
            vision: projectorFilename == nil ? .no : .yes,
            visionActive: false,
            contextLength: contextLength
        )
    }
}
