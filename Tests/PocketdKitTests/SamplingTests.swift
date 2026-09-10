import Foundation
import Testing
@testable import PocketdKit

/// These tests exist because the parameters used to decode perfectly and then
/// go nowhere. Asserting on the response body would not have caught that —
/// `EchoEngine` does not sample, and neither did the real engine's answer
/// change. The only place the bug was visible was the value the engine was
/// handed, so that is what is asserted here.
@Suite("Sampling parameters")
struct SamplingTests {

    // MARK: - Off the wire and into the engine

    @Test("an OpenAI request's temperature, top_p and seed reach the engine")
    func openAICarriesSampling() async throws {
        let engine = EchoEngine()
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "deterministic please")],
            stream: false,
            temperature: 0,
            top_p: 0.4,
            seed: 1234,
            top_k: 7,
            repeat_penalty: 1.15
        ))
        let (status, _) = try await harness.send(request)
        #expect(status == 200)

        let seen = try #require(await engine.lastSampling)
        // Zero specifically, not "roughly zero": a client sending
        // `temperature: 0` is asking for greedy decoding, and 0.8 was the whole
        // bug.
        #expect(seen.temperature == 0)
        #expect(seen.topP == 0.4)
        #expect(seen.topK == 7)
        #expect(seen.repeatPenalty == 1.15)
        #expect(seen.seed == 1234)
    }

    @Test("an Ollama request's options reach the engine")
    func ollamaCarriesSampling() async throws {
        let engine = EchoEngine()
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/api/chat", json: Ollama.ChatRequest(
            model: "echo",
            messages: [Ollama.Message(role: "user", content: "hi")],
            stream: false,
            options: Ollama.Options(
                temperature: 0.1,
                top_p: 0.5,
                top_k: 12,
                repeat_penalty: 1.3,
                seed: 99
            )
        ))
        let (status, _) = try await harness.send(request)
        #expect(status == 200)

        let seen = try #require(await engine.lastSampling)
        #expect(seen.temperature == 0.1)
        #expect(seen.topP == 0.5)
        #expect(seen.topK == 12)
        #expect(seen.repeatPenalty == 1.3)
        #expect(seen.seed == 99)
    }

    @Test("the /v1/completions adapter carries sampling through the rewrite")
    func legacyCompletionsCarriesSampling() async throws {
        let engine = EchoEngine()
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/completions", json: OpenAI.CompletionRequest(
            model: "echo",
            prompt: "once upon a time",
            stream: false,
            temperature: 0.25,
            seed: 42,
            top_k: 3
        ))
        let (status, _) = try await harness.send(request)
        #expect(status == 200)

        let seen = try #require(await engine.lastSampling)
        #expect(seen.temperature == 0.25)
        #expect(seen.topK == 3)
        #expect(seen.seed == 42)
    }

    // MARK: - What an omitted field means

    @Test("an omitted field falls back to the server's configured value, not llama.cpp's")
    func omittedFieldsInheritServerDefaults() async throws {
        // What Settings would have written.
        let configured = SamplingParameters(temperature: 0.2, topP: 0.6, topK: 20)
        let engine = EchoEngine(defaultSampling: configured)
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false,
            temperature: 0.9
        ))
        _ = try await harness.send(request)

        let seen = try #require(await engine.lastSampling)
        #expect(seen.temperature == 0.9, "the field the request named")
        // The point of the merge: naming one parameter must not silently revert
        // the others to llama.cpp's numbers.
        #expect(seen.topP == 0.6)
        #expect(seen.topK == 20)
        #expect(seen.seed == nil)
    }

    @Test("a request naming nothing gets llama.cpp's documented defaults")
    func nothingNamedMeansLlamaDefaults() async throws {
        let engine = EchoEngine()
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        _ = try await harness.send(harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false
        )))

        #expect(await engine.lastSampling == .default)
        // These are `common_params_sampling`'s, and the README quotes them.
        #expect(SamplingParameters.default.temperature == 0.8)
        #expect(SamplingParameters.default.topP == 0.95)
        #expect(SamplingParameters.default.topK == 40)
        #expect(SamplingParameters.default.typicalP == 1.0)
        #expect(SamplingParameters.default.repeatPenalty == 1.0)
        #expect(SamplingParameters.default.repeatLastN == 64)
        #expect(SamplingParameters.default.seed == nil)
    }

    // MARK: - Equality, which is what makes this affordable

    @Test("two requests with the same settings resolve equal, so nothing is rebuilt")
    func identicalRequestsCompareEqual() async throws {
        let engine = EchoEngine()
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        for _ in 0..<2 {
            _ = try await harness.send(harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "hi")],
                stream: false,
                temperature: 0.3,
                top_p: 0.7
            )))
        }

        let seen = await engine.receivedSampling
        #expect(seen.count == 2)
        #expect(seen[0] == seen[1], "equal here is what lets LlamaEngine skip the reload")
    }

    @Test("a request that changes one parameter no longer compares equal")
    func changedParameterComparesUnequal() async throws {
        let engine = EchoEngine()
        let harness = try await TestServer.start(engine: engine)
        defer { Task { await harness.stop() } }

        for temperature in [0.3, 0.31] {
            _ = try await harness.send(harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "hi")],
                stream: false,
                temperature: temperature
            )))
        }

        let seen = await engine.receivedSampling
        #expect(seen.count == 2)
        #expect(seen[0] != seen[1])
    }

    @Test("an explicit seed forces a rebuild even against an identical sampler")
    func seedDefeatsEqualitySkipping() {
        let unseeded = SamplingParameters(temperature: 0.3)
        #expect(unseeded.pinsRandomness == false)

        let seeded = SamplingParameters(temperature: 0.3, seed: 7)
        // Equality alone would say "same sampler, do nothing" on the second
        // seeded request — and llama.cpp's RNG would have moved on, so the same
        // seed would produce a different answer. `pinsRandomness` is what stops
        // that being silently wrong.
        #expect(seeded == SamplingParameters(temperature: 0.3, seed: 7))
        #expect(seeded.pinsRandomness)
    }

    // MARK: - Resolution rules

    @Test("options win over a pinned sampler, which wins over the engine's defaults")
    func resolutionPrecedence() {
        let engineDefaults = SamplingParameters(temperature: 0.1, topP: 0.1, topK: 1)
        let pinned = SamplingParameters(temperature: 0.5, topP: 0.5, topK: 5)

        let request = GenerationRequest(
            modelID: "m",
            messages: [.user("hi")],
            options: GenerationOptions(temperature: 0.9),
            sampling: pinned
        )
        let resolved = request.resolvedSampling(defaults: engineDefaults)

        #expect(resolved.temperature == 0.9, "the request body")
        #expect(resolved.topP == 0.5, "the pinned sampler, not the engine's")
        #expect(resolved.topK == 5)
    }

    @Test("an unpinned request resolves against the engine's defaults")
    func unpinnedResolvesAgainstEngine() {
        let engineDefaults = SamplingParameters(temperature: 0.1, topP: 0.1, topK: 1)
        let request = GenerationRequest(modelID: "m", messages: [.user("hi")])

        #expect(request.sampling == nil)
        #expect(request.resolvedSampling(defaults: engineDefaults) == engineDefaults)
    }

    // MARK: - Values that would otherwise take the process down

    @Test("a top_k past Int32 is clamped rather than trapping in llama.cpp")
    func clampsTopKToInt32() {
        // LocalLLMClient converts this with a trapping `Int32.init`. Unclamped,
        // one request body kills the process and every other client's
        // connection with it.
        let resolved = SamplingParameters.default.overriding(GenerationOptions(topK: 99_999_999_999))
        #expect(resolved.topK == Int(Int32.max))

        #expect(SamplingParameters.default.overriding(GenerationOptions(topK: -5)).topK == 0)
    }

    @Test("a non-finite temperature is read as saying nothing")
    func ignoresNonFiniteValues() {
        let base = SamplingParameters(temperature: 0.42, topP: 0.42)
        // NaN would propagate through the whole logit array. Keeping the base
        // value is the only reading that leaves the sampler usable.
        #expect(base.overriding(GenerationOptions(temperature: .nan)).temperature == 0.42)
        #expect(base.overriding(GenerationOptions(topP: .infinity)).topP == 0.42)
    }

    @Test("a negative temperature clamps to greedy, which is what llama.cpp does with it anyway")
    func clampsNegativeTemperature() {
        #expect(SamplingParameters.default.overriding(GenerationOptions(temperature: -1)).temperature == 0)
    }

    @Test("top_p is held inside 0...1")
    func clampsTopP() {
        #expect(SamplingParameters.default.overriding(GenerationOptions(topP: 4)).topP == 1)
        #expect(SamplingParameters.default.overriding(GenerationOptions(topP: -1)).topP == 0)
    }

    // MARK: - Saying no instead of pretending

    @Test("a non-zero frequency_penalty is refused rather than dropped")
    func refusesFrequencyPenalty() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false,
            frequency_penalty: 0.5
        ))
        let (status, data) = try await harness.send(request)
        #expect(status == 400)

        let body = try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: data)
        #expect(body.error.type == "unsupported_parameter")
        // Named, so the client can fix its request without guessing.
        #expect(body.error.message.contains("frequency_penalty"))
    }

    @Test("frequency_penalty: 0 is served, because it asks for nothing")
    func acceptsNoOpPenalties() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false,
            frequency_penalty: 0,
            presence_penalty: 0
        ))
        let (status, _) = try await harness.send(request)
        // Several SDKs send these unprompted. Refusing them would break working
        // clients to make a point about a parameter they never chose.
        #expect(status == 200)
    }

    @Test("min_p is refused on both APIs, because top_p already decides it")
    func refusesMinP() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let openAI = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false,
            min_p: 0.05
        ))
        let (openAIStatus, _) = try await harness.send(openAI)
        #expect(openAIStatus == 400)

        let ollama = try harness.request("POST", "/api/chat", json: Ollama.ChatRequest(
            model: "echo",
            messages: [Ollama.Message(role: "user", content: "hi")],
            stream: false,
            options: Ollama.Options(min_p: 0)
        ))
        let (ollamaStatus, data) = try await harness.send(ollama)
        // Zero is refused too: `min_p` is derived from `top_p` here, so it is
        // never off, and a client asking to turn it off would not get that.
        #expect(ollamaStatus == 400)
        let body = try JSONDecoder().decode(Ollama.ErrorResponse.self, from: data)
        #expect(body.error.contains("min_p"))
    }

    @Test("/api/generate refuses the same options /api/chat does")
    func refusesOnGenerateToo() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let request = try harness.request("POST", "/api/generate", json: Ollama.GenerateRequest(
            model: "echo",
            prompt: "hi",
            stream: false,
            options: Ollama.Options(min_p: 0.1)
        ))
        let (status, _) = try await harness.send(request)
        #expect(status == 400)
    }
}
