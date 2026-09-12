import SwiftUI

/// Which tab is showing. Lifted out of TabView's own state so an empty state
/// can send someone where it is telling them to go — an instruction naming a
/// destination with no way to reach it is the definition of feeling stuck.
enum AppTab: Hashable {
    case abilities, server, models, chat, settings

    /// Scheduled tasks, which is a destination and **not** a tab — `route(to:)`
    /// presents it rather than selecting it.
    ///
    /// It lives in this enum anyway, and that is the point: every screen in the
    /// app already takes a `(AppTab) -> Void`, so the schedule is one line away
    /// for any of them without a second routing type or a second closure
    /// threaded through views this change does not own. The Abilities list is
    /// where the permanent row for it belongs — see the handoff — and until that
    /// lands, `ScheduleBar` carries the entry point.
    case schedules
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

    @State private var showingSchedules = false

    var body: some View {
        if model.needsOnboarding {
            // Ahead of desk mode and the tabs both: there is nothing useful
            // behind this yet, and a tab bar under an intro invites someone to
            // tap into a screen the intro is about to explain.
            OnboardingView(finish: { route(to: $0) })
                .transition(.opacity)
        } else if model.deskMode {
            DeskModeView()
                .transition(.opacity)
        } else {
            // Above the tabs rather than inside one of them: a download is the
            // one thing here that outlives the screen that started it.
            VStack(spacing: 0) {
                DownloadBanner(goTo: { route(to: $0) })
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
                        AbilitiesView(goTo: { route(to: $0) })
                            // Scheduled tasks hang off Abilities, and as a bar
                            // rather than as a sixth tab.
                            //
                            // Five is the hard limit: iOS folds everything past
                            // the fifth tab into More, so a sixth does not cost
                            // a slot, it costs Settings — buried behind a
                            // disclosure list to make room for a screen most
                            // people visit weekly. The argument above for the
                            // fifth tab already spent the last one that was
                            // going.
                            //
                            // Abilities rather than Chat because the sentence
                            // this screen exists to say is "what the assistant
                            // on this phone can do", and running on a schedule
                            // is one of those things — Chat is the same
                            // assistant answering *now*, and a schedule is not
                            // a conversation. It also puts the bar on the tab a
                            // returning launch lands on, which is what makes it
                            // discoverable at all.
                            //
                            // A bar and not a plain link because it carries
                            // state the user cannot get anywhere else: the next
                            // firing, and a count of prompt-task results
                            // waiting to be written because the app was closed
                            // when they came due. That last one is the fact
                            // this whole feature has to keep visible.
                            //
                            // The row belongs inside the Abilities list itself;
                            // that file is another change's, so the handoff
                            // names the line. When it lands, this modifier and
                            // `ScheduleBar` both go.
                            .safeAreaInset(edge: .bottom) {
                                ScheduleBar { showingSchedules = true }
                            }
                    }
                    Tab("Server", systemImage: "network", value: AppTab.server) {
                        ServerView(goTo: { route(to: $0) })
                    }
                    Tab("Models", systemImage: "shippingbox", value: AppTab.models) { ModelsView() }
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: AppTab.chat) {
                        ChatView(goTo: { route(to: $0) })
                    }
                    Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
                }
            }
            // On the container rather than on the Abilities tab, so that a route
            // to the schedule from anywhere — the bar today, an Abilities row or
            // a notification tap later — presents the same sheet and does not
            // tear it down when the selected tab changes underneath it.
            .sheet(isPresented: $showingSchedules) {
                SchedulesView(goTo: { destination in
                    showingSchedules = false
                    route(to: destination)
                })
            }
        }
    }

    /// Sends the app somewhere, whether or not that somewhere is a tab.
    ///
    /// Switched exhaustively rather than defaulted, so that a destination added
    /// to `AppTab` later has to say here how it is reached instead of silently
    /// selecting a tab that does not exist — which `TabView` renders as a blank
    /// screen with no way back.
    private func route(to destination: AppTab) {
        switch destination {
        case .schedules:
            showingSchedules = true
        case .abilities, .server, .models, .chat, .settings:
            // Dismissed first: a tab change behind a sheet moves a screen the
            // user cannot see, which is the shape of every "the button did
            // nothing" report.
            showingSchedules = false
            tab = destination
        }
    }
}
