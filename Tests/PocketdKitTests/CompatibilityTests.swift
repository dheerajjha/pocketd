import Foundation
import Testing
@testable import PocketdKit

/// Assertions taken from the upstream sources rather than from memory: Ollama's
/// `api/types.go` and llama.cpp's `tools/server`. Each one exists because a real
/// client breaks without it.
@Suite("Client compatibility")
struct CompatibilityTests {

    @Test("the prompt a client sends is the prompt the model gets")
    func serverDoesNotRewriteTheClientsPrompt() async throws {
        // The Chat tab prepends `DateContext` to its own system turn, because a
        // model that does not know the date answers "what's on tomorrow" from
        // whenever its training data stopped. That injection stops at the socket,
        // and deliberately.
        //
        // Two reasons, both about what a client is promised. A seed is the
        // stronger one: the engine rebuilds its whole context whenever a request
        // pins randomness, precisely so that a seed means what the client thinks
        // it means — and a system message carrying a clock would make the same
        // seeded request answer differently at 14:31 than it did at 14:30, with
        // nothing in the response saying why. The second is plainer: this
        // endpoint claims to be a drop-in for Ollama and llama-server, and
        // neither edits the messages you send. A network client that wants the
        // date already knows it and can say so; the phone's own user cannot,
        // because the app writes their prompt for them.
        let engine = EchoEngine()
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        let sent = [
            OpenAI.Message(role: "system", content: "You are terse."),
            OpenAI.Message(role: "user", content: "hi")
        ]
        let (status, _) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(model: "echo", messages: sent, stream: false)
        ))
        #expect(status == 200)

        let seen = await engine.receivedMessages
        #expect(seen.count == 2, "no turn may be invented on the caller's behalf")
        #expect(seen.first?.role == .system)
        #expect(seen.first?.content == "You are terse.", "the client's system prompt arrives unedited")
    }

    @Test("a client that sends no system turn is not given one")
    func serverInventsNoSystemTurn() async throws {
        let engine = EchoEngine()
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        let (status, _) = try await harness.send(try harness.request("POST", "/api/chat", json:
            Ollama.ChatRequest(model: "echo", messages: [Ollama.Message(role: "user", content: "hi")], stream: false)
        ))
        #expect(status == 200)

        let seen = await engine.receivedMessages
        #expect(seen.contains { $0.role == .system } == false)
    }

    @Test("answers a HEAD probe at the root")
    func headRoot() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        var request = try harness.request("HEAD", "/")
        request.httpMethod = "HEAD"
        let (status, _) = try await harness.send(request)
        #expect(status == 200, "clients that probe with HEAD read a 404 as 'no server here'")
    }

    @Test("answers HEAD on the endpoints Ollama exposes them for")
    func headEndpoints() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        for path in ["/api/version", "/api/tags"] {
            var request = try harness.request("HEAD", path)
            request.httpMethod = "HEAD"
            let (status, _) = try await harness.send(request)
            #expect(status == 200, "HEAD \(path) should match Ollama")
        }
    }

    @Test("reports the resident model through /api/ps")
    func processList() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/api/ps"))
        #expect(status == 200)

        let body = try JSONDecoder().decode(Ollama.ProcessResponse.self, from: data)
        #expect(body.models.count == 1)
        #expect(body.models.first?.model == "echo")
        #expect((body.models.first?.context_length ?? 0) > 0)
    }

    @Test("retrieves a single model by id")
    func retrieveModel() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/v1/models/echo"))
        #expect(status == 200)

        let model = try JSONDecoder().decode(OpenAI.Model.self, from: data)
        #expect(model.id == "echo")
        #expect(model.object == "model")

        let (missing, _) = try await harness.send(harness.request("GET", "/v1/models/nope"))
        #expect(missing == 404)
    }

    @Test("refuses embeddings with 501 rather than 404")
    func embeddingsNotImplemented() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        for path in ["/v1/embeddings", "/api/embed", "/api/embeddings"] {
            var request = try harness.request("POST", path)
            request.httpBody = Data("{}".utf8)
            let (status, _) = try await harness.send(request)
            #expect(status == 501, "a 404 at \(path) sends people debugging their base URL")
        }
    }

    @Test("emits a usage chunk with empty choices when stream_options asks")
    func streamOptionsIncludeUsage() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        var body = OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "count me")],
            stream: true
        )
        body.stream_options = OpenAI.StreamOptions(include_usage: true)

        let lines = try await harness.lines(try harness.request("POST", "/v1/chat/completions", json: body))
        let payloads = lines.filter { $0.hasPrefix("data: ") }.map { String($0.dropFirst(6)) }
        let chunks = payloads
            .filter { $0 != "[DONE]" }
            .compactMap { try? JSONDecoder().decode(OpenAI.ChatCompletionChunk.self, from: Data($0.utf8)) }

        let usageChunk = try #require(chunks.last)
        // The OpenAI spec requires an empty choices array on the usage chunk.
        #expect(usageChunk.choices.isEmpty)
        #expect(usageChunk.usage != nil)
        #expect((usageChunk.usage?.total_tokens ?? 0) > 0)

        // ...and every earlier chunk must not carry usage.
        #expect(chunks.dropLast().allSatisfy { $0.usage == nil })
    }

    @Test("omits usage entirely when the client did not ask")
    func noUsageChunkByDefault() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let lines = try await harness.lines(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "quiet")],
                stream: true
            )
        ))
        let chunks = lines
            .filter { $0.hasPrefix("data: ") }
            .map { String($0.dropFirst(6)) }
            .filter { $0 != "[DONE]" }
            .compactMap { try? JSONDecoder().decode(OpenAI.ChatCompletionChunk.self, from: Data($0.utf8)) }

        #expect(chunks.allSatisfy { $0.usage == nil })
        #expect(chunks.allSatisfy { !$0.choices.isEmpty })
    }

    @Test("puts parent_model and families on the wire even when empty")
    func modelDetailsAlwaysPresent() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (_, data) = try await harness.send(harness.request("GET", "/api/tags"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = try #require(json?["models"] as? [[String: Any]])
        let details = try #require(models.first?["details"] as? [String: Any])

        // Ollama's Go struct has no omitempty on these two, so a strict client
        // decodes them as required fields.
        #expect(details["parent_model"] != nil)
        #expect(details["families"] != nil)
        #expect(models.first?["capabilities"] != nil)
    }

    @Test("stamps a system fingerprint that names this server")
    func systemFingerprint() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (_, data) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "hi")],
                stream: false
            )
        ))
        let body = try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: data)
        #expect(body.system_fingerprint?.hasPrefix("pocketd-") == true)
    }
}
