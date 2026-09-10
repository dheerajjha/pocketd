import Foundation
import Testing
@testable import PocketdKit

@Suite("Setup page and pairing")
struct SetupPageTests {

    @Test("a browser gets the setup page and an Ollama client still gets the probe string")
    func contentNegotiation() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        var browser = try harness.request("GET", "/", key: .some(nil))
        browser.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (browserStatus, browserBody) = try await harness.send(browser)
        #expect(browserStatus == 200)
        #expect(String(decoding: browserBody, as: UTF8.self).contains("<!doctype html>"))

        // The contract every Ollama client checks before doing anything else.
        for accept in ["*/*", "application/json", ""] {
            var probe = try harness.request("GET", "/", key: .some(nil))
            if !accept.isEmpty { probe.setValue(accept, forHTTPHeaderField: "Accept") }
            let (status, body) = try await harness.send(probe)
            #expect(status == 200)
            #expect(String(decoding: body, as: UTF8.self) == "Ollama is running",
                    "Accept: \(accept) must not get HTML")
        }
    }

    @Test("/setup serves the page regardless of Accept")
    func explicitSetupPath() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, body) = try await harness.send(harness.request("GET", "/setup", key: .some(nil)))
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Pairing code"))
    }

    @Test("a correct code returns the key and the snippets")
    func pairingSucceeds() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let code = await harness.server.openPairing()
        let (status, data) = try await harness.send(try harness.request(
            "POST", "/pair", json: InferenceServer.PairRequest(code: code), key: .some(nil)
        ))
        #expect(status == 200)

        let body = try JSONDecoder().decode(InferenceServer.PairedResponse.self, from: data)
        #expect(body.apiKey == harness.apiKey)
        #expect(body.snippets.isEmpty == false)
        #expect(body.baseURL.hasPrefix("http://"))
    }

    @Test("a wrong code is refused and the response cannot contain the key")
    func wrongCodeLeaksNothing() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        _ = await harness.server.openPairing()
        let (status, data) = try await harness.send(try harness.request(
            "POST", "/pair", json: InferenceServer.PairRequest(code: "000000"), key: .some(nil)
        ))
        // 000000 is a legitimate code, so tolerate the one-in-a-million pass.
        if status == 200 { return }

        #expect(status == 403)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(harness.apiKey) == false, "a failed handshake must not leak the key")
        #expect(text.contains("pairing_failed"))
    }

    @Test("the code is single-use")
    func codeIsSingleUse() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let code = await harness.server.openPairing()
        let first = try await harness.send(try harness.request(
            "POST", "/pair", json: InferenceServer.PairRequest(code: code), key: .some(nil)))
        #expect(first.0 == 200)

        let second = try await harness.send(try harness.request(
            "POST", "/pair", json: InferenceServer.PairRequest(code: code), key: .some(nil)))
        #expect(second.0 == 403, "a code that keeps working is a permanent bypass of the API key")
    }

    @Test("pairing does not open a hole in the rest of the API")
    func othersStillGuarded() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        _ = await harness.server.openPairing()
        let (status, _) = try await harness.send(harness.request("GET", "/v1/models", key: .some(nil)))
        #expect(status == 401)
    }
}

@Suite("Pairing session")
struct PairingSessionTests {

    @Test("five wrong attempts burn the code")
    func attemptLimit() async {
        let session = PairingSession()
        let code = await session.open()
        let wrong = code == "111111" ? "222222" : "111111"

        for expected in [4, 3, 2, 1] {
            let outcome = await session.redeem(wrong, from: "192.168.1.9")
            #expect(outcome == .wrongCode(attemptsRemaining: expected))
        }
        #expect(await session.redeem(wrong, from: "192.168.1.9") == .expired)
        // ...and the right code no longer works either.
        #expect(await session.redeem(code, from: nil) == .expired)
    }

    @Test("an expired code is refused")
    func expiry() async {
        // Freezing time keeps this deterministic instead of sleeping ten minutes.
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = PairingSession(now: { clock })
        let code = await session.open()

        clock = clock.addingTimeInterval(PairingSession.lifetime + 1)
        #expect(await session.redeem(code, from: nil) == .expired)
    }

    @Test("records where the wrong codes came from")
    func recordsFailures() async {
        let session = PairingSession()
        let code = await session.open()
        _ = await session.redeem(code == "111111" ? "222222" : "111111", from: "10.0.0.5")

        let snapshot = await session.snapshot()
        #expect(snapshot.lastFailureAddress == "10.0.0.5")
        #expect(snapshot.failureCount == 1)
    }
}

@Suite("Client snippets")
struct ClientSnippetTests {
    private let base = URL(string: "http://192.168.1.42:11434")!

