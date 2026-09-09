import Foundation
import FlyingFox

extension InferenceServer {
    /// `GET /` has to serve two audiences. Ollama clients probe it and refuse to
    /// proceed unless it answers with the exact string `Ollama is running`;
    /// a person opening the address in a browser wants the setup page. Browsers
    /// always send `Accept: text/html` and Ollama clients never do, so the
    /// header decides and neither contract is broken.
    func handleRoot(_ request: HTTPRequest) async -> HTTPResponse {
        let accept = request.headers[HTTPHeader("Accept")] ?? ""
        guard accept.contains("text/html") else {
            return HTTPResponse(
                statusCode: .ok,
                headers: corsHeaders(),
                body: Data("Ollama is running".utf8)
            )
        }
        // The chat page handles its own pairing, so it is the right landing
        // place whether or not this browser has connected before.
        return await handleChatPage()
    }

    /// The chat client. Served at /chat and, once a browser has paired, the
    /// thing the bare address should land on — someone opening their phone's
    /// address wants to talk to the model, not read setup instructions again.
    func handleChatPage() async -> HTTPResponse {
        var headers = corsHeaders()
        headers[.contentType] = "text/html; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return HTTPResponse(statusCode: .ok, headers: headers, body: Data(ChatPage.html.utf8))
    }

    func handleSetupPage() async -> HTTPResponse {
        var headers = corsHeaders()
        headers[.contentType] = "text/html; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return HTTPResponse(
            statusCode: .ok,
            headers: headers,
            body: Data(SetupPage.html(serverName: "Pocketd").utf8)
        )
    }

    struct PairRequest: Codable, Sendable {
        var code: String
    }

    struct PairedSnippet: Codable, Sendable {
        var id: String
        var title: String
        var language: String
        var body: String
        var filename: String?
        var note: String?
    }

    struct PairedResponse: Codable, Sendable {
        var baseURL: String
        var apiKey: String?
        var model: String?
        var snippets: [PairedSnippet]
    }

    struct PairFailure: Codable, Sendable {
        struct Body: Codable, Sendable {
            var message: String
            var type: String
        }
        var error: Body
        var attemptsRemaining: Int
    }

    /// The one route deliberately exempt from `authorize` — it *is* the
    /// handshake that hands over the key. Everything it can leak is guarded by
    /// the code's expiry and its five-attempt limit instead.
    func handlePair(_ request: HTTPRequest) async -> HTTPResponse {
        var headers = corsHeaders()
        headers[.contentType] = "application/json"

        guard let payload = try? JSONDecoder().decode(PairRequest.self, from: await request.bodyData) else {
            return jsonResponse(
                PairFailure(error: .init(message: "Send {\"code\":\"123456\"}.", type: "pairing_failed"), attemptsRemaining: 0),
                headers: headers
            )
        }

        switch await pairing.redeem(payload.code, from: request.peerAddress) {
        case .paired:
            let host = pairedHost()
            var model = await currentEngine().loadedModel()?.id
            if model == nil { model = await models().first?.id }
            let base = URL(string: "http://\(host):\(await resolvedPort())")!
            let snippets = ClientSnippets.all(
                baseURL: base,
                apiKey: configuration.requiresAuth ? configuration.apiKey : nil,
                model: model ?? "your-model"
            ).map {
                PairedSnippet(id: $0.id, title: $0.title, language: $0.language,
                              body: $0.body, filename: $0.filename, note: $0.note)
            }
            return jsonResponse(
                PairedResponse(
                    baseURL: base.absoluteString,
                    apiKey: configuration.requiresAuth ? configuration.apiKey : nil,
                    model: model,
                    snippets: snippets
                ),
                headers: headers
            )

        case .wrongCode(let remaining):
            return HTTPResponse(
                statusCode: HTTPStatusCode(403, phrase: "Forbidden"),
                headers: headers,
                body: (try? JSONEncoder().encode(PairFailure(
                    error: .init(message: "Wrong code.", type: "pairing_failed"),
                    attemptsRemaining: remaining
                ))) ?? Data()
            )

        case .expired:
            return HTTPResponse(
                statusCode: HTTPStatusCode(403, phrase: "Forbidden"),
                headers: headers,
                body: (try? JSONEncoder().encode(PairFailure(
                    error: .init(message: "That code has expired. Tap New code on the phone.", type: "pairing_expired"),
                    attemptsRemaining: 0
                ))) ?? Data()
            )
        }
    }

    private func pairedHost() -> String {
        if case let .running(host, _) = currentStateValue() { return host }
        return NetworkInterface.localIPv4Address() ?? "127.0.0.1"
    }
}
