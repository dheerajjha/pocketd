import Foundation
import Testing
@testable import PocketdKit

@Suite("Private Cloud Compute failures")
struct AppleCloudFailureTests {
    @Test("approaching the limit can still answer; reaching it carries Apple's reset")
    func preflight() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppleCloudFailure(blocking: .available) == nil)
        #expect(AppleCloudFailure(blocking: .approachingLimit) == nil)
        #expect(AppleCloudFailure(blocking: .notReady) == .notReady)
        #expect(AppleCloudFailure(blocking: .unavailable) == .unavailable)
        #expect(AppleCloudFailure(blocking: .limitReached(reset: reset)) == .limitReached(reset: reset))
        let known = InferenceError.privateCloud(.limitReached(reset: reset))
        let unknown = InferenceError.privateCloud(.limitReached(reset: nil))
        let when = reset.formatted(date: .abbreviated, time: .shortened)
        #expect(known.localizedDescription.contains(when))
        #expect(InferenceError.privateCloud(.limitReached(reset: reset), afterWrite: true).localizedDescription.contains(when))
        #expect(unknown.localizedDescription.contains("reset"))
        #expect(known.detail == unknown.detail)
    }

    @Test("a failed cloud narration does not imply that its write was undone", arguments: [
        AppleCloudFailure.network, .refused, .limitReached(reset: nil), .timedOut, .contextExceeded
    ])
    func change(_ failure: AppleCloudFailure) {
        let after = InferenceError.privateCloud(failure, afterWrite: true)
        #expect(after.localizedDescription.contains("Check your calendar or reminders"))
        #expect(!after.suggestsNewConversation)
        #expect(after.localizedDescription != InferenceError.privateCloud(failure).localizedDescription)
        #expect(after.detail == failure.diagnosticCode)
    }

    @Test("a backend string cannot masquerade as a typed cloud failure")
    func bounded() {
        let offline = InferenceError.privateCloud(.network).localizedDescription
        #expect(offline.contains("internet connection"))
        #expect(InferenceError.backend(offline).localizedDescription != offline)
        #expect(InferenceError.privateCloud(.refused).localizedDescription.contains("declined"))
    }
}
