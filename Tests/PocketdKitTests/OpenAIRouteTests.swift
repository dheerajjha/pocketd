import Foundation
import Testing
@testable import PocketdKit

@Suite("OpenAI-compatible API")
struct OpenAIRouteTests {

    @Test("lists installed models")
    func listsModels() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/v1/models"))
        #expect(status == 200)

        let list = try JSONDecoder().decode(OpenAI.ModelList.self, from: data)
        #expect(list.object == "list")
        #expect(list.data.map(\.id) == ["echo"])
        #expect(list.data.allSatisfy { $0.object == "model" })
    }

    @Test("rejects a request with no key")
    func rejectsMissingKey() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/v1/models", key: .some(nil)))
        #expect(status == 401)

        // The error must be in OpenAI's nested shape, or SDKs report it as an
        // unknown failure with no message.
        let body = try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: data)
        #expect(body.error.type == "invalid_request_error")
    }

    @Test("rejects a request with the wrong key")
    func rejectsWrongKey() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, _) = try await harness.send(harness.request("GET", "/v1/models", key: "pk-wrong"))
        #expect(status == 401)
    }

    @Test("serves an unauthenticated request when auth is disabled")
    func allowsAnonymousWhenConfigured() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, requiresAuth: false)
        )
        defer { Task { await harness.stop() } }

        let (status, _) = try await harness.send(harness.request("GET", "/v1/models", key: .some(nil)))
        #expect(status == 200)
    }

    @Test("completes a non-streaming chat request")
    func completesChat() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hello world")],
            stream: false
        ))
        let (status, data) = try await harness.send(request)
        #expect(status == 200)

        let body = try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: data)
        #expect(body.object == "chat.completion")
        #expect(body.model == "echo")
        #expect(body.choices.first?.message.content == "hello world")
        #expect(body.choices.first?.finish_reason == "stop")
        #expect(body.usage.total_tokens == body.usage.prompt_tokens + body.usage.completion_tokens)
    }

    @Test("streams a chat request as server-sent events")
    func streamsChat() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "streaming works")],
            stream: true
        ))
        let lines = try await harness.lines(request)
        let payloads = lines.filter { $0.hasPrefix("data: ") }.map { String($0.dropFirst(6)) }

        #expect(payloads.last == "[DONE]")

        let chunks = payloads
            .filter { $0 != "[DONE]" }
            .compactMap { try? JSONDecoder().decode(OpenAI.ChatCompletionChunk.self, from: Data($0.utf8)) }

        #expect(chunks.count > 1, "a single chunk means the body was buffered, not streamed")
        #expect(chunks.first?.choices.first?.delta.role == "assistant")
        #expect(chunks.last?.choices.first?.finish_reason == "stop")

        let assembled = chunks.compactMap { $0.choices.first?.delta.content }.joined()
        #expect(assembled == "streaming works")
    }

    @Test("caps max_tokens at the configured context limit")
    func capsMaxTokens() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 64)
        )
        defer { Task { await harness.stop() } }

        // The prompt has to be comfortably inside the window — a context so
        // small that the prompt itself does not fit is a different test, and the
        // oversized-prompt guard rightly answers it with a 413.
        let prompt = String(repeating: "z", count: 100)
        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: prompt)],
            stream: false,
            max_tokens: 10_000
        ))
        let (status, data) = try await harness.send(request)
        #expect(status == 200)

        let body = try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: data)
        #expect(body.choices.first?.message.content == String(prompt.prefix(64)))
        #expect(body.choices.first?.finish_reason == "length")
    }

    @Test("reports a 404 for a model that is not installed")
    func unknownModel() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "not-installed",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false
        ))
        let (status, data) = try await harness.send(request)
        #expect(status == 404)

        let body = try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: data)
        #expect(body.error.type == "model_not_found")
    }

    @Test("adapts the legacy completions endpoint")
    func legacyCompletions() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/completions", json: OpenAI.CompletionRequest(
            model: "echo",
            prompt: "legacy path",
            stream: false
        ))
        let (status, data) = try await harness.send(request)
        #expect(status == 200)

        let body = try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: data)
        #expect(body.choices.first?.message.content == "legacy path")
    }

    @Test("rejects a malformed body without taking down the server")
    func malformedBody() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        var request = try harness.request("POST", "/v1/chat/completions")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{ not json".utf8)
        let (status, _) = try await harness.send(request)
        #expect(status == 400)

        let (followUp, _) = try await harness.send(harness.request("GET", "/v1/models"))
        #expect(followUp == 200)
    }
}
