import SwiftUI

/// Which tab is showing. Lifted out of TabView's own state so an empty state
/// can send someone where it is telling them to go — an instruction naming a
/// destination with no way to reach it is the definition of feeling stuck.
enum AppTab: Hashable {
    case abilities, server, models, chat, settings
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    /// Where a returning launch lands.
    ///
    /// Was `.server`, which is the line that made this a server product: the
    /// first thing anyone saw, every time, was a socket. The direction is
    /// assistant first and server second — `OnboardingView` already argues it
    /// at length, and the tab bar was still saying the opposite.
    ///
    /// Abilities rather than Chat, because it is the one screen that is useful
    /// in every state the app can be in. Chat with nothing loaded is a dead end
    /// that sends you to Models; Abilities says what the assistant can do,
    /// shows anything that is quietly broken — a refused permission, a server
    /// that did not come back up — and carries the door to Chat when there is
    /// something to ask. A server user loses nothing either: the server's live
    /// state and its stop button are a row on it.
    ///
    /// Only ever the *initial* value. A fresh install goes through onboarding,
    /// which picks its own destination.
    @State private var tab: AppTab = .abilities

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
                DownloadBanner(goTo: { tab = $0 })
                TabView(selection: $tab) {
                    // A fifth tab, and not casually. iOS collapses a tab bar at
                    // five, so this is paid for rather than free, and the two
                    // cheaper options were both worse:
                    //
                    // An entry point from Chat and Settings puts the one screen
                    // that says what this app is *behind* the two screens that
                    // assume you already know. Settings is where these three
                    // abilities have been hiding all along — moving them a
                    // section higher inside it changes nothing about whether
                    // anybody finds them.
                    //
                    // Replacing a tab was the other option, and there is no
                    // spare one: Models is where a model comes from, Chat is
                    // the product, Settings holds the server's configuration,
                    // and Server is the second act rather than a dead one.
                    //
                    // So the bar grows by one, and the new tab goes first —
                    // leftmost is what an app says it is when you look at the
                    // bar, and what this app is, is the assistant that can read
                    // what is on your phone.
                    Tab("Abilities", systemImage: "sparkles", value: AppTab.abilities) {
                        AbilitiesView(goTo: { tab = $0 })
                    }
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
