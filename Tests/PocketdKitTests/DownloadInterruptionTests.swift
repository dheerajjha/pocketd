import Foundation
import Testing
@testable import PocketdKit

struct DownloadInterruptionTests {
    @Test("an interrupted connection explains the network problem, not a foreground requirement")
    func connectionMessage() {
        let interruption = DownloadInterruption.from(URLError(.networkConnectionLost))
        #expect(interruption == .connectionLost)
        #expect(interruption?.message == "Paused — the connection was interrupted. Tap to resume.")
        #expect(interruption?.message.contains("stay open") == false)
    }

    @Test("offline and disallowed mobile data retain an actionable resume message")
    func offlineMessage() {
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed] {
            let interruption = DownloadInterruption.from(URLError(code))
            #expect(interruption == .offline)
            #expect(interruption?.message == "Paused — no network. Tap to resume.")
        }
    }
}
