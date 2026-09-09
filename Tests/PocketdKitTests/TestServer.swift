import Foundation
import Testing
@testable import PocketdKit

/// Boots a real server on a kernel-assigned port and talks to it over real HTTP.
///
/// The alternative — calling route handlers directly — would pass while the
/// SSE framing, the status codes and the header names were all wrong, which is
/// exactly the layer this project has to get right for third-party clients.
struct TestServer {
    let server: InferenceServer
    let baseURL: URL
    let apiKey: String

    static func start(
        configuration: ServerConfiguration = ServerConfiguration(port: 0, binding: .loopback),
        engine: any InferenceEngine = EchoEngine(),
        models: [ModelRecord] = [.echo]
    ) async throws -> TestServer {
        let server = InferenceServer(
            configuration: configuration,
            engine: engine,
            models: { models }
        )
        try await server.start()
        guard case let .running(_, port) = await server.currentState() else {
            throw TestFailure.serverDidNotStart
        }
        return TestServer(
            server: server,
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            apiKey: configuration.apiKey
        )
    }

    func stop() async { await server.stop() }

    func request(
        _ method: String,
        _ path: String,
        json: (any Encodable)? = nil,
        key: String?? = .none
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        // `.none` means "use the server's real key"; `.some(nil)` means send none.
        let resolved: String? = key ?? apiKey
        if let resolved {
            request.setValue("Bearer \(resolved)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(json))
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Collects a streamed body as a list of text lines, which is the shape both
    /// SSE and NDJSON assertions want.
    func lines(_ request: URLRequest) async throws -> [String] {
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var out: [String] = []
        for try await line in bytes.lines { out.append(line) }
        return out
    }
}

enum TestFailure: Error {
    case serverDidNotStart
}

struct AnyEncodable: Encodable {
    let wrapped: any Encodable
    init(_ wrapped: any Encodable) { self.wrapped = wrapped }
    func encode(to encoder: any Encoder) throws { try wrapped.encode(to: encoder) }
}
