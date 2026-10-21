import Foundation

/// A request to open straight into the conversation, left for the app by a tap on
/// the "Ask Pocketd" control.
///
/// `IntentInbox` cannot serve this the way it serves Siri: that inbox is an
/// in-memory slot, safe only because `AskPocketdIntent` is compiled solely
/// into the app target and its `perform()` runs inside this process. The "Ask
/// Pocketd" control is declared by the widget extension — a separate process
/// with its own memory space — and Control Center, the Lock Screen and the
/// Action Button all invoke it through that extension, not through the app.
/// `OpenAskIntent.perform()` has to assume it may be running on the other
/// side of that boundary, so the marker has to survive a process hop: a few
/// bytes in the App Group's shared UserDefaults, the same container
/// `SchedulePublicationStore` writes to for the same reason in the other
/// direction.
///
/// One marker rather than a queue, like `IntentInbox`'s single slot: a second
/// tap before the app is foregrounded is impatience, not a second request.
enum AskLaunchRequest {

    /// How the tap wants the conversation to open. One case today — the control
    /// asks for the microphone — kept as a type so a future control that asks
    /// for the keyboard has a spelling to use.
    enum Mode: String, Codable, Sendable {
        case voice
    }

    /// How long a tap is worth acting on.
    ///
    /// The marker waits for the main screen, and the main screen does not
    /// exist while the intro is up: a tap made then used to open the
    /// microphone whenever the intro finished, minutes later, with nobody
    /// expecting it. A minute covers the slowest cold launch.
    static let freshness: TimeInterval = 60

    private struct Marker: Codable, Sendable {
        var mode: Mode
        var at: Date
    }

    /// Duplicated from `SchedulePublication.appGroup` rather than imported.
    /// This file is compiled directly into `PocketdWidgets`, which links
    /// neither PocketdKit nor the app target — see the note at the bottom of
    /// SchedulePublication.swift — so an `import PocketdKit` here would build
    /// for the app and fail for the extension. Both targets and both
    /// entitlements files must agree on this literal.
    private static let appGroup = "group.dev.pocketd.app"
    private static let key = "pocketd.askLaunch"

    /// `nil` when the App Group entitlement is missing, which is not
    /// hypothetical — see `SchedulePublicationStore.init()`. Failing soft
    /// here means a control that could not leave word behind still opens the
    /// app, rather than the extension crashing on a tap.
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Leaves the marker for the app to collect on its next launch.
    static func leave(mode: Mode) {
        guard let defaults, let data = try? JSONEncoder().encode(Marker(mode: mode, at: Date())) else { return }
        defaults.set(data, forKey: key)
    }

    /// Takes the marker and clears it, so a scene that becomes active twice
    /// does not act on one tap twice.
    static func take(now: Date = Date()) -> Mode? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        guard let marker = try? JSONDecoder().decode(Marker.self, from: data),
              now.timeIntervalSince(marker.at) < freshness
        else { return nil }
        return marker.mode
    }
}
