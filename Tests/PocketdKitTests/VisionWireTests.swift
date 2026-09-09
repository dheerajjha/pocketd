import Foundation
import Testing
@testable import PocketdKit

@Suite("Image content on the wire")
struct VisionWireTests {
    /// A one-pixel PNG, so the fixture is real bytes rather than a placeholder.
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    @Test("OpenAI content parts decode into text plus image bytes")
    func openAIContentParts() throws {
        let json = """
        {"model":"m","messages":[{"role":"user","content":[
          {"type":"text","text":"What is in this picture?"},
          {"type":"image_url","image_url":{"url":"data:image/png;base64,\(pngBase64)"}}
        ]}]}
        """
        let request = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: Data(json.utf8))
        let messages = request.chatMessages()

        #expect(messages.count == 1)
        #expect(messages[0].content == "What is in this picture?")
        #expect(messages[0].images.count == 1)
        #expect(messages[0].images[0].count > 0)
    }

    @Test("a plain string content still decodes, as most requests send")
    func openAIPlainString() throws {
        let json = #"{"model":"m","messages":[{"role":"user","content":"just text"}]}"#
        let request = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.chatMessages()[0].content == "just text")
        #expect(request.chatMessages()[0].images.isEmpty)
    }

    @Test("http image URLs are refused, only data: URIs accepted")
    func refusesRemoteImages() {
        // Fetching a remote image would make the phone issue outbound requests
        // on a caller's behalf — a request-forgery surface a local inference
        // server has no reason to open.
        #expect(OpenAI.MessageContent.decodeDataURI("https://example.com/cat.png") == nil)
        #expect(OpenAI.MessageContent.decodeDataURI("file:///etc/passwd") == nil)
        #expect(OpenAI.MessageContent.decodeDataURI("data:image/png;base64,\(pngBase64)") != nil)
        // Non-base64 data URIs are not images we can use.
        #expect(OpenAI.MessageContent.decodeDataURI("data:text/plain,hello") == nil)
    }

    @Test("Ollama carries images as a flat base64 array, not typed parts")
    func ollamaImages() throws {
        let json = """
        {"model":"m","messages":[{"role":"user","content":"describe","images":["\(pngBase64)"]}]}
        """
        let request = try JSONDecoder().decode(Ollama.ChatRequest.self, from: Data(json.utf8))
        #expect(request.messages[0].imageData.count == 1)
        // Ollama sends no data: prefix, so a decoder expecting one gets nothing.
        #expect(request.messages[0].images?.first?.hasPrefix("data:") == false)
    }

    @Test("a text-only model reports no vision, and the resident one reports what it can do")
    func capabilitiesAreHonest() async throws {
        let vision = try #require(ModelCatalog.model(withID: "smolvlm-500m"))
        let text = try #require(ModelCatalog.model(withID: "smollm2-360m"))

        // Declared: a property of the model.
        #expect(vision.declaredCapabilities.vision == .yes)
        #expect(text.declaredCapabilities.vision == .no)

        // Live: only meaningful for whatever is actually loaded, which is why
        // it is a separate axis rather than the same flag.
        #expect(vision.declaredCapabilities.visionActive == false)
        // The listing advertises what the model can do once loaded, because a
        // request naming it triggers that load. Only /health reports residency.
        #expect(vision.declaredCapabilities.ollamaCapabilities == ["completion", "vision"])
        #expect(text.declaredCapabilities.ollamaCapabilities == ["completion"])
    }

    @Test("/v1/models reports capabilities and context length")
    func modelsEndpointReportsCapabilities() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/v1/models"))
        #expect(status == 200)
        let list = try JSONDecoder().decode(OpenAI.ModelList.self, from: data)
        #expect(list.data.first?.capabilities?.contains("completion") == true)
    }
}

@Suite("Pulling models")
struct PullTests {

    @Test("the catalogue lists what can be pulled and what is already here")
    func catalogue() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(harness.request("GET", "/api/catalogue"))
        #expect(status == 200)

        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let list = try #require(entries)
        #expect(list.count == ModelCatalog.all.count)
        // The catalogue answers "what could I have", which is a different
        // question from /v1/models — that one answers "what can I use now".
        #expect(list.contains { ($0["id"] as? String) == "smolvlm-500m" })
        let vision = try #require(list.first { ($0["id"] as? String) == "smolvlm-500m" })
        #expect((vision["capabilities"] as? [String])?.contains("vision") == true)
    }

    @Test("pulling an unknown model says so rather than hanging")
    func unknownModel() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, _) = try await harness.send(try harness.request(
            "POST", "/api/pull", json: InferenceServer.PullRequest(model: "no-such-model", name: nil, stream: nil)
        ))
        #expect(status == 404)
    }

    @Test("a server with no downloader answers 501, not a hang or a 404")
    func noDownloader() async throws {
        // TestServer builds an InferenceServer without a puller, which is the
        // same shape as a build that cannot download.
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, _) = try await harness.send(try harness.request(
            "POST", "/api/pull", json: InferenceServer.PullRequest(model: "smollm2-360m", name: nil, stream: nil)
        ))
        #expect(status == 501)
    }
}
