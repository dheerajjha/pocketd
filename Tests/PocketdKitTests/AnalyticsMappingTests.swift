import Testing
import Foundation
@testable import PocketdKit

@Suite("Analytics mapping")
struct AnalyticsMappingTests {

    @Test("the phone talking to itself is not an external client")
    func loopbackIsNotExternal() {
        // The event this guards answers the only question that distinguishes
        // this product from a local chatbot. The phone serves its own /chat
        // page as a network client — deliberately, since privileging it would
        // be a security hole — so counting loopback would inflate exactly the
        // number someone will quote.
        #expect(AnalyticsMapping.isExternal(clientAddress: "127.0.0.1") == false)
        #expect(AnalyticsMapping.isExternal(clientAddress: "::1") == false)
        #expect(AnalyticsMapping.isExternal(clientAddress: "localhost") == false)
        #expect(AnalyticsMapping.isExternal(clientAddress: "0:0:0:0:0:0:0:1") == false)
        #expect(AnalyticsMapping.isExternal(clientAddress: "  ::1  ") == false, "whitespace must not defeat it")
        #expect(AnalyticsMapping.isExternal(clientAddress: "LOCALHOST") == false, "case must not defeat it")

        #expect(AnalyticsMapping.isExternal(clientAddress: "192.168.1.42"))
        #expect(AnalyticsMapping.isExternal(clientAddress: "10.0.0.7"))

        // Unknown is not external. Guessing yes would count a request we
        // cannot attribute as evidence for the headline claim.
        #expect(AnalyticsMapping.isExternal(clientAddress: nil) == false)
        #expect(AnalyticsMapping.isExternal(clientAddress: "") == false)
    }

    @Test("dialect comes from the path we served, not from the client")
    func dialectFromPath() {
        #expect(AnalyticsMapping.dialect(path: "/v1/chat/completions") == .openai)
        #expect(AnalyticsMapping.dialect(path: "/v1/models") == .openai)
        #expect(AnalyticsMapping.dialect(path: "/api/chat") == .ollama)
        #expect(AnalyticsMapping.dialect(path: "/api/version") == .ollama)
        // Neither surface: /health is a reachability probe and should not be
        // counted as a client using the API at all.
        #expect(AnalyticsMapping.dialect(path: "/health") == nil)
        #expect(AnalyticsMapping.dialect(path: "/setup") == nil)
        #expect(AnalyticsMapping.dialect(path: "/chat") == nil)
    }

    @Test("ram is a bucket, not a measurement")
    func ramBuckets() {
        // Buckets because the question is "do 4 GB phones fail to load 3B
        // models", which a bucket answers, and an exact byte count narrows a
        // device further than the question needs.
        #expect(AnalyticsMapping.ramClass(bytes: 3 * 1_073_741_824) == "3gb")
        #expect(AnalyticsMapping.ramClass(bytes: 4 * 1_073_741_824) == "4gb")
        #expect(AnalyticsMapping.ramClass(bytes: 6 * 1_073_741_824) == "6gb")
        #expect(AnalyticsMapping.ramClass(bytes: 8 * 1_073_741_824) == "8gb")
        #expect(AnalyticsMapping.ramClass(bytes: 12 * 1_073_741_824) == "12gb")
        #expect(AnalyticsMapping.ramClass(bytes: 16 * 1_073_741_824) == "16gb_plus")
        // Never empty, whatever it is handed.
        #expect(AnalyticsMapping.ramClass(bytes: 0).isEmpty == false)
    }

    @Test("no error's own text survives the mapping")
    func errorsBecomeBoundedReasons() {
        // The guarantee that matters: whatever an error says, what leaves is a
        // case name. A URLError's userInfo carries the signed CDN URL and the
        // entire resume blob, and this app has already put that on a screen.
        let leaky = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "https://cdn-lfs.hf.co/repos/secret?X-Amz-Signature=deadbeef",
            NSURLErrorFailingURLStringErrorKey: "https://cdn-lfs.hf.co/repos/secret"
        ])
        let reason = AnalyticsMapping.downloadReason(for: leaky)
        #expect(reason == .timedOut)
        #expect(reason.rawValue.contains("http") == false || reason.rawValue == "http_error")
        #expect(reason.rawValue.contains("cdn") == false)
        #expect(reason.rawValue.contains("Signature") == false)

        #expect(AnalyticsMapping.downloadReason(for: ModelStoreError.insufficientDisk(needed: 1, free: 0)) == .insufficientDisk)
        #expect(AnalyticsMapping.downloadReason(for: ModelStoreError.insufficientMemory(model: "x")) == .insufficientMemory)
        #expect(AnalyticsMapping.downloadReason(for: ModelStoreError.httpStatus(404)) == .httpError)
        #expect(AnalyticsMapping.downloadReason(for: ModelStoreError.incompleteDownload(model: "x", expected: 2, actual: 1)) == .incompleteBytes)

        #expect(AnalyticsMapping.loadReason(for: ModelStoreError.insufficientMemory(model: "x")) == .outOfMemory)
        #expect(AnalyticsMapping.loadReason(for: ModelStoreError.notInstalled("x")) == .fileMissing)

        // And an error nobody anticipated still produces a case, not a string.
        struct Surprise: Error { let detail = "user typed this" }
        #expect(AnalyticsMapping.downloadReason(for: Surprise()) == .other)
        #expect(AnalyticsMapping.loadReason(for: Surprise()) == .other)
    }
}
