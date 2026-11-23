import Foundation

/// A live reading for Apple's server model. Device readiness and a person's daily
/// quota are separate: reaching the limit doesn't make the device unsupported.
public enum AppleCloudStatus: Sendable, Equatable {
    case unavailable
    case notReady
    case available
    case approachingLimit
    case limitReached(reset: Date?)

    public static let title = "Apple Private Cloud Compute"
    public static let detail = "Apple processes your questions, relevant chat history, and connected day information on its private servers. Requires internet; daily limits apply."

    /// Never offer a server choice based on last launch's reading or a device name.
    public var isListed: Bool {
        switch self {
        case .available, .approachingLimit, .limitReached: true
        case .unavailable, .notReady: false
        }
    }

    public var canChoose: Bool {
        switch self {
        case .available, .approachingLimit: true
        case .unavailable, .notReady, .limitReached: false
        }
    }

    public var statusLine: String {
        switch self {
        case .unavailable: "Apple Private Cloud Compute isn't available on this device."
        case .notReady: "Apple Private Cloud Compute isn't ready. Try again later or choose a local brain."
        case .available: "Ready · Internet required"
        case .approachingLimit: "Approaching your daily Apple cloud limit."
        case .limitReached(let reset):
            if let reset {
                "Daily Apple cloud limit reached. Resets \(reset.formatted(date: .abbreviated, time: .shortened))."
            } else {
                "Daily Apple cloud limit reached. Try again later or choose a local brain."
            }
        }
    }
}

public extension ModelRecord {
    /// Distinct from the on-device Apple model and from every downloadable id.
    static let privateCloudComputeID = "system:apple-private-cloud-compute"
    static let privateCloudCompute = ModelRecord(
        id: privateCloudComputeID, displayName: AppleCloudStatus.title, repoID: "", filename: "",
        parameters: "", quantization: "", sizeBytes: 0, contextLength: 32_768, license: "Apple", toolSupport: .yes
    )
}
