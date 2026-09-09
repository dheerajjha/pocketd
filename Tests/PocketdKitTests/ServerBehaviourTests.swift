import Foundation
import Testing
@testable import PocketdKit

@Suite("Server behaviour")
struct ServerBehaviourTests {

    @Test("reports health without a key so a client can probe reachability")
    func health() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/health", key: .some(nil)))
        #expect(status == 200)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["status"] as? String == "ok")
        #expect(json?["backend"] as? String == "echo")
        #expect(json?["model"] as? String == "echo")
    }

    @Test("refuses a second concurrent generation instead of thrashing the GPU")
    func admissionControl() async throws {
        // A slow engine keeps the first request in flight long enough for the
        // second to arrive while it is still generating.
        let harness = try await TestServer.start(
            engine: EchoEngine(chunkSize: 1, delay: .milliseconds(120))
        )
        defer { Task { await harness.stop() } }

        let body = OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "abcdefgh")],
            stream: false
        )
        async let first = harness.send(try harness.request("POST", "/v1/chat/completions", json: body))
        try await Task.sleep(for: .milliseconds(150))
        let second = try await harness.send(harness.request("POST", "/v1/chat/completions", json: body))

        #expect(second.0 == 503)
        let (firstStatus, _) = try await first
        #expect(firstStatus == 200)
    }

    @Test("accepts the next request once the previous one finishes")
    func releasesSlotAfterCompletion() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let body = OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "one")],
            stream: false
        )
        for _ in 0..<3 {
            let (status, _) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json: body))
            #expect(status == 200)
        }
    }

    @Test("frees the slot when a stream ends")
    func releasesSlotAfterStreaming() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let streaming = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "stream")],
            stream: true
        ))
        _ = try await harness.lines(streaming)

        let (status, _) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "after")],
                stream: false
            )
        ))
        #expect(status == 200, "a streamed request that never released its slot would deadlock the server")
    }

    @Test("records requests in the log with timing and token counts")
    func logsRequests() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        _ = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "logged")],
                stream: false
            )
        ))

        let entries = await harness.server.log.all()
        let entry = try #require(entries.first)
        #expect(entry.path == "/v1/chat/completions")
        #expect(entry.statusCode == 200)
        #expect(entry.model == "echo")
        #expect((entry.duration ?? 0) > 0)
    }

    @Test("answers a 404 for an unknown path in the caller's dialect")
    func unknownPath() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (openAIStatus, openAIData) = try await harness.send(harness.request("GET", "/v1/nope"))
        #expect(openAIStatus == 404)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: openAIData)
        }

        let (ollamaStatus, ollamaData) = try await harness.send(harness.request("GET", "/api/nope"))
        #expect(ollamaStatus == 404)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(Ollama.ErrorResponse.self, from: ollamaData)
        }
    }

    @Test("answers a CORS preflight")
    func preflight() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        var request = try harness.request("OPTIONS", "/v1/chat/completions", key: .some(nil))
        request.setValue("https://example.com", forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        _ = data

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 204)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
    }

    @Test("restarts cleanly on a new port")
    func restart() async throws {
        let harness = try await TestServer.start()
        let firstPort = harness.baseURL.port

        try await harness.server.apply(ServerConfiguration(
            port: 0, binding: .loopback, apiKey: harness.apiKey
        ))
        let state = await harness.server.currentState()
        #expect(state.isRunning)

        await harness.stop()
        let stopped = await harness.server.currentState()
        #expect(stopped == .stopped)
        #expect(firstPort != nil)
    }
}
