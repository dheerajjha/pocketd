import Foundation

public struct ServerConfiguration: Sendable, Equatable, Codable {
    public enum Binding: String, Sendable, Codable, CaseIterable, Identifiable {
        /// 127.0.0.1 — reachable only from apps on this phone.
        case loopback
        /// 0.0.0.0 — reachable from every device on the Wi-Fi network.
        case localNetwork

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .loopback: "This device only"
            case .localNetwork: "Local network"
            }
        }
    }

    /// Ollama's default port, chosen so that a client already pointed at a
    /// desktop Ollama needs only its host changed, not its port.
    public var port: UInt16
    public var binding: Binding
    /// Off is allowed but never the default. A model endpoint on an open port
    /// is a stranger's free GPU, and hotel Wi-Fi is not a trusted network.
    public var requiresAuth: Bool
    public var apiKey: String
    public var allowCORS: Bool
    /// A phone has one GPU and a thermal ceiling. Serving two generations at
    /// once makes both slower than serving them in turn.
    public var maxConcurrentRequests: Int
    /// Hard cap on prompt + completion, independent of what the weights claim
    /// to support. KV cache is the thing that actually exhausts the device.
    public var maxContextTokens: Int
    /// Keep the screen awake while listening. iOS suspends a backgrounded app
    /// and drops its listening socket, so a locked phone is an offline server.
    public var keepAwakeWhileServing: Bool
    /// Stop serving when the battery drops below this, so an overnight server
    /// does not leave the user with a dead phone.
    public var pauseBelowBatteryLevel: Double
    /// How long a connection may go quiet before the server drops it.
    ///
    /// FlyingFox defaults this to 15 seconds, which is right for a web server
    /// and catastrophic for an inference server: a non-streamed completion
    /// writes nothing until the last token, so on a phone at 5-25 tok/s every
    /// response longer than about 200 tokens is killed mid-generation and the
    /// client gets a 500 with an empty body. Streaming survived only because
    /// each token resets the clock. The default here is the wall-clock cost of
    /// a full context at a pessimistic three tokens a second.
    public var connectionTimeout: TimeInterval

    public init(
        port: UInt16 = 11434,
        binding: Binding = .localNetwork,
        requiresAuth: Bool = true,
        apiKey: String = ServerConfiguration.generateAPIKey(),
        allowCORS: Bool = true,
        maxConcurrentRequests: Int = 1,
        maxContextTokens: Int = 4096,
        keepAwakeWhileServing: Bool = true,
        pauseBelowBatteryLevel: Double = 0.15,
        connectionTimeout: TimeInterval? = nil
    ) {
        self.port = port
        self.binding = binding
        self.requiresAuth = requiresAuth
        self.apiKey = apiKey
        self.allowCORS = allowCORS
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxContextTokens = maxContextTokens
        self.keepAwakeWhileServing = keepAwakeWhileServing
        self.pauseBelowBatteryLevel = pauseBelowBatteryLevel
        self.connectionTimeout = connectionTimeout ?? Self.timeout(forContext: maxContextTokens)
    }

    /// The wall-clock cost of generating a full context at three tokens a
    /// second — slower than any phone this runs on, which is the point.
    public static func timeout(forContext tokens: Int) -> TimeInterval {
        max(120, Double(tokens) / 3.0)
    }

    public static func generateAPIKey() -> String {
        "pk-" + (0..<32).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }
                        .reduce(into: "") { $0.append($1) }
    }

    public func baseURL(host: String) -> URL {
        URL(string: "http://\(host):\(port)")!
    }
}
