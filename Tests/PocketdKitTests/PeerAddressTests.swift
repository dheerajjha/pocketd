import Foundation
import Testing
@testable import PocketdKit

@Suite("Client origin cannot be forged")
struct PeerAddressTests {

    /// FlyingFox's `remoteIPAddress` returns `X-Forwarded-For` in preference to
    /// the socket peer. That is right behind a proxy you run and wrong for a
    /// phone listening directly on a LAN: the header is just a string the
    /// caller picked. Using it meant anyone on the network could appear in the
    /// request log as the phone itself.
    @Test("a forged X-Forwarded-For does not become the logged client")
    func forwardedForIsIgnored() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        var request = try harness.request("GET", "/v1/models")
        request.setValue("10.9.9.9", forHTTPHeaderField: "X-Forwarded-For")
        let (status, _) = try await harness.send(request)
        #expect(status == 200)

        let entries = await harness.server.log.all()
        // /v1/models is not logged; drive something that is.
        _ = entries

        var chat = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo",
            messages: [OpenAI.Message(role: "user", content: "hi")],
            stream: false
        ))
        chat.setValue("10.9.9.9", forHTTPHeaderField: "X-Forwarded-For")
        _ = try await harness.send(chat)

        let logged = await harness.server.log.all()
        let entry = try #require(logged.first { $0.path == "/v1/chat/completions" })
        #expect(entry.clientAddress != "10.9.9.9", "the audit trail must record the socket, not a header")
        #expect(entry.clientAddress == "127.0.0.1")
    }

    @Test("a forged header does not misattribute a failed pairing attempt")
    func pairingFailureAttribution() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        _ = await harness.server.openPairing()
        var request = try harness.request(
            "POST", "/pair",
            json: InferenceServer.PairRequest(code: "000000"),
            key: .some(nil)
        )
        request.setValue("10.9.9.9", forHTTPHeaderField: "X-Forwarded-For")
        _ = try await harness.send(request)

        let snapshot = await harness.server.pairing.snapshot()
        // The Server tab shows this address to the user. Letting an attacker
        // choose it lets them pin their attempts on a neighbour's device.
        #expect(snapshot.lastFailureAddress != "10.9.9.9")
    }
}
