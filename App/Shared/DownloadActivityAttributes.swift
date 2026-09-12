import ActivityKit
import Foundation

/// The shape of the download Live Activity, shared by the app and the widget.
///
/// Not in `PocketdKit` despite being the same kind of cross-target type as
/// `SchedulePublication`: ActivityKit is iOS-only and the kit builds for macOS
/// to run its tests, so one `import ActivityKit` in there costs the whole test
/// suite. Compiled into both targets from `App/Shared` instead.
///
/// A download is the one thing this app does that deserves a Live Activity. It
/// is long — gigabytes over a phone's Wi-Fi — the user starts it deliberately,
/// and `FileDownloader` sets `sessionSendsLaunchEvents` on a background session,
/// so the bytes genuinely keep arriving after the app leaves the screen. Every
/// other candidate fails that last test: the server's socket is torn down on
/// suspend, and `autoOffloadInBackground` unloads the model, so a SERVING
/// Activity would be false within seconds of being useful.
struct DownloadActivityAttributes: ActivityAttributes {

    /// What changes while it runs.
    struct ContentState: Codable, Hashable {
        var receivedBytes: Int64
        var totalBytes: Int64
        /// Paused by the user, or stalled waiting for a network the phone does
        /// not have. Rendered differently from progress, because a frozen bar
        /// with no explanation reads as a crash.
        var isPaused: Bool

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
        }
    }

    /// Fixed for the life of the activity. The model's own name, which came
    /// from a catalogue entry or from what the user typed into Hugging Face
    /// search — not from anything read off the device.
    var modelName: String
}