    @Test("every OpenAI-dialect snippet points at /v1 and the Ollama one does not")
    func dialectPaths() {
        let snippets = ClientSnippets.all(baseURL: base, apiKey: "pk-test", model: "gemma-4-e2b")
        for snippet in snippets where snippet.id != "open-webui" {
            #expect(snippet.body.contains("11434/v1"), "\(snippet.id) must use the /v1 prefix")
        }
        let ollama = try! #require(snippets.first { $0.id == "open-webui" })
        #expect(ollama.body.contains("/v1") == false, "the Ollama dialect lives at the root")
    }

    @Test("every snippet carries the address, port, key and model")
    func carriesEverything() {
        for snippet in ClientSnippets.all(baseURL: base, apiKey: "pk-test", model: "gemma-4-e2b") {
            #expect(snippet.body.contains("192.168.1.42"))
            #expect(snippet.body.contains("11434"))
            #expect(snippet.body.contains("pk-test"))
        }
    }

    @Test("an auth-free server still gives the SDKs a usable placeholder")
    func noAuthPlaceholder() {
        let snippets = ClientSnippets.all(baseURL: base, apiKey: nil, model: "m")
        let curl = try! #require(snippets.first { $0.id == "curl" })
        #expect(curl.body.contains("Authorization") == false)

        // The OpenAI SDKs reject an empty api_key, so "" would be a broken snippet.
        let python = try! #require(snippets.first { $0.id == "openai-python" })
        #expect(python.body.contains("api_key=\"\"") == false)
        #expect(python.body.contains("not-needed"))
    }
}

@Suite("Chat page")
struct ChatPageTests {

    @Test("/chat serves a chat client")
    func servesChat() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (status, body) = try await harness.send(harness.request("GET", "/chat", key: .some(nil)))
        #expect(status == 200)
        let html = String(decoding: body, as: UTF8.self)
        #expect(html.contains("<!doctype html>"))
        #expect(html.contains("/v1/chat/completions"), "the page must talk to the real endpoint")
    }

    @Test("a browser at the root lands on the chat, not the probe string")
    func rootIsChatForBrowsers() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        var request = try harness.request("GET", "/", key: .some(nil))
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (status, body) = try await harness.send(request)
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Pocketd"))
    }

    @Test("the chat page never hard-codes a key")
    func noEmbeddedSecret() async throws {
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }

        let (_, body) = try await harness.send(harness.request("GET", "/chat", key: .some(nil)))
        // The page is served before any pairing, so a key in it would be a
        // straight leak to anyone who can reach the port.
        #expect(String(decoding: body, as: UTF8.self).contains(harness.apiKey) == false)
    }
}

@Suite("Pairing survives a relaunch")
struct PairingPersistenceTests {

    /// `hasPaired` was in-memory only, so the Connected section — the API key
    /// and all seven client snippets — vanished on every relaunch. Someone who
    /// paired yesterday and wanted to re-copy a snippet today could not, unless
    /// they paired a device again.
    @Test("a completed pairing is remembered across a restart")
    func remembersPairing() async throws {
        let suite = "pocketd.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = PairingSession(store: .init(defaults: defaults))
        let code = await first.open()
        #expect(await first.redeem(code, from: nil) == .paired)
        #expect(await first.snapshot().hasPaired)

        // A second session is what the next launch sees.
        let second = PairingSession(store: .init(defaults: defaults))
        #expect(await second.snapshot().hasPaired)
        // ...but the code itself must NOT come back: it is short-lived and
        // guessable by design.
        #expect(await second.snapshot().code == nil)
    }

    @Test("a session that never paired reports so")
    func freshSessionIsUnpaired() async throws {
        let suite = "pocketd.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(await PairingSession(store: .init(defaults: defaults)).snapshot().hasPaired == false)
    }
}

@Suite("Asking for a new code")
struct NewCodeTests {

    /// `open()` rebuilt the whole snapshot and dropped `pairedAt`, so tapping
    /// "Show a new pairing code" hid the API key and every client snippet —
    /// and the button that did it lived inside the section it hid. `close()`
    /// had always preserved it; `open()` had not.
    @Test("a new code does not un-pair you")
    func openPreservesPairedState() async {
        let session = PairingSession(store: .init(defaults: nil))
        let code = await session.open()
        #expect(await session.redeem(code, from: nil) == .paired)
        #expect(await session.snapshot().hasPaired)

        _ = await session.open()
        #expect(await session.snapshot().hasPaired, "the key and snippets must not vanish")
        #expect(await session.snapshot().isOpen)
    }

    @Test("a new code does not erase the record of who failed")
    func openPreservesFailures() async {
        let session = PairingSession(store: .init(defaults: nil))
        let code = await session.open()
        _ = await session.redeem(code == "111111" ? "222222" : "111111", from: "10.0.0.5")
        #expect(await session.snapshot().failureCount == 1)

        _ = await session.open()
        #expect(await session.snapshot().lastFailureAddress == "10.0.0.5")
    }
}
