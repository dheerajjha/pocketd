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

@Suite("Long generations")
struct LongGenerationTests {

    /// The regression this exists for: FlyingFox's default connection timeout is
    /// 15 seconds, and a non-streamed completion writes nothing until the last
    /// token. Every response longer than a few hundred tokens on a phone came
    /// back as a 500 with an empty body. The old smoke test never caught it
    /// because it only ever asked for 24 tokens.
    @Test("a buffered completion slower than the default timeout still answers", .timeLimit(.minutes(1)))
    func slowBufferedCompletion() async throws {
        // 40 chunks at 500ms is 20 seconds — comfortably past FlyingFox's 15s
        // default, and well inside the configured one.
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, connectionTimeout: 120),
            engine: EchoEngine(chunkSize: 1, delay: .milliseconds(500))
        )
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: String(repeating: "x", count: 40))],
            stream: false
        ))
        let started = ContinuousClock.now
        let (status, data) = try await harness.send(request)
        let elapsed = started.duration(to: .now)

        #expect(elapsed > .seconds(15), "the test is meaningless unless it outlives the old default")
        #expect(status == 200)
        #expect(data.isEmpty == false, "an empty body is what the 15s timeout produced")

        let body = try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: data)
        #expect(body.choices.first?.message.content?.text == String(repeating: "x", count: 40))
    }

    @Test("the default configuration allows a full context at a slow phone's pace")
    func defaultIsGenerous() {
        let configuration = ServerConfiguration()
        let worstCaseSeconds = Double(configuration.maxContextTokens) / 3.0
        #expect(configuration.connectionTimeout >= worstCaseSeconds,
                "a phone at 3 tok/s needs \(Int(worstCaseSeconds))s for a full context")
    }
}

@Suite("Device limits")
struct DeviceConditionTests {

    @Test("a hot phone refuses with a reason and a Retry-After, not an opaque failure")
    func thermalRefusal() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        await harness.server.setCondition(.thermal)

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 503)
        // A client that cannot tell "busy" from "too hot" cannot back off
        // sensibly; thermal recovery is a minute, a charge is not.
        #expect(http.value(forHTTPHeaderField: "Retry-After") == "60")

        let body = try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: data)
        #expect(body.error.type == "device_thermal")
        #expect(body.error.message.contains("hot"))
    }

    @Test("the same refusal reaches an Ollama client in its own shape")
    func thermalRefusalOllama() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }
        await harness.server.setCondition(.battery)

        let (status, data) = try await harness.send(try harness.request("POST", "/api/chat", json:
            Ollama.ChatRequest(model: "echo", messages: [Ollama.Message(role: "user", content: "hi")], stream: false)
        ))
        #expect(status == 503)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(Ollama.ErrorResponse.self, from: data)
        }
    }

    @Test("/health reports the condition so a client can back off before it is refused")
    func healthReportsCondition() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        await harness.server.setCondition(.thermal)
        let (_, data) = try await harness.send(harness.request("GET", "/health", key: .some(nil)))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["condition"] as? String == "thermal")
    }

    @Test("recovering lets work through again")
    func recovery() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        await harness.server.setCondition(.thermal)
        let body = OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false
        )
        #expect(try await harness.send(harness.request("POST", "/v1/chat/completions", json: body)).0 == 503)

        await harness.server.setCondition(.ok)
        #expect(try await harness.send(harness.request("POST", "/v1/chat/completions", json: body)).0 == 200)
    }

    @Test("the server keeps listening while throttled")
    func staysReachable() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }
        await harness.server.setCondition(.thermal)

        // Refusing the connection would look like the phone had gone away. A
        // 503 with a reason is the difference between "broken" and "wait".
        #expect(try await harness.send(harness.request("GET", "/v1/models")).0 == 200)
        #expect(try await harness.send(harness.request("GET", "/health", key: .some(nil))).0 == 200)
    }
}

@Suite("Governor hysteresis")
struct GovernorTests {
    private let floor = 0.15

    @Test("a serious thermal state stops serving")
    func hot() {
        #expect(ServeCondition.evaluate(
            thermalIsSevere: true, thermalIsElevated: false,
            batteryLevel: 0.9, charging: true, floor: floor, current: .ok
        ) == .thermal)
    }

    @Test("recovery from thermal needs more than crossing back over the line")
    func thermalHysteresis() {
        // "fair" is cooler than "serious" but not cool enough to resume: a phone
        // sitting at the boundary would otherwise flap every few seconds, which
        // is worse for a client than staying down.
        #expect(ServeCondition.evaluate(
            thermalIsSevere: false, thermalIsElevated: true,
            batteryLevel: 0.9, charging: true, floor: floor, current: .thermal
        ) == .thermal)

        #expect(ServeCondition.evaluate(
            thermalIsSevere: false, thermalIsElevated: false,
            batteryLevel: 0.9, charging: true, floor: floor, current: .thermal
        ) == .ok)
    }

    @Test("a flat battery stops serving, and charging exempts it")
    func battery() {
        #expect(ServeCondition.evaluate(
            thermalIsSevere: false, thermalIsElevated: false,
            batteryLevel: 0.10, charging: false, floor: floor, current: .ok
        ) == .battery)

        // Plugged in, the phone is not going flat, so the floor does not apply.
        #expect(ServeCondition.evaluate(
            thermalIsSevere: false, thermalIsElevated: false,
            batteryLevel: 0.10, charging: true, floor: floor, current: .ok
        ) == .ok)
    }

    @Test("battery recovery needs five points of headroom")
    func batteryHysteresis() {
        // Exactly at the floor is not recovery.
        #expect(ServeCondition.evaluate(
            thermalIsSevere: false, thermalIsElevated: false,
            batteryLevel: 0.15, charging: false, floor: floor, current: .battery
        ) == .battery)

        #expect(ServeCondition.evaluate(
            thermalIsSevere: false, thermalIsElevated: false,
            batteryLevel: 0.20, charging: false, floor: floor, current: .battery
        ) == .ok)
    }

    @Test("an unknown battery level is not treated as flat")
    func unknownBattery() {
        // UIDevice reports -1 when monitoring is off or unavailable. Reading
        // that as "below the floor" would refuse every request on a simulator.
        #expect(ServeCondition.evaluate(
            thermalIsSevere: false, thermalIsElevated: false,
            batteryLevel: -1, charging: false, floor: floor, current: .ok
        ) == .ok)
    }

    @Test("thermal outranks battery")
    func thermalWins() {
        #expect(ServeCondition.evaluate(
            thermalIsSevere: true, thermalIsElevated: false,
            batteryLevel: 0.05, charging: false, floor: floor, current: .ok
        ) == .thermal)
    }
}
