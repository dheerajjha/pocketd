import ActivityKit
import Foundation
import PocketdKit

/// Starts, updates and ends the download Live Activity.
///
/// Driven from one place — `AppModel.transfers`'s `didSet` — rather than from
/// the seven sites that mutate it. Those seven are the download's whole state
/// machine (start, progress, finish, pause, fail, and two cancels), and hooking
/// each one is how you end up with an Activity that survives the one path
/// somebody forgot. Reconciling the whole dictionary means the Activity is a
/// function of the state rather than of the transitions.
@MainActor
enum DownloadActivityController {

    // No stored `Activity`, and that is a correctness decision before it is a
    // concurrency one.
    //
    // `Activity.update` and `.end` are `@concurrent`, so handing them an
    // activity held on the main actor is sending a main-actor value to another
    // executor — Swift 6 rejects it, and it is the same region-isolation shape
    // that `RefreshHandle` exists for. Resolving the activity INSIDE the task
    // that awaits it means the value is born in that region and never crosses.
    //
    // The reason this is a better design rather than an appeasement: a stored
    // reference is wrong across a relaunch. `FileDownloader` sets
    // `sessionSendsLaunchEvents`, so the system relaunches this app to deliver
    // download events — at which point a static would be nil while the activity
    // is still live on the lock screen, and the next progress callback would
    // start a SECOND one. `Activity.activities` is the system's own list and
    // survives that, so the app adopts what is already there.

    /// How long a number stays believable once the app stops updating it.
    ///
    /// A background `URLSession` keeps transferring while the app is suspended,
    /// but `didWriteData` does not fire into a suspended process — the callbacks
    /// queue and arrive on relaunch. So the bytes are real and the DISPLAYED
    /// bytes freeze, which is the one dishonest state this feature can reach: a
    /// confident 34% that is actually 60%.
    ///
    /// ActivityKit has the answer built in. Past `staleDate` the system renders
    /// the activity as out of date, so a frozen number reads as "this is old"
    /// instead of as a stall. Two minutes because that is long enough to cover
    /// ordinary scrolling and short enough that a locked phone in a pocket does
    /// not spend an hour asserting a stale percentage.
    private static let freshness: TimeInterval = 120

    static func sync(_ transfers: [String: ModelTransfer]) {
        // Only what is actually moving. `FileDownloader`'s session is serial, so
        // at most one transfer is ever running; anything else in the dictionary
        // is queued, finished or failed, and none of those is a thing to put on
        // a lock screen.
        let live = transfers.values.first { transfer in
            switch transfer.state {
            case .running, .paused: true
            case .waiting, .stopping, .finished, .failed: false
            }
        }

        guard let live else { return end() }

        let state: DownloadActivityAttributes.ContentState
        switch live.state {
        case let .running(progress):
            state = .init(receivedBytes: progress.receivedBytes,
                          totalBytes: progress.totalBytes, isPaused: false)
        case .paused:
            // Keep the last known bytes rather than zeroing them. A pause that
            // resets the bar to the start looks like the download was thrown
            // away, which is exactly what pausing is supposed to not do.
            let last = live.lastProgress
            state = .init(receivedBytes: last?.receivedBytes ?? 0,
                          totalBytes: last?.totalBytes ?? 0, isPaused: true)
        default:
            return end()
        }

        // Reading a String out of the activity is not sending the activity.
        let existing = Activity<DownloadActivityAttributes>.activities.first?.attributes.modelName
        if existing == live.record.displayName {
            Task {
                guard let activity = Activity<DownloadActivityAttributes>.activities.first else { return }
                await activity.update(content(state))
            }
        } else {
            end()
            start(named: live.record.displayName, state: state)
        }
    }

    private static func content(
        _ state: DownloadActivityAttributes.ContentState
    ) -> ActivityContent<DownloadActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(freshness))
    }

    private static func start(
        named name: String,
        state: DownloadActivityAttributes.ContentState
    ) {
        // Asking is not the same as being allowed. The user can switch Live
        // Activities off for this app in Settings, and `request` throws if they
        // have; there is nothing to tell them about it, because they are the
        // one who turned it off.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // The result is discarded deliberately: the system's list is what this
        // file reads back, so keeping a copy would just be a second answer that
        // can disagree with it.
        _ = try? Activity.request(
            attributes: DownloadActivityAttributes(modelName: name),
            content: content(state)
        )
    }

    private static func end() {
        // Every one of them, not just the one this launch started. An activity
        // orphaned by a crash or a previous launch is otherwise stuck on the
        // lock screen until iOS times it out hours later.
        Task {
            for activity in Activity<DownloadActivityAttributes>.activities {
                // `.immediate`, not the default. The default leaves a finished
                // download on the lock screen for up to four hours, and a
                // completed transfer has a destination in the app — the point
                // is to get the user there, not to keep saying it is over.
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
