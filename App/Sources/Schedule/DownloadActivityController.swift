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

    /// How long a failed `Activity.request` is left alone before this file
    /// will try again for the same transfer.
    ///
    /// AUDIT FINDING (UX audit, on a simulator): `sync` used to call `end()`
    /// and then `Activity.request` again on EVERY progress tick whenever the
    /// activity ActivityKit reported back did not match the transfer this
    /// file expected. `request`'s result was `try?`-discarded, so a request
    /// that kept failing — Live Activities off in Settings, unavailable, or
    /// just the simulator, which does not support them — never stopped
    /// mismatching: the very next progress tick tried again, and the one
    /// after that, for the life of the download. Measured effect: the widget
    /// extension was relaunched roughly 50 times a second for the whole
    /// download — benign when Live Activities work, a battery and thermal
    /// bug on every download when they do not. `lastRequestFailure` plus
    /// this interval are the fix: try once, remember that it failed, and
    /// leave it alone for 30 seconds. Do not "simplify" this back out.
    private static let retryInterval: TimeInterval = 30

    /// The last time `Activity.request` failed, keyed by transfer id.
    ///
    /// Per id rather than one flag: `FileDownloader`'s session is serial, so
    /// at most one transfer is ever live at once (see `sync`), but a resumed
    /// download or a later, different one gets its own id and deserves its
    /// own first attempt rather than inheriting an unrelated failure from a
    /// transfer that is long gone.
    private static var lastRequestFailure: [String: Date] = [:]

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
            // The activity on screen already belongs to this transfer:
            // update it in place. Never end-and-re-request on this branch —
            // that used to happen on every tick and is the bug described on
            // `retryInterval` above.
            Task {
                guard let activity = Activity<DownloadActivityAttributes>.activities.first else { return }
                await activity.update(content(state))
            }
        } else {
            reconcile(id: live.id, name: live.record.displayName, state: state)
        }
    }

    /// Ends whatever activity is showing and asks for one that matches this
    /// transfer — but only when that is actually worth attempting.
    ///
    /// `sync` reaches this on a progress tick, which fires many times a
    /// second while a transfer is running. The two guards below are what
    /// keep that from becoming the retry storm described on `retryInterval`.
    private static func reconcile(
        id: String,
        name: String,
        state: DownloadActivityAttributes.ContentState
    ) {
        // Asking is not the same as being allowed, and it is worth knowing
        // BEFORE paying for an `end()` + `request` round trip rather than
        // after: the user can switch Live Activities off for this app in
        // Settings, or this build can simply be running somewhere — the
        // simulator — that does not support them. Either way, no request.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Already tried and failed for this exact transfer recently: leave
        // it alone rather than asking again on the next tick.
        if let last = lastRequestFailure[id], Date().timeIntervalSince(last) < retryInterval {
            return
        }

        end()
        start(named: name, id: id, state: state)
    }

    private static func content(
        _ state: DownloadActivityAttributes.ContentState
    ) -> ActivityContent<DownloadActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(freshness))
    }

    private static func start(
        named name: String,
        id: String,
        state: DownloadActivityAttributes.ContentState
    ) {
        do {
            _ = try Activity.request(
                attributes: DownloadActivityAttributes(modelName: name),
                content: content(state)
            )
            // A later mismatch for this id (a rename, or ActivityKit losing
            // track of it) deserves a fresh attempt, not a memory of this
            // success standing in the way.
            lastRequestFailure[id] = nil
        } catch {
            lastRequestFailure[id] = Date()
            // `code` is a short, stable identifier chosen right here — never
            // `error` or its description. `DiagnosticLog` exists to be
            // copied off the device, and what `Activity.request` throws is
            // not this file's call to make safe to send.
            DiagnosticLog.record(.failure(area: .widgets, code: "liveActivityRequestFailed"))
        }
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
