#if DEBUG
import Foundation
import PocketdKit

/// A download that is not happening, for the screens that have to be looked at.
///
/// The one state this app's most important card exists for cannot be produced
/// on a simulator: `com.apple.nsurlsessiond` does not vend its XPC service
/// there, so every background `URLSessionDownloadTask` fails at creation with
/// `NSCocoaErrorDomain 4097` and the card goes straight from "no brain" to
/// "the download failed". Both of those are real states worth reviewing, and
/// neither is the one somebody spends four minutes looking at.
///
/// So the progress, the estimate and the Cancel link get staged from a launch
/// argument. Same shape and same reasons as `DemoSeed`: `#if DEBUG` around the
/// whole file so there is not even a dead branch in a Release build, a launch
/// argument rather than a build setting so the same binary still behaves
/// normally, and nothing in the app's own UI can reach it.
///
///     xcrun simctl launch <udid> dev.pocketd.app -pocketd.stageDownload running
///
/// Values: `running`, `paused`, `failed`, `waiting`, `cancelled`.
enum OnboardingDownloadStage {

    /// What this launch asked to see, if anything.
    private static var requested: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-pocketd.stageDownload"),
              arguments.index(after: position) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: position)]
    }

    /// The model the staged transfer pretends to be fetching: whichever starter
    /// the catalogue lists first, so the name and the byte count on screen are
    /// a real model's rather than an invented one's.
    private static var record: ModelRecord? {
        ModelCatalog.all.min { $0.totalDownloadBytes < $1.totalDownloadBytes }
    }

    static var transfer: ModelTransfer? {
        guard let requested, let record else { return nil }
        let received = Int64(Double(record.totalDownloadBytes) * 0.34)
        let progress = DownloadProgress(
            modelID: record.id,
            receivedBytes: received,
            totalBytes: record.totalDownloadBytes
        )
        let state: ModelTransfer.State? = switch requested {
        case "running": .running(progress)
        case "waiting": .waiting
        case "paused": .paused("Paused — Wi-Fi went away. It will pick up where it stopped.")
        case "failed": .failed("The download failed.")
        // `cancelled` is `cancelledRecord`'s business, not a transfer state.
        default: nil
        }
        guard let state else { return nil }
        return ModelTransfer(record: record, state: state, lastProgress: progress)
    }

    /// The state after Cancel, which cannot be reached by cancelling anything
    /// here: a staged transfer is a value, so it never stops being active and
    /// the card would keep drawing its progress.
    static var cancelledRecord: ModelRecord? {
        requested == "cancelled" ? record : nil
    }

    /// 2.1 MB/s, which on a 386 MB file leaves the padded estimate at a couple
    /// of minutes — a number worth reading rather than a round one.
    static var pace: AppModel.DownloadPace? {
        guard requested == "running", let record else { return nil }
        let remaining = Double(record.totalDownloadBytes) * 0.66
        return AppModel.DownloadPace(
            bytesPerSecond: 2_100_000,
            secondsRemaining: remaining / 2_100_000
        )
    }
}
#endif
