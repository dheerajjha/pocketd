import Foundation
import Testing
@testable import PocketdKit

@Suite("Private Cloud Compute is a distinct, explicit phone choice")
struct PrivateCloudChoiceTests {
    @Test("Readiness never selects cloud for a new install, a missing download, or a legacy local preference")
    func localDefaults() {
        let file = "my-gguf", cloud = ModelRecord.privateCloudComputeID
        #expect(BrainChoice.effective(chosen: nil, builtIn: .available, installed: [], cloud: .available) == .builtIn)
        #expect(BrainChoice.effective(chosen: nil, builtIn: .notEligible, installed: [cloud, file], cloud: .available) == .downloaded(id: file))
        #expect(BrainChoice.effective(chosen: nil, builtIn: .notEligible, installed: [cloud], cloud: .available) == nil)
        #expect(BrainChoice.effective(chosen: .downloaded(id: file), builtIn: .available, installed: [], cloud: .available) == .builtIn)
        #expect(BrainChoice(storedValue: "downloaded:" + cloud) == nil)
        #expect(!ProAccess.brainNeedsPro(id: cloud, recommendedID: nil, onPhone: []))
    }

    @Test("A real choice survives relaunch and a temporary limit; an unsupported device uses a local alternative")
    func remembered() throws {
        let suite = "PocketdCloudChoiceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ModelRecord.privateCloudComputeID, forKey: "pocketd.loadedModel")
        #expect(BrainChoice.load(from: defaults) == nil)
        BrainChoice.privateCloudCompute.save(to: defaults)
        let chosen = BrainChoice.load(from: try #require(UserDefaults(suiteName: suite)))
        #expect(chosen == .privateCloudCompute && chosen?.modelID == ModelRecord.privateCloudComputeID)
        for cloud in [AppleCloudStatus.available, .approachingLimit, .limitReached(reset: nil), .notReady] {
            #expect(BrainChoice.effective(chosen: chosen, builtIn: .available, installed: ["small"], cloud: cloud) == .privateCloudCompute)
        }
        #expect(BrainChoice.effective(chosen: chosen, builtIn: .available, installed: ["small"], cloud: .unavailable) == .builtIn)
        #expect(BrainChoice.effective(chosen: chosen, builtIn: .notEligible, installed: ["small"], cloud: .unavailable) == .downloaded(id: "small"))
    }

    @Test("Only explicit phone requests for the selected PCC model may reach its transport")
    func dispatch() throws {
        let cloud = ModelRecord.privateCloudComputeID
        func request(_ id: String, _ origin: RequestOrigin) -> GenerationRequest {
            .init(modelID: id, messages: [.user("Hello")], origin: origin)
        }
        for origin in [RequestOrigin.onDeviceChat, .scheduledTask(id: UUID())] {
            try BrainChoice.validateCloudRoute(request(cloud, origin), selected: .privateCloudCompute)
        }
        #expect(throws: InferenceError.modelNotFound(cloud)) {
            try BrainChoice.validateCloudRoute(request(cloud, .network(host: "localhost", port: 1)), selected: .privateCloudCompute)
        }
        for local in [ModelRecord.builtInID, "downloaded-file", ""] {
            #expect(throws: InferenceError.modelMismatch(requested: local, loaded: cloud)) {
                try BrainChoice.validateCloudRoute(request(local, .onDeviceChat), selected: .privateCloudCompute)
            }
        }
        #expect(throws: InferenceError.noModelLoaded) {
            try BrainChoice.validateCloudRoute(request(cloud, .onDeviceChat), selected: .builtIn)
        }
    }

    @Test("Ask reports actual quota state and offers a local choice, without affecting local conversations")
    func notices() {
        let limited = AppleCloudStatus.limitReached(reset: nil)
        let notice = AskNotice.decide(.init(brain: .failed(reason: "limit"), selectedCloud: limited))
        #expect(notice == .appleCloud(limited) && notice?.action == .chooseBrain)
        #expect(AskNotice.decide(.init(brain: .ready, selectedCloud: .approachingLimit)) == .appleCloud(.approachingLimit))
        #expect(AskNotice.decide(.init(brain: .ready, selectedCloud: .available)) == nil)
        #expect(AskNotice.decide(.init(brain: .ready)) == nil)
    }

    @Test("A laptop can still use a download, but neither wire format advertises or serves Apple's phone-only models")
    func laptopServer() async throws {
        let h = try await TestServer.start(models: [.privateCloudCompute, .builtIn, .echo])
        defer { Task { await h.stop() } }
        let (ls, list) = try await h.send(h.request("GET", "/v1/models"))
        #expect(ls == 200)
        #expect(try JSONDecoder().decode(OpenAI.ModelList.self, from: list).data.map(\.id) == ["echo"])
        let (ts, tags) = try await h.send(h.request("GET", "/api/tags"))
        #expect(ts == 200)
        #expect(try JSONDecoder().decode(Ollama.TagsResponse.self, from: tags).models.map(\.name) == ["echo"])
        for id in [ModelRecord.privateCloudComputeID, ModelRecord.builtInID, "echo"] {
            let (status, reply) = try await h.send(h.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
                model: id, messages: [OpenAI.Message(role: "user", content: "local control")], stream: false)))
            if id == "echo" {
                #expect(status == 200)
                #expect(try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: reply).choices.first?.message.content?.text == "local control")
            } else {
                #expect(status == 404)
                #expect(try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: reply).error.type == "model_not_found")
            }
        }
    }
}
