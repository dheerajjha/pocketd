import Foundation

/// Where a scheduled task is being asked to run, and therefore what it is
/// physically able to do there.
///
/// This type exists because of one hardware fact that decides the whole design
/// of scheduled tasks on this app, and that is invisible in every API involved:
///
/// **llama.cpp inference cannot run while the app is in the background.** Every
/// layer runs on Metal, and a backgrounded app's Metal command buffers are
/// refused by the system — `MTLCommandBuffer` comes back with
/// `MTLCommandBufferError.notPermitted` rather than with a slower answer.
/// Background GPU access exists, but only on iPad M3 and better; on every
/// iPhone this app targets there is no version of "think about it quietly while
/// the screen is off". `BGAppRefreshTask` gets its thirty seconds of CPU and
/// the model still will not load.
///
/// So the honest split is not "urgent versus deferrable", it is "needs the GPU
/// versus does not", and the context a task wakes up in is half of that
/// decision. Nothing here is a preference or a policy knob; each value is a
/// physical statement about one of the states this app can be in.
public enum ExecutionContext: String, Sendable, Codable, CaseIterable {

    /// A `BGAppRefreshTask`. Seconds of CPU, no GPU, no user.
    case backgroundRefresh

    /// The app is on screen with somebody looking at it.
    case foreground

    /// Desk Mode: on screen, on a charger, serving, and left alone for hours.
    ///
    /// A first-class execution context rather than a special case of
    /// `.foreground`, because it is the only state this app has where
    /// *unattended inference is legal*. The app is technically in the
    /// foreground, so Metal works and a model can think; nobody is waiting on
    /// the screen, so a thirty-second generation costs nothing; and the phone
    /// is plugged in, so the battery argument against it does not apply. Every
    /// other product in this space treats "phone on a charger" as a screensaver.
    /// Here it is the runtime.
    case deskMode

    /// The user tapped the notification for a task that could not think when it
    /// was due. This is where the thinking actually happens for most prompt
    /// tasks, and the app is in the foreground by definition when it does.
    case notificationResponse

    /// Whether a model can run here at all. See the type's note: false in
    /// exactly one case, and for a reason no amount of scheduling can work
    /// around.
    public var mayRunModel: Bool {
        switch self {
        case .backgroundRefresh: false
        case .foreground, .deskMode, .notificationResponse: true
        }
    }

    /// Whether there is a person watching this happen.
    ///
    /// Used for output, not for permission: an unattended run has nowhere to
    /// stream to and no one to answer a follow-up, so its result is written to
    /// the run record and announced, rather than printed into a live view.
    public var isAttended: Bool {
        switch self {
        case .backgroundRefresh, .deskMode: false
        case .foreground, .notificationResponse: true
        }
    }
}
