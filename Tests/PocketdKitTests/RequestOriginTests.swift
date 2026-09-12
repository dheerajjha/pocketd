import Foundation
import Testing
@testable import PocketdKit

@Suite("Request origin")
struct RequestOriginTests {

    @Test("a request with no origin set is treated as untrusted")
    func failsClosed() {
        // The default matters more than it looks: a call site that forgets to
        // set the origin must get the path with no access to personal data.
        let request = GenerationRequest(modelID: "m", messages: [.user("hi")])
        #expect(request.origin.mayReachPersonalData == false)
    }

    @Test("only the app's own chat may reach personal data")
    func onlyOnDevice() {
        #expect(RequestOrigin.onDeviceChat.mayReachPersonalData)
        #expect(RequestOrigin.network(host: "127.0.0.1", port: 5000).mayReachPersonalData == false)
    }

    @Test("loopback over the network is still the network")
    func loopbackIsNotPrivileged() {
        // The /chat page the phone serves is indistinguishable from curl at the
        // route layer. Privileging loopback would hand every local process the
        // user's calendar.
        #expect(RequestOrigin.network(host: "127.0.0.1", port: 1).mayReachPersonalData == false)
        #expect(RequestOrigin.network(host: "::1", port: 1).mayReachPersonalData == false)
    }

    @Test("a tool body reads back the origin the caller bound")
    func taskLocalPropagates() async {
        await ToolContext.$origin.withValue(.onDeviceChat) {
            #expect(ToolContext.origin == .onDeviceChat)
        }
        // ...and it does not leak outside the binding.
        #expect(ToolContext.origin.mayReachPersonalData == false)
    }

    @Test("the refusal is a sentence a model can repeat verbatim")
    func refusalReadsWell() {
        #expect(ToolContext.refusal.hasSuffix("."))
        #expect(ToolContext.refusal.contains("iPhone"))
    }
}

@Suite("Tool-capable models")
struct ToolCapabilityTests {

    @Test("only models whose template was trained for tools are marked capable")
    func catalogueIsHonest() throws {
        let qwen = try #require(ModelCatalog.model(withID: "qwen3-1.7b"))
        #expect(qwen.declaredCapabilities.tools == .yes)
        #expect(qwen.declaredCapabilities.ollamaCapabilities.contains("tools"))

        // SmolLM2's template is plain ChatML with no mention of tools. Attaching
        // them would produce a model that never calls one.
        let smol = try #require(ModelCatalog.model(withID: "smollm2-360m"))
        #expect(smol.declaredCapabilities.tools == .no)
        #expect(smol.declaredCapabilities.ollamaCapabilities.contains("tools") == false)
    }

    @Test("unverified models default to unknown, not capable")
    func unknownIsTheDefault() throws {
        let llama = try #require(ModelCatalog.model(withID: "llama-3.2-3b"))
        #expect(llama.declaredCapabilities.tools == .unknown)
        // Unknown must not advertise the capability.
        #expect(llama.declaredCapabilities.ollamaCapabilities.contains("tools") == false)
    }

    @Test("an older manifest decodes with tool support unknown")
    func migration() throws {
        let old = #"{"sizeBytes":1,"quantization":"q","filename":"f","id":"i","displayName":"d","contextLength":2048,"repoID":"r","license":"l","parameters":"p"}"#
        let record = try JSONDecoder().decode(ModelRecord.self, from: Data(old.utf8))
        #expect(record.toolSupport == .unknown)
    }
}

@Suite("A scheduled run is not a person")
struct ScheduledOriginTests {
    @Test("a scheduled task reaches personal data, deliberately")
    func scheduledMayReachPersonalData() {
        // The user wrote the prompt on this device and chose the time. This
        // is a decision, not an inheritance, which is why it has its own case
        // rather than borrowing one.
        let origin = RequestOrigin.scheduledTask(id: UUID())
        #expect(origin.mayReachPersonalData)
        #expect(RequestOrigin.onDeviceChat.mayReachPersonalData)
        #expect(RequestOrigin.network(host: "192.168.1.42", port: 51_000).mayReachPersonalData == false)
    }

    @Test("a scheduled run does not claim someone is watching")
    func nobodyIsWatchingAScheduledRun() {
        // The distinction that pays for the separate case. Anything that wants
        // to prompt, confirm, or assume a person will read the answer has to
        // ask this rather than mayReachPersonalData — and at 7am, nobody is.
        #expect(RequestOrigin.scheduledTask(id: UUID()).hasSomeoneWatching == false)
        #expect(RequestOrigin.onDeviceChat.hasSomeoneWatching)
        #expect(RequestOrigin.network(host: "10.0.0.2", port: 1).hasSomeoneWatching == false)
    }

    @Test("a scheduled run never impersonates the chat tab")
    func noForgery() {
        // The regression this exists for was real and shipped for one commit:
        // PromptHandoff set origin = .onDeviceChat so the personal-data tools
        // would answer it. That works, and it silently converts
        // mayReachPersonalData from a fact derived from the accepted socket
        // into a claim the caller makes about itself — the exact forgeable
        // property this enum was written to avoid.
        //
        // Nothing caught it. RequestOriginTests only asserted that .network is
        // refused, so a case that wrongly claimed to be a person passed every
        // test in the suite.
        let id = UUID()
        let handoff = PromptHandoff(taskID: id, title: "Morning briefing", prompt: "What is on today?", firing: Date())
        #expect(handoff.origin != .onDeviceChat, "a scheduled run must not claim to be a human at the keyboard")
        #expect(handoff.origin == .scheduledTask(id: id))
        #expect(handoff.origin.hasSomeoneWatching == false)
    }

    @Test("the log says which scheduled task, without becoming a UUID")
    func loggingIsReadable() {
        let id = UUID()
        let line = RequestOrigin.scheduledTask(id: id).loggingDescription
        #expect(line.hasPrefix("scheduled "))
        #expect(line.count < 24, "this lands in a request log a person reads")
        #expect(line.contains(id.uuidString.prefix(8)))
    }
}
