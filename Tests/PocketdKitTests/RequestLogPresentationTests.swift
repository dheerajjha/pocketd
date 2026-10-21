import Foundation
import Testing
@testable import PocketdKit

@Suite("Request log, as the phone says it")
struct RequestLogPresentationTests {
    private func entry(_ path: String, _ status: Int) -> RequestLogEntry {
        RequestLogEntry(method: "POST", path: path, clientAddress: "192.168.1.9", statusCode: status)
    }

    @Test("both dialects of a question read the same")
    func questions() {
        for path in ["/v1/chat/completions", "/v1/completions", "/api/chat", "/api/generate"] {
            #expect(entry(path, 200).requestKind == "Question")
            #expect(entry(path, 200).outcome == "Answered")
        }
    }

    @Test("pairing says paired or wrong code, never a status number")
    func pairing() {
        #expect(entry("/pair", 200).outcome == "Paired")
        #expect(entry("/pair", 403).outcome == "Wrong code")
        #expect(entry("/pair", 403).outcomeIsTrouble)
        #expect(entry("/v1/models", 403).outcome == "Refused")
    }

    @Test("every refusal the server can send has a word")
    func refusals() {
        #expect(entry("/v1/chat/completions", 401).outcome == "Wrong key")
        #expect(entry("/api/chat", 503).outcome == "Busy or paused")
        #expect(entry("/v1/chat/completions", 413).outcome == "Too long")
        #expect(entry("/v1/embeddings", 501).outcome == "Not supported")
        #expect(entry("/v1/embeddings", 501).requestKind == "Unsupported request")
        #expect(entry("/v1/nope", 404).outcome == "Not found")
        #expect(entry("/v1/chat/completions", 500).outcome == "Failed")
    }

    @Test("a device that hung up mid-answer is said plainly, and is not trouble")
    func hungUp() {
        let left = entry("/api/chat", InferenceServer.clientClosedRequest)
        #expect(left.outcome == "Stopped early")
        #expect(left.outcomeIsTrouble == false)
    }

    @Test("a reply still streaming has no outcome yet")
    func inFlight() {
        #expect(entry("/api/chat", 0).outcome == nil)
        #expect(entry("/api/chat", 0).outcomeIsTrouble == false)
    }

    @Test("listing brains, by any of its paths, is one kind")
    func listings() {
        for path in ["/v1/models", "/v1/models/qwen3-1.7b", "/api/tags", "/api/ps", "/api/show", "/api/catalogue"] {
            #expect(entry(path, 200).requestKind == "Brain list", "\(path)")
        }
        #expect(entry("/health", 200).requestKind == "Status check")
        #expect(entry("/", 200).requestKind == "Chat page")
        #expect(entry("/somewhere", 404).requestKind == "Other request")
    }

    @Test("no word on this list is a path, a code or a vendor")
    func noMachinery() {
        let paths = ["/v1/chat/completions", "/pair", "/", "/health", "/api/pull", "/api/search", "/v1/models",
                     "/v1/embeddings", "/nope"]
        let statuses = [0, 200, 400, 401, 403, 404, 413, 499, 500, 501, 503]
        for path in paths {
            for status in statuses {
                let words = [entry(path, status).requestKind, entry(path, status).outcome ?? ""].joined(separator: " ")
                #expect(words.contains("/") == false)
                #expect(words.rangeOfCharacter(from: .decimalDigits) == nil)
                #expect(words.lowercased().contains("openai") == false)
                #expect(words.lowercased().contains("gpt") == false)
            }
        }
    }
}
