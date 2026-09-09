import Foundation
import Testing
@testable import PocketdKit

@Suite("Wire format details")
struct WireFormatTests {

    @Test("decodes stop as either a string or an array")
    func stopSequences() throws {
        let single = try JSONDecoder().decode(StringOrArray.self, from: Data("\"###\"".utf8))
        #expect(single.values == ["###"])

        let many = try JSONDecoder().decode(StringOrArray.self, from: Data(#"["a","b"]"#.utf8))
        #expect(many.values == ["a", "b"])

        // A number is neither, and must not take down the whole request decode.
        let neither = try JSONDecoder().decode(StringOrArray.self, from: Data("42".utf8))
        #expect(neither.values.isEmpty)
    }

    @Test("prefers max_completion_tokens over the deprecated max_tokens")
    func tokenLimitPrecedence() {
        var request = OpenAI.ChatCompletionRequest(model: "m", messages: [])
        request.max_tokens = 100
        request.max_completion_tokens = 50
        #expect(request.resolvedMaxTokens == 50)

        request.max_completion_tokens = nil
        #expect(request.resolvedMaxTokens == 100)
    }

    @Test("survives a message with null content")
    func nullContent() throws {
        let json = #"{"model":"m","messages":[{"role":"assistant","content":null}]}"#
        let request = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.chatMessages() == [ChatMessage(role: .assistant, content: "")])
    }

    @Test("maps an unknown role to user rather than failing the request")
    func unknownRole() throws {
        let json = #"{"model":"m","messages":[{"role":"developer","content":"hi"}]}"#
        let request = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.chatMessages().first?.role == .user)
    }

    @Test("frames server-sent events with a blank line terminator")
    func sseFraming() {
        let frame = ServerSentEvents.frame(Data(#"{"a":1}"#.utf8))
        #expect(String(decoding: frame, as: UTF8.self) == "data: {\"a\":1}\n\n")
        #expect(String(decoding: ServerSentEvents.done, as: UTF8.self) == "data: [DONE]\n\n")
    }

    @Test("emits an RFC 3339 timestamp with fractional seconds")
    func ollamaTimestamp() {
        let stamp = Ollama.timestamp(Date(timeIntervalSince1970: 0))
        #expect(stamp.hasPrefix("1970-01-01T00:00:00."))
        #expect(stamp.hasSuffix("Z"))
    }
}

@Suite("Streaming body adapter")
struct StreamingBodyTests {

    @Test("reassembles chunks byte-for-byte")
    func reassembles() async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.yield(Data("hello ".utf8))
        continuation.yield(Data())            // empty chunk must not end the stream
        continuation.yield(Data("world".utf8))
        continuation.finish()

        var iterator = DataStreamSequence(stream: stream).makeAsyncIterator()
        var collected = Data()
        while let buffer = try await iterator.nextBuffer(suggested: 4) {
            #expect(buffer.count <= 4)
            collected.append(buffer)
        }
        #expect(String(decoding: collected, as: UTF8.self) == "hello world")
    }

    @Test("reports the end of the stream exactly once")
    func terminates() async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.finish()

        var iterator = DataStreamSequence(stream: stream).makeAsyncIterator()
        #expect(try await iterator.nextBuffer(suggested: 16) == nil)
        #expect(try await iterator.nextBuffer(suggested: 16) == nil)
    }
}

@Suite("Device memory budget")
struct DeviceBudgetTests {

    /// An iPhone 14: 6 GB physical, no increased-memory-limit entitlement.
    private let iPhone14 = DeviceBudget(
        physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
        hasIncreasedMemoryLimit: false
    )

    @Test("fits a 1B model comfortably on a 6 GB device")
    func smallModelFits() throws {
        let model = try #require(ModelCatalog.model(withID: "llama-3.2-1b"))
        #expect(iPhone14.fit(for: model) == .comfortable)
    }

    @Test("calls a 3B model tight rather than comfortable")
    func mediumModelIsTight() throws {
        let model = try #require(ModelCatalog.model(withID: "llama-3.2-3b"))
        #expect(iPhone14.fit(for: model) == .tight)
    }

    @Test("a 4B model needs the entitlement on a 6 GB device")
    func fourBillionNeedsEntitlement() throws {
        // This is the whole reason the entitlement is worth the trouble: without
        // it a 4B Q4 model is not "slow", it is killed on load.
        let model = try #require(ModelCatalog.model(withID: "qwen3-4b"))
        #expect(iPhone14.fit(for: model) == .willNotFit)

        let entitled = DeviceBudget(
            physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
            hasIncreasedMemoryLimit: true
        )
        #expect(entitled.fit(for: model) == .tight)
    }

    @Test("refuses a model that cannot fit at all")
    func oversizedModelRefused() {
        let huge = ModelRecord(
            id: "huge", displayName: "Huge", repoID: "x/y", filename: "z.gguf",
            parameters: "30B", quantization: "Q4_K_M",
            sizeBytes: 19_000_000_000, contextLength: 8192, license: "n/a"
        )
        #expect(iPhone14.fit(for: huge) == .willNotFit)
        #expect(!iPhone14.fit(for: huge).allowsDownload)
    }

    @Test("the entitlement raises the ceiling but does not double it")
    func entitlementEffect() {
        let entitled = DeviceBudget(
            physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
            hasIncreasedMemoryLimit: true
        )
        #expect(entitled.usableBytes > iPhone14.usableBytes)
        #expect(entitled.usableBytes < iPhone14.physicalMemoryBytes)
    }
}

@Suite("Model store")
struct ModelStoreTests {

    @Test("round-trips the manifest and forgets files that vanished")
    func manifestRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let budget = DeviceBudget(physicalMemoryBytes: 8 << 30, hasIncreasedMemoryLimit: false)
        let store = ModelStore(directory: directory, budget: budget)
        let model = try #require(ModelCatalog.model(withID: "smollm2-360m"))

        // Simulate a completed download.
        try Data("weights".utf8).write(to: store.fileURL(for: model))
        let manifest = [model.id: model]
        try JSONEncoder().encode(manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))

        await store.load()
        #expect(await store.installed().map(\.id) == [model.id])

        try FileManager.default.removeItem(at: store.fileURL(for: model))
        let reopened = ModelStore(directory: directory, budget: budget)
        await reopened.load()
        #expect(await reopened.installed().isEmpty, "a manifest that outlives its files lies to /v1/models")
    }

    @Test("refuses to download a model the device cannot hold")
    func refusesOversized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ModelStore(
            directory: directory,
            budget: DeviceBudget(physicalMemoryBytes: 2 << 30, hasIncreasedMemoryLimit: false)
        )
        let model = try #require(ModelCatalog.model(withID: "qwen3-4b"))

        await #expect(throws: ModelStoreError.insufficientMemory(model: model.id)) {
            for try await _ in await store.download(model) {}
        }
    }
}

@Suite("Catalogue")
struct CatalogTests {

    @Test("every entry has a unique, URL-safe id")
    func uniqueIDs() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0 == $0.lowercased() })
        #expect(ids.allSatisfy { !$0.contains(" ") })
    }

    @Test("every entry points at a resolvable Hugging Face URL")
    func downloadURLs() {
        for model in ModelCatalog.all {
            let url = model.downloadURL
            #expect(url.host() == "huggingface.co")
            #expect(url.path().contains(model.filename))
        }
    }

    @Test("generated API keys are unique and prefixed")
    func apiKeys() {
        let keys = (0..<50).map { _ in ServerConfiguration.generateAPIKey() }
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix("pk-") && $0.count == 35 })
    }
}
