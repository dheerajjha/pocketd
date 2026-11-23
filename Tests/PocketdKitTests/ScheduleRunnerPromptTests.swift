import Foundation
import PocketdKit
import Testing

@Suite("Scheduled prompt completion")
@MainActor
final class ScheduleRunnerPromptTests {
    private static let firing = Date(timeIntervalSince1970: 1_790_000_000)
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let store: ScheduledTaskStore
    private let task: ScheduledTask

    init() async throws {
        store = ScheduledTaskStore(directory: directory)
        task = ScheduledTask(title: "Count", body: .prompt("Count the fruit"), recurrence: .once(Self.firing),
                             createdAt: Self.firing.addingTimeInterval(-60))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await store.save(task)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func runner(_ first: Events) -> ScheduleRunner {
        let retry = End.finished(.stop).stream(text: "Three apples.")
        let now = Self.firing.addingTimeInterval(30)
        return ScheduleRunner(
            store: store, engine: ScriptedEngine([first, retry]),
            readEvents: { _ in .rows([], truncated: false) }, readReminders: { _ in .rows([], truncated: false) },
            host: .init(isUserGenerating: { false }, systemPrompt: { "" }, maxTokens: { 120 }, record: { _ in }),
            now: { now }
        )
    }

    private func onDisk() async throws -> ScheduledTask {
        try #require(await ScheduledTaskStore(directory: directory).task(task.id))
    }

    private func expectSettlement(_ runner: ScheduleRunner, _ outcome: TaskRun.Outcome, text: String?) async throws {
        let completions = await runner.sweep(in: .foreground)
        #expect(completions.count == 1)
        let run = try #require(completions.first?.run)
        #expect(run.firing == Self.firing)
        #expect(run.outcome == outcome)
        #expect(run.output?.attackerControlledValue() == text)
        let saved = try await onDisk()
        #expect(saved.runs == [run])
        #expect(saved.settledThrough == Self.firing)
        #expect(await runner.sweep(in: .foreground).isEmpty)
    }

    @Test("cancelling the reader after it consumed a token leaves its one-shot due", .timeLimit(.minutes(1)))
    func cancelSweep() async throws {
        let ready = AsyncStream<Void>.makeStream()
        let hold = AsyncStream<Void>.makeStream()
        defer { ready.continuation.finish(); hold.continuation.finish() }
        let pause = PauseAfterToken(ready: ready.continuation, hold: hold.stream)
        let runner = runner(Events(unfolding: { await pause.next() }))
        let sweep = Task { await runner.sweep(in: .foreground) }
        defer { sweep.cancel() }

        var signal = ready.stream.makeAsyncIterator()
        try #require(await signal.next() != nil)
        sweep.cancel()
        #expect(await sweep.value.isEmpty)
        #expect(try await onDisk() == task)
        try await expectSettlement(runner, .reported, text: "Three apples.")
    }

    @Test("engine cancellation preserves even an already-promised firing", arguments: [
        End.finished(.cancelled), .threw(.cancelled), .swiftCancellation
    ])
    func engineCancellation(_ end: End) async throws {
        let runner = runner(end.stream(text: "Partial answer"))
        let promised = await runner.sweep(in: .backgroundRefresh)
        #expect(promised.first?.run.outcome == .awaitingForeground)
        let before = try await onDisk()

        #expect(await runner.sweep(in: .notificationResponse).isEmpty)
        #expect(try await onDisk() == before)
        try await expectSettlement(runner, .reported, text: "Three apples.")
    }

    @Test("both clean stop and the configured length cap can report text", arguments: [FinishReason.stop, .length])
    func completed(_ reason: FinishReason) async throws {
        let runner = runner(End.finished(reason).stream(text: "Two pears."))
        try await expectSettlement(runner, .reported, text: "Two pears.")
    }

    @Test("a backend error or an unmarked EOF discards any tokens and settles as a failure", arguments: [
        End.threw(.backend("decode failed")), .eof
    ])
    func hardFailure(_ end: End) async throws {
        let runner = runner(end.stream(text: "Partial answer"))
        try await expectSettlement(runner, .failed(.other), text: nil)
    }

    @Test("losing the resident model during generation keeps its distinct failure")
    func lostModel() async throws {
        let runner = runner(End.threw(.noModelLoaded).stream(text: ""))
        try await expectSettlement(runner, .failed(.noModelLoaded), text: nil)
    }

    enum End: Sendable {
        case finished(FinishReason), threw(InferenceError), swiftCancellation, eof

        fileprivate func stream(text: String) -> Events {
            Events { stream in
                stream.yield(.token(text))
                switch self {
                case let .finished(reason):
                    stream.yield(.finished(reason: reason, usage: .init()))
                    stream.finish()
                case let .threw(error): stream.finish(throwing: error)
                case .swiftCancellation: stream.finish(throwing: CancellationError())
                case .eof: stream.finish()
                }
            }
        }
    }
}

private typealias Events = AsyncThrowingStream<GenerationEvent, any Error>

private actor ScriptedEngine: InferenceEngine {
    private var streams: [Events]
    init(_ streams: [Events]) { self.streams = streams }
    nonisolated let backendName = "fixture"
    func loadedModel() -> ModelRecord? { .echo }
    func load(model: ModelRecord) {}
    func unload() {}
    func generate(_ request: GenerationRequest) throws -> Events {
        guard !streams.isEmpty else {
            Issue.record("Generated again for a spent one-shot")
            throw InferenceError.backend("unexpected generation")
        }
        return streams.removeFirst()
    }
}

private actor PauseAfterToken {
    let ready: AsyncStream<Void>.Continuation
    let hold: AsyncStream<Void>
    var sent = false

    init(ready: AsyncStream<Void>.Continuation, hold: AsyncStream<Void>) {
        self.ready = ready
        self.hold = hold
    }

    func next() async -> GenerationEvent? {
        if !sent { sent = true; return .token("Partial answer") }
        // The runner asked for its *next* event, so it already consumed the
        // partial answer. A real Task.cancel() wakes this wait without throwing.
        ready.yield(())
        var iterator = hold.makeAsyncIterator()
        _ = await iterator.next()
        return nil
    }
}

// ScheduleRunner.swift in this test target links to the actual app source.
// Its brief reader is device-only and must never be called by a prompt sweep.
enum BriefNotice {
    static func sentence(now: Date, calendar: Calendar) async -> String? {
        Issue.record("Unexpected brief read")
        return nil
    }

    static func run(sentence: String?, firing: Date, ranAt: Date, context: ExecutionContext) -> TaskRun {
        Issue.record("Unexpected brief run")
        return .failed(.other, firing: firing, ranAt: ranAt, context: context)
    }
}
