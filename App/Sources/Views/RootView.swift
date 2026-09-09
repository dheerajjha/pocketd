import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.deskMode {
            DeskModeView()
                .transition(.opacity)
        } else {
            TabView {
                Tab("Server", systemImage: "network") { ServerView() }
                Tab("Models", systemImage: "shippingbox") { ModelsView() }
                Tab("Chat", systemImage: "bubble.left.and.bubble.right") { ChatView() }
                Tab("Settings", systemImage: "gearshape") { SettingsView() }
            }
        }
    }
}
