import Foundation

/// Consumes the marker `OpenAskIntent` leaves when the "Ask Pocketd" control
/// is tapped.
///
/// A thin, app-side wrapper around `AskLaunchRequest` rather than a second
/// copy of it: that type has to compile into the widget extension too, since
/// it is what the control writes, so it stays in `App/Shared` and stays
/// Foundation-only. This is the one place in the app that reads it back,
/// mirroring how the shell reads `IntentInbox` for a Siri question.
@MainActor
enum AskLaunch {
    typealias Mode = AskLaunchRequest.Mode

    /// Takes the marker and clears it, so a scene that becomes active twice
    /// does not focus the composer twice for one tap. `nil` when no control
    /// or Action Button launch is waiting.
    static func take() -> Mode? {
        AskLaunchRequest.take()
    }
}
