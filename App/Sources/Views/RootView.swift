import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Server", systemImage: "network") { ServerView() }
            Tab("Models", systemImage: "shippingbox") { ModelsView() }
            Tab("Chat", systemImage: "bubble.left.and.bubble.right") { ChatView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
    }
}
