import SwiftUI

/// Which tab is showing. Lifted out of TabView's own state so an empty state
/// can send someone where it is telling them to go — an instruction naming a
/// destination with no way to reach it is the definition of feeling stuck.
enum AppTab: Hashable {
    case server, models, chat, settings
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .server

    var body: some View {
        if model.needsOnboarding {
            // Ahead of desk mode and the tabs both: there is nothing useful
            // behind this yet, and a tab bar under an intro invites someone to
            // tap into a screen the intro is about to explain.
            OnboardingView(finish: { tab = $0 })
                .transition(.opacity)
        } else if model.deskMode {
            DeskModeView()
                .transition(.opacity)
        } else {
            // Above the tabs rather than inside one of them: a download is the
            // one thing here that outlives the screen that started it.
            VStack(spacing: 0) {
                DownloadBanner()
                TabView(selection: $tab) {
                    Tab("Server", systemImage: "network", value: AppTab.server) {
                        ServerView(goTo: { tab = $0 })
                    }
                    Tab("Models", systemImage: "shippingbox", value: AppTab.models) { ModelsView() }
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: AppTab.chat) {
                        ChatView(goTo: { tab = $0 })
                    }
                    Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
                }
            }
        }
    }
}
