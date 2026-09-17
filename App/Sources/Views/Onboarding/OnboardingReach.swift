import Foundation
import Network
import Observation

/// Whether the connection about to be charged a gigabyte is one somebody pays
/// for by the megabyte.
///
/// The audit of v1 found a first run that started a 1.1 GB download with no
/// warning and no way out; on a slow link that was twenty-six minutes, and on a
/// metered one it was somebody's data allowance. This is the one sentence that
/// costs nothing to say and is the difference between a download somebody chose
/// and one that happened to them.
///
/// `isExpensive` rather than "is the interface Wi-Fi", deliberately. A phone
/// tethered to a hotspot reports `.wifi` and is still the bill; a simulator on a
/// Mac reports `.wiredEthernet` and is not. `isExpensive` is the answer to the
/// question actually being asked, and it is the flag iOS itself uses to decide
/// what to defer.
///
/// No permission and no Info.plist key: path monitoring reports the state of
/// the interface and touches no network. That is why it is not
/// `NWBrowser`/Bonjour, which is what `NSLocalNetworkUsageDescription` covers.
@MainActor
@Observable
final class OnboardingReach {
    /// True only when there is a connection and iOS says it is metered.
    /// Starts false, so a screen never accuses a Wi-Fi user of being on data
    /// during the half second before the first path arrives.
    private(set) var isOnMobileData = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.pocketd.reach")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Only the two booleans cross the boundary. `NWPath` carries
            // interface objects that have no business on the main actor.
            let metered = path.status == .satisfied && path.isExpensive
            Task { @MainActor in self?.isOnMobileData = metered }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
