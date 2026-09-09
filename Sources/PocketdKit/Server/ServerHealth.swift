import Foundation

/// Why the server is declining work, when it is.
///
/// A phone has physical limits a desktop does not, and the honest thing is to
/// tell a client which one was hit rather than failing opaquely or — worse —
/// generating anyway until the device throttles itself to a crawl and the
/// battery is flat.
public enum ServeCondition: String, Sendable, Codable, Equatable {
    case ok
    /// The device is hot. Generating now makes everything slower and cooks the
    /// phone; llama.cpp will be throttled by the SoC regardless.
    case thermal
    /// The battery is below the floor the user set. A server that flattens the
    /// phone it runs on has failed at being a phone.
    case battery

    public var isServing: Bool { self == .ok }

    /// What a client is told. Written for someone reading a 503 in a terminal.
    public var message: String {
        switch self {
        case .ok: "Serving."
        case .thermal: "The phone is too hot to generate right now. It will resume when it cools."
        case .battery: "The phone's battery is below the level set for serving. Charge it, or lower the floor in Settings."
        }
    }

    /// Seconds to suggest before retrying. Thermal recovery is quicker than a
    /// charge, so the numbers differ rather than being one guess.
    public var retryAfter: Int {
        switch self {
        case .ok: 0
        case .thermal: 60
        case .battery: 300
        }
    }
}

public extension ServeCondition {
    /// Whether the device should be serving, given what the sensors say.
    ///
    /// Pure and in the package rather than the app so the hysteresis is
    /// testable — the alternative is a rule about thermal recovery that can
    /// only be exercised by physically heating a phone.
    ///
    /// Recovery is deliberately harder than tripping. Coming back the moment a
    /// reading crosses the line makes a device hovering at the boundary flap
    /// between serving and refusing every few seconds, which is worse for a
    /// client than staying down until it genuinely recovers.
    static func evaluate(
        thermalIsSevere: Bool,
        thermalIsElevated: Bool,
        batteryLevel: Double,
        charging: Bool,
        floor: Double,
        current: ServeCondition
    ) -> ServeCondition {
        if thermalIsSevere { return .thermal }
        // Once hot, "fair" is not yet cool enough to resume.
        if current == .thermal, thermalIsElevated { return .thermal }

        // A charging phone is not going flat, so the floor does not apply.
        if !charging, batteryLevel >= 0 {
            if current == .battery {
                return batteryLevel >= floor + 0.05 ? .ok : .battery
            }
            if batteryLevel < floor { return .battery }
        }
        return .ok
    }
}
