import Foundation
import Testing
@testable import PocketdKit

/// The cancellation contract every engine has to meet, pinned against the
/// echo engine because it is the one that runs without weights.
///
/// What it guards is the walkthrough's worst afternoon: Stop on a long reply,
/// and the process kept computing at ~800% CPU for five minutes more, through a
/// brain switch, while every later answer crawled. `LlamaEngine` meets this
/// with llama.cpp's abort callback (`DecodeAbort`), which needs a model to
/// exercise; the shape of the promise — a cancelled stream stops producing,
/// promptly, and the next request answers — is engine-independent and is
/// checked here.
@Suite("Stop stops")
struct EngineCancellationTests {

    /// Slow enough that an uncancelled stream would run for half a minute.
    private func slowEngine() -> EchoEngine {
        EchoEngine(chunkSize: 1, delay: .milliseconds(50))
    }

    private func request(_ text: String = String(repeating: "word ", count: 120)) -> GenerationRequest {
        GenerationRequest(modelID: "", messages: [.user(text)], origin: .onDeviceChat)
    }

    /// Waits up to `seconds` for the engine to report nothing producing.
    private func settles(_ engine: EchoEngine, within seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await engine.activeStreams == 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await engine.activeStreams == 0
    }

    @Test("cancelling the reader stops the stream within a second")
    func cancelStops() async throws {
        let engine = slowEngine()
        let reader = Task {
            var received = 0
            for try await event in try await engine.generate(request()) {
                if case .token = event { received += 1 }
            }
            return received
        }
        try await Task.sleep(for: .milliseconds(200))
        reader.cancel()
        _ = try? await reader.value

        #expect(await settles(engine, within: 1), "a stopped reply must not keep computing")
    }

    @Test("a stream dropped without being drained stops too")
    func droppedStreamStops() async throws {
        let engine = slowEngine()
        do {
            let stream = try await engine.generate(request())
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        }
        // The stream and its iterator are gone; nothing is reading.
        #expect(await settles(engine, within: 1))
    }

    @Test("interrupt ends every stream in flight, and the next request answers in full")
    func interruptThenAnswer() async throws {
        let engine = slowEngine()
        let readers = (0..<3).map { _ in
            Task { () -> Bool in
                do {
                    for try await _ in try await engine.generate(request()) {}
                    return false
                } catch {
                    return true
                }
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        await engine.interrupt()
        for reader in readers { #expect(await reader.value, "an interrupted stream ends as cancelled") }
        #expect(await settles(engine, within: 1))

        let fast = EchoEngine()
        let answer = try await fast.complete(request("still here?"))
        #expect(answer.text == "still here?")
        #expect(answer.reason == .stop)

        // The interrupted engine itself is not left broken.
        let again = try await EchoEngine(chunkSize: 4).complete(request("and again"))
        #expect(again.text == "and again")
        let same = try await engine.complete(request("after"))
        #expect(same.text == "after")
    }

    @Test("an engine with nothing to stop still accepts interrupt")
    func defaultInterrupt() async {
        struct Minimal: InferenceEngine {
            var backendName: String { "minimal" }
            func loadedModel() async -> ModelRecord? { nil }
            func load(model: ModelRecord) async throws {}
            func unload() async {}
            func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        await Minimal().interrupt()
    }
}
