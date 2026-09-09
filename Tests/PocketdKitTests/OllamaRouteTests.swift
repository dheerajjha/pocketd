import Foundation
import Testing
@testable import PocketdKit

@Suite("Ollama-compatible API")
struct OllamaRouteTests {

    @Test("answers the root probe Ollama clients expect")
    func rootProbe() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/"))
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self) == "Ollama is running")
    }

    @Test("lists models under /api/tags")
    func tags() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/api/tags"))
        #expect(status == 200)

        let body = try JSONDecoder().decode(Ollama.TagsResponse.self, from: data)
        #expect(body.models.map(\.name) == ["echo"])
        #expect(body.models.first?.details.format == "gguf")
    }

    @Test("reports a version that parses as semver")
    func version() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/api/version"))
        #expect(status == 200)

        let body = try JSONDecoder().decode(Ollama.VersionResponse.self, from: data)
        #expect(body.version.split(separator: ".").count == 3)
    }

    @Test("streams newline-delimited JSON, not SSE")
    func streamsNDJSON() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/api/chat", json: Ollama.ChatRequest(
            model: "echo",
            messages: [Ollama.Message(role: "user", content: "ndjson please")],
            stream: true
        ))
        let lines = try await harness.lines(request).filter { !$0.isEmpty }

        // An SSE `data: ` prefix here would be silently unparseable to every
        // Ollama client, so assert its absence explicitly.
        #expect(lines.allSatisfy { !$0.hasPrefix("data: ") })

        let responses = lines.compactMap {
            try? JSONDecoder().decode(Ollama.ChatResponse.self, from: Data($0.utf8))
        }
        #expect(responses.count == lines.count, "every line must be a complete JSON object")
        #expect(responses.dropLast().allSatisfy { !$0.done })
        #expect(responses.last?.done == true)
        #expect(responses.last?.done_reason == "stop")

        let assembled = responses.map(\.message.content).joined()
        #expect(assembled == "ndjson please")
    }

    @Test("streams by default when the client omits the flag")
    func streamsByDefault() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/api/chat", json: Ollama.ChatRequest(
            model: "echo",
            messages: [Ollama.Message(role: "user", content: "default")],
            stream: nil
        ))
        let lines = try await harness.lines(request).filter { !$0.isEmpty }
        #expect(lines.count > 1, "Ollama's default is to stream, unlike OpenAI's")
    }

    @Test("serves a buffered response when streaming is off")
    func buffered() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/api/generate", json: Ollama.GenerateRequest(
            model: "echo",
            prompt: "one shot",
            stream: false
        ))
        let (status, data) = try await harness.send(request)
        #expect(status == 200)

        let body = try JSONDecoder().decode(Ollama.GenerateResponse.self, from: data)
        #expect(body.response == "one shot")
        #expect(body.done)
        #expect((body.eval_count ?? 0) >= 0)
    }

    @Test("treats num_predict of -1 as unlimited rather than zero")
    func unlimitedNumPredict() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/api/generate", json: Ollama.GenerateRequest(
            model: "echo",
            prompt: "full length please",
            stream: false,
            options: Ollama.Options(num_predict: -1)
        ))
        let (status, data) = try await harness.send(request)
        #expect(status == 200)

        let body = try JSONDecoder().decode(Ollama.GenerateResponse.self, from: data)
        #expect(body.response == "full length please")
    }

    @Test("reports errors in Ollama's flat shape")
    func errorShape() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/api/chat", json: Ollama.ChatRequest(
            model: "missing",
            messages: [Ollama.Message(role: "user", content: "hi")],
            stream: false
        ))
        let (status, data) = try await harness.send(request)
        #expect(status == 404)

        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(Ollama.ErrorResponse.self, from: data)
        }
    }
}
