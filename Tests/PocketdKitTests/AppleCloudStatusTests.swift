import Foundation
import Testing
@testable import PocketdKit

@Suite("Apple cloud availability and quota")
struct AppleCloudStatusTests {
    @Test("Device readiness, warnings and an exhausted quota have different actions")
    func readiness() {
        for state in [AppleCloudStatus.unavailable, .notReady] {
            #expect(!state.isListed && !state.canChoose)
        }
        for state in [AppleCloudStatus.available, .approachingLimit] {
            #expect(state.isListed && state.canChoose)
        }
        let reached = AppleCloudStatus.limitReached(reset: nil)
        #expect(reached.isListed && !reached.canChoose)
        #expect(reached.statusLine.contains("local brain"))
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppleCloudStatus.limitReached(reset: reset).statusLine.contains(reset.formatted(date: .abbreviated, time: .shortened)))
    }

    @Test("The server model is never a local catalogue download or the resident on-device Apple model")
    func distinctProvider() {
        let cloud = ModelRecord.privateCloudCompute
        #expect(cloud.id != ModelRecord.builtInID && !cloud.isBuiltInBrain)
        #expect(ModelCatalog.model(withID: cloud.id) == nil)
        #expect(cloud.totalDownloadBytes == 0 && cloud.contextLength == 32_768)
        #expect(cloud.displayName == "Apple Private Cloud Compute")
    }
}
