import Foundation
import Testing
@testable import PocketdKit

/// A crash report from a real device is the reason this file exists:
/// `llama_batch.add(id:pos:seq_ids:logits:)` raising a Swift assertion inside
/// `Context.decode(text:)`, SIGTRAP, process gone. One oversized request from
/// any client took the whole server down and every other connection with it.
@Suite("Oversized prompts")
struct ContextGuardTests {

    @Test("a prompt past the window is refused, not passed to the model")
    func refusesOversized() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 512)
        )
        defer { Task { await harness.stop() } }

        let huge = String(repeating: "word ", count: 20_000)
        let (status, data) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: huge)],
                stream: false
            )
        ))

        #expect(status == 413)
        let body = try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: data)
        #expect(body.error.type == "context_length_exceeded")
    }

    @Test("the server still answers after refusing one")
    func survivesOversized() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 512)
        )
        defer { Task { await harness.stop() } }

        _ = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: String(repeating: "word ", count: 20_000))],
                stream: false
            )
        ))

        // The real defect was not the 413 — it was that nothing worked afterwards.
        let (status, _) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "still here?")],
                stream: false
            )
        ))
        #expect(status == 200)
    }

    @Test("refuses on the Ollama route too, in its own error shape")
    func ollamaRoute() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 512)
        )
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(try harness.request("POST", "/api/chat", json:
            Ollama.ChatRequest(
                model: "echo",
                messages: [Ollama.Message(role: "user", content: String(repeating: "word ", count: 20_000))],
                stream: false
            )
        ))
        #expect(status == 413)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(Ollama.ErrorResponse.self, from: data)
        }
    }

    @Test("an ordinary prompt is not refused")
    func allowsNormal() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 4096)
        )
        defer { Task { await harness.stop() } }

        let (status, _) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: String(repeating: "a paragraph of prose. ", count: 100))],
                stream: false
            )
        ))
        #expect(status == 200, "a 2 KB prompt in a 4096-token window must go through")
    }

    @Test("the estimate is pessimistic, never optimistic")
    func estimateIsPessimistic() {
        // Four characters per token is the English average; the guard uses three
        // so that code, JSON and non-Latin text cannot slip past it.
        let text = String(repeating: "x", count: 1200)
        #expect(ContextGuard.estimateTokens(text) >= text.count / 4)
        #expect(ContextGuard.charactersPerToken < 4)
    }

    @Test("reserves room for the answer")
    func reservesCompletion() {
        let guardian = ContextGuard(contextTokens: 1000, reservedForCompletion: 200)
        #expect(guardian.promptBudget == 800)
        // A prompt that exactly fills the window leaves nowhere to reply.
        let filling = [ChatMessage.user(String(repeating: "x", count: 1000 * ContextGuard.charactersPerToken))]
        #expect(guardian.fits(filling) == false)
    }
}
