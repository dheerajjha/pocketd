import AppIntents
import Foundation

/// The action behind the "Ask Pocketd" control — the same intent runs
/// whether the tap came from Control Center, the Lock Screen's bottom
/// buttons, or the Action Button.
///
/// It carries no question, unlike `AskPocketdIntent`. A control is a single
/// tap with no room for a parameter, a Siri dialog or a Shortcuts input; all
/// it can ask for is the composer, ready. `AskLaunch` turns that into a
/// routed tab and a focus request on the other side of the launch — see
/// `AskLaunchRequest` for why the hand-off is an App Group marker rather
/// than a call straight into `IntentInbox`.
///
/// Compiled into both the app and `PocketdWidgets` from `App/Shared`. The
/// widget extension needs the type to vend the control at all; the app needs
/// it too, in case `openAppWhenRun` runs `perform()` after the app is already
/// foregrounded rather than before.
struct OpenAskIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Pocketd"

    static let description = IntentDescription(
        "Opens Pocketd straight into the Ask tab, ready for a question."
    )

    /// Required, and for the same reason `AskPocketdIntent` gives: the model
    /// lives in the app's process, under a memory budget no extension gets
    /// near, so opening the app is the only honest way this ends in an
    /// answer.
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AskLaunchRequest.leave(mode: .voice)
        return .result()
    }
}
