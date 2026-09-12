import SwiftUI
import UIKit

@main
struct PocketdApp: App {
    /// The app exists for two things that have to happen before launch
    /// finishes, and SwiftUI's `App` has no hook that early. See `AppDelegate`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    // Both the socket and the resident model are torn down by
                    // suspension — one by iOS, one by us — so every transition
                    // matters and the handler owns which is which.
                    Task { await model.handleScenePhase(phase) }

                    // Leaving the screen is the last moment this process is
                    // guaranteed to run, and a refresh request is consumed by
                    // the wake-up it causes. Topping it up here is what keeps
                    // the schedule alive for somebody who opens the app once a
                    // week: without it, background refresh stops after the first
                    // fire and every watcher waits for a foreground visit.
                    if phase == .background {
                        BackgroundWake.scheduleNextRefresh()
                    }
                }
        }
    }
}

/// Two callbacks, both of which are worthless a moment later.
///
/// This app had no delegate at all, and the two things that put one back are
/// both deadlines rather than preferences:
///
/// - `BGTaskScheduler.register` has to have claimed every permitted identifier
///   before `didFinishLaunchingWithOptions` returns. Registering afterwards is
///   an error, and registering the same identifier twice terminates the app, so
///   it cannot be done lazily from the screen that happens to need it.
/// - `UNUserNotificationCenter.delegate` has to be installed before the same
///   moment, or a tap that *launched* the app — the case the whole prompt half
///   of the feature depends on — is delivered before anything is listening and
///   is lost.
///
/// Nothing else belongs here. In particular nothing here asks the user for
/// anything: this app opens without a single permission prompt, and both calls
/// below are registrations, not requests.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundWake.register()
        NotificationCentre.shared.attach()
        return true
    }
}
