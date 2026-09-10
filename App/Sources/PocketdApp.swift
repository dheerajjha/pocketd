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
                    // Both the socket and the resident model are torn down by
                    // suspension — one by iOS, one by us — so every transition
                    // matters and the handler owns which is which.
                    Task { await model.handleScenePhase(phase) }
                }
        }
    }
}
