import Foundation

/// How much memory this process may actually use before the kernel kills it.
///
/// iOS does not publish this number. What it publishes is total physical RAM,
/// which is roughly double what a single app is allowed to touch, and reporting
/// that to a user is how a "fits comfortably" badge turns into a jetsam crash.
/// The fractions below are conservative on purpose.
public struct DeviceBudget: Sendable, Equatable {
    public var physicalMemoryBytes: Int64
    /// True when the app ships `com.apple.developer.kernel.increased-memory-limit`.
    public var hasIncreasedMemoryLimit: Bool

    public init(physicalMemoryBytes: Int64, hasIncreasedMemoryLimit: Bool) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.hasIncreasedMemoryLimit = hasIncreasedMemoryLimit
    }

    public static func current(hasIncreasedMemoryLimit: Bool) -> DeviceBudget {
        DeviceBudget(
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            hasIncreasedMemoryLimit: hasIncreasedMemoryLimit
        )
    }

    /// Bytes this app can reasonably hold resident.
    public var usableBytes: Int64 {
        let fraction = hasIncreasedMemoryLimit ? 0.58 : 0.45
        return Int64(Double(physicalMemoryBytes) * fraction)
    }

    public enum Fit: Sendable, Equatable {
        case comfortable
        /// Loads, but leaves little room for context. Expect trouble on long chats.
        case tight
        /// Will be killed by the kernel. Downloading it is wasted bandwidth.
        case willNotFit

        public var allowsDownload: Bool { self != .willNotFit }
    }

    public func fit(for model: ModelRecord) -> Fit {
        let needed = model.estimatedResidentBytes
        if needed <= Int64(Double(usableBytes) * 0.7) { return .comfortable }
        if needed <= usableBytes { return .tight }
        return .willNotFit
    }
}
