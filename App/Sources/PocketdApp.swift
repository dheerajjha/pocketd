import PocketdKit
import SwiftUI
import UIKit

@main
struct PocketdApp: App {
    /// The app exists for two things that have to happen before launch
    /// finishes, and SwiftUI's `App` has no hook that early. See `AppDelegate`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    /// Where the app is. Owned here rather than by `RootView` so that it
    /// survives the view being torn down and rebuilt — which happens every time
    /// onboarding finishes, desk mode ends, or the scene is restored.
    @State private var navigator = Navigator()
    /// Pocketd Pro. Made with the app because its App Store listener has to be
    /// running from launch; see `ProStore`.
    @State private var pro = ProStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(navigator)
                .environment(pro)
                .task {
                    #if DEBUG
                    // A screenshot run says where it wants to start before
                    // anything renders. Whole call inside `#if DEBUG`; see `YouStage`.
                    YouStage.selectTabIfRequested(navigator)
                    SystemModelProbe.runIfRequested()
                    #endif
                    await model.bootstrap()
                }
                // "Use from your laptop" is Pro, and the switch only asks when
                // it is turned on. A server left on from before — a TestFlight
                // build, a refund — would otherwise come back by itself at every
                // launch. Once the App Store has answered and the answer is no,
                // it goes off and stays off until someone turns it on again.
                .task(id: [pro.hasChecked, pro.isPro]) {
                    guard pro.hasChecked, !pro.isPro, model.serverShouldRun else { return }
                    await model.stopServer()
                }
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
                #if DEBUG
                .componentGalleryIfRequested() // -pocketd.gallery: Design/Gallery/ComponentGallery.swift
                .proSheetIfRequested(pro) // -pocketd.proSheet: Views/Pro/ProGate.swift
                #endif
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

    /// A brain download finished while Pocketd was suspended or closed.
    ///
    /// iOS relaunches the app to hand over the file, and the handover only
    /// happens once the download session is rebuilt under the identifier iOS
    /// names — `BackgroundDownloads.handleEvents` does that and calls iOS back
    /// when the last event is delivered. Without this method the bytes sat in
    /// the system's care until the next time somebody opened the app, and a
    /// brain that had finished downloading in a pocket was still "downloading"
    /// on the lock screen.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // UIKit calls this on the main thread and wants the handler called on
        // it too; the Kit hops back to main before calling, so handing the
        // non-Sendable handler across is safe.
        nonisolated(unsafe) let finish = completionHandler
        BackgroundDownloads.handleEvents(forSession: identifier) { finish() }
    }
}
