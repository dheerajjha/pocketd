import Foundation
import Testing
@testable import PocketdKit

@Suite("Pairing payload encoding")
struct EncodingProbeTests {

    /// The setup page parses this in JavaScript, and the tests parse it with
    /// Swift's own decoder — which is exactly the trap. A payload Foundation
    /// round-trips can still be rejected by every other JSON parser, and the
    /// only consumer that matters here is a browser.
    @Test("the pairing payload is JSON any parser accepts")
    func payloadIsPortableJSON() throws {
        let snippets = ClientSnippets.all(
            baseURL: URL(string: "http://192.168.1.31:11434")!,
            apiKey: "pk-test",
            model: "smollm2-360m"
        )
        let payload = InferenceServer.PairedResponse(
            baseURL: "http://192.168.1.31:11434",
            apiKey: "pk-test",
            model: "smollm2-360m",
            snippets: snippets.map {
                InferenceServer.PairedSnippet(
                    id: $0.id, title: $0.title, language: $0.language,
                    body: $0.body, filename: $0.filename, note: $0.note
                )
            }
        )
        let data = try JSONEncoder().encode(payload)

        // JSONSerialization is stricter than JSONDecoder and closer to what a
        // browser's JSON.parse will accept.
        #expect(throws: Never.self) {
            _ = try JSONSerialization.jsonObject(with: data)
        }

        let text = String(decoding: data, as: UTF8.self)
        // Report the offending region rather than just failing.
        if (try? JSONSerialization.jsonObject(with: data)) == nil {
            Issue.record("unparseable around: \(String(text.dropFirst(200).prefix(80)).debugDescription)")
        }
    }
}
