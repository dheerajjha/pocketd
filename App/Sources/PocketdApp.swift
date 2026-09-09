import SwiftUI

@main
struct PocketdApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    // The listening socket does not survive suspension, so
                    // coming back to the foreground has to put it back.
                    if phase == .active {
                        Task { await model.reconcileAfterForeground() }
                    }
                }
        }
    }
}
