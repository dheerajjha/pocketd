import Foundation
import FlyingFox

extension InferenceServer {
    struct PullRequest: Codable, Sendable {
        var model: String?
        var name: String?
        var stream: Bool?

        var resolved: String { model ?? name ?? "" }
    }

    /// Ollama's pull progress shape, so `ollama pull`-shaped clients and the
    /// setup page can both render a bar without special-casing us.
    struct PullProgress: Codable, Sendable {
        var status: String
        var digest: String?
        var total: Int64?
        var completed: Int64?
    }

    /// `POST /api/pull` — fetch a catalogue model onto the phone.
    ///
    /// Ollama has this and we did not, which meant the only way to put a model
    /// on the device was to tap through the phone's own UI. That is a poor fit
    /// for the thing this app is: the phone is the server, and a server you
    /// have to walk over to and touch is a worse server.
    func handlePull(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }

        guard let payload = try? JSONDecoder().decode(PullRequest.self, from: await request.bodyData),
              !payload.resolved.isEmpty
        else {
            return errorResponse(status: .badRequest, message: "Send {\"model\":\"<id>\"}.", style: .ollama, headers: cors)
        }
        guard let record = ModelCatalog.model(withID: payload.resolved) else {
            return errorResponse(
                status: .notFound,
                message: "'\(payload.resolved)' is not in the catalogue. GET /api/catalogue lists what can be pulled.",
                style: .ollama,
                headers: cors
            )
        }
        guard let pull = puller else {
            return errorResponse(
                status: HTTPStatusCode(501, phrase: "Not Implemented"),
                message: "This server was built without model downloading.",
                style: .ollama,
                headers: cors
            )
        }

        var headers = cors
        headers[.contentType] = "application/x-ndjson"
        headers[.cacheControl] = "no-cache"

        return HTTPResponse.streaming(headers: headers) { continuation in
            Task {
                let encoder = JSONEncoder()
                func emit(_ value: PullProgress) {
                    guard var data = try? encoder.encode(value) else { return }
                    data.append(0x0A)
                    continuation.yield(data)
                }

                emit(PullProgress(status: "pulling manifest"))
                do {
                    for try await progress in pull(record) {
                        emit(PullProgress(
                            status: "downloading",
                            digest: record.id,
                            total: progress.totalBytes,
                            completed: progress.receivedBytes
                        ))
                    }
                    emit(PullProgress(status: "success"))
                } catch {
                    emit(PullProgress(status: "error: \(error)"))
                }
                continuation.finish()
            }
        }
    }

    /// Everything that could be pulled, which `/v1/models` deliberately does not
    /// list — that endpoint answers "what can I use right now".
    func handleCatalogue(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }

        struct Entry: Encodable {
            var id: String
            var name: String
            var parameters: String
            var quantization: String
            var sizeBytes: Int64
            var contextLength: Int
            var license: String
            var capabilities: [String]
            var installed: Bool
        }
        let installed = Set(await models().map(\.id))
        return jsonResponse(
            ModelCatalog.all.map {
                Entry(
                    id: $0.id,
                    name: $0.displayName,
                    parameters: $0.parameters,
                    quantization: $0.quantization,
                    sizeBytes: $0.totalDownloadBytes,
                    contextLength: $0.contextLength,
                    license: $0.license,
                    capabilities: $0.declaredCapabilities.ollamaCapabilities,
                    installed: installed.contains($0.id)
                )
            },
            headers: cors
        )
    }
}
