import Foundation
import FlyingFox
import FlyingSocks

/// The HTTP server that turns the phone into an inference endpoint.
///
/// Lifecycle is deliberately explicit rather than automatic. iOS closes a
/// listening socket when it suspends the app, so "running" is a state the app
/// has to re-establish on every foreground transition — a server that silently
/// believed it was still up would report a URL that refuses connections.
public actor InferenceServer {
    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case running(host: String, port: UInt16)
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    public private(set) var configuration: ServerConfiguration
    public let log: RequestLog

    private let engine: any InferenceEngine
    private let modelsProvider: @Sendable () async -> [ModelRecord]

    private var server: HTTPServer?
    private var runTask: Task<Void, Never>?
    private var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            for continuation in stateObservers.values { continuation.yield(state) }
        }
    }
    private var stateObservers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var activeRequests = 0

    public init(
        configuration: ServerConfiguration = ServerConfiguration(),
        engine: any InferenceEngine,
        models: @escaping @Sendable () async -> [ModelRecord],
        log: RequestLog = RequestLog()
    ) {
        self.configuration = configuration
        self.engine = engine
        self.modelsProvider = models
        self.log = log
    }

    public func currentState() -> State { state }

    public func stateStream() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream { continuation in
            stateObservers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateObserver(id) }
            }
        }
    }

    private func removeStateObserver(_ id: UUID) { stateObservers[id] = nil }

    /// Applies a new configuration, restarting the listener if the change
    /// affects the socket. Changing the API key while running takes effect on
    /// the next request without a restart, which matters because rotating a
    /// leaked key should not drop in-flight work.
    public func apply(_ new: ServerConfiguration) async throws {
        let needsRestart = new.port != configuration.port || new.binding != configuration.binding
        configuration = new
        if needsRestart, state.isRunning {
            await stop()
            try await start()
        }
    }

    public func start() async throws {
        guard !state.isRunning else { return }
        state = .starting

        let server: HTTPServer
        switch configuration.binding {
        case .loopback:
            server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: configuration.port))
        case .localNetwork:
            server = HTTPServer(address: sockaddr_in.inet(port: configuration.port))
        }
        await installRoutes(on: server)
        self.server = server

        runTask = Task { try? await server.run() }
        do {
            try await server.waitUntilListening(timeout: 5)
        } catch {
            // Almost always EADDRINUSE from a previous run whose socket has not
            // been reclaimed yet. Surfacing the raw error here is what lets the
            // UI say "port 11434 is busy" instead of "something went wrong".
            state = .failed(String(describing: error))
            runTask?.cancel()
            runTask = nil
            self.server = nil
            throw error
        }

        let host = configuration.binding == .loopback
            ? "127.0.0.1"
            : (NetworkInterface.localIPv4Address() ?? "0.0.0.0")
        // Read the port back rather than trusting the configuration: port 0 asks
        // the kernel to pick one, and the UI has to display the number a client
        // should actually dial.
        state = .running(host: host, port: await server.resolvedPort() ?? configuration.port)
    }

    public func stop() async {
        await server?.stop(timeout: 1)
        runTask?.cancel()
        runTask = nil
        server = nil
        activeRequests = 0
        state = .stopped
    }

    // MARK: - Shared request plumbing

    func models() async -> [ModelRecord] { await modelsProvider() }

    func currentEngine() -> any InferenceEngine { engine }

    /// Returns nil when the request may proceed, or the rejection to send back.
    func authorize(_ request: HTTPRequest) -> HTTPResponse? {
        guard configuration.requiresAuth else { return nil }
        let presented = request.headers[.authorization]?
            .replacingOccurrences(of: "Bearer ", with: "")
            ?? request.headers[HTTPHeader("X-API-Key")]
        guard let presented, constantTimeEquals(presented, configuration.apiKey) else {
            return errorResponse(
                status: .unauthorized,
                message: "Missing or invalid API key.",
                type: "invalid_request_error",
                style: request.path.hasPrefix("/api") ? .ollama : .openAI
            )
        }
        return nil
    }

    /// Compares without an early return so that a wrong key takes the same time
    /// to reject regardless of how much of the prefix was correct.
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// Admission control. One GPU, one generation: a second concurrent request
    /// does not run twice as fast, it makes both slower and heats the device.
    func beginRequest() -> Bool {
        guard activeRequests < configuration.maxConcurrentRequests else { return false }
        activeRequests += 1
        return true
    }

    func endRequest() {
        activeRequests = max(0, activeRequests - 1)
    }

    func corsHeaders() -> HTTPHeaders {
        guard configuration.allowCORS else { return [:] }
        return [
            HTTPHeader("Access-Control-Allow-Origin"): "*",
            HTTPHeader("Access-Control-Allow-Headers"): "Authorization, Content-Type, X-API-Key",
            HTTPHeader("Access-Control-Allow-Methods"): "GET, POST, OPTIONS"
        ]
    }

    func contextCap() -> Int { configuration.maxContextTokens }
}
