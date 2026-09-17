import StoreKit
import SwiftUI

/// The three things the app can be showing, and the shell that holds the
/// fourth.
///
/// `AppTab` used to live here as `RootView`'s private idea of where it was. It
/// now lives in `Navigator`, because a tab is no longer this view's secret: a
/// chip on Today hands a question to Ask, a card on Today pushes two levels
/// into You, and a Siri phrase lands on Ask before this view has rendered once.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.needsOnboarding {
            // Ahead of desk mode and the shell both: there is nothing useful
            // behind this yet, and a tab bar under an intro invites someone to
            // tap into a screen the intro is about to explain.
            //
            // Untouched from v1 on purpose — the onboarding rebuild is its own
            // workstream, and a half-restyled intro is worse than either end
            // of the change.
            OnboardingViewBridge()
                .transition(.opacity)
        } else if model.deskMode {
            DeskModeView()
                .transition(.opacity)
        } else {
            Shell()
                .transition(.opacity)
        }
    }
}

/// Hands the old intro a destination in the new vocabulary.
///
/// A separate view so `RootView` does not have to hold a `Navigator` it only
/// needs in one branch, and so the seam where v1's `(AppTab) -> Void` meets the
/// `Navigator` is one line that a later workstream deletes.
private struct OnboardingViewBridge: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        OnboardingView(finish: { navigator.go($0) })
    }
}

// MARK: - The shell

/// Four tabs in a ZStack, a floating capsule over them, and a download banner
/// above everything.
///
/// Not a `TabView`. The system bar is 83pt of opaque chrome that ends every
/// screen with a hard line, and these screens are meant to run off the bottom
/// of the phone. There is no system tab bar to hide here, because none is
/// created. How each tab keeps clear of the capsule is the note on `selected`.
private struct Shell: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    /// Apple's own prompt. There is no way to ask for it outside a view, and no
    /// way to find out whether it was shown — see `reviewPromptShown()`.
    @Environment(\.requestReview) private var requestReview

    @State private var toasts = ToastCenter()
    /// Whether the keyboard is up, so the strip kept clear for the floating bar
    /// can give way to it. There is no environment value for this, and the
    /// alternative — letting the reserve stand — leaves an empty band between
    /// the composer and the keys.
    @State private var keyboardIsUp = false

    var body: some View {
        @Bindable var navigation = navigator

        ZStack(alignment: .bottom) {
            Color.pd.canvas.ignoresSafeArea()

            selected

            FloatingTabBar(selection: $navigation.tab)
                .padding(.horizontal, PDMetric.tabBarSideMargin)
                .padding(.bottom, PDMetric.tabBarBottomInset)
                // The bar belongs to the phone, not to the page: without this
                // it rides up on top of the keyboard and sits in the gap
                // between the composer and the keys, which is the one place on
                // Ask nobody is looking for it.
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        // Above the tabs rather than inside one of them: a download is the one
        // thing here that outlives the screen that started it. Slim, at the
        // top, and absent entirely when nothing is downloading.
        .overlay(alignment: .top) {
            DownloadBanner(goTo: { navigator.go($0) })
        }
        .environment(toasts)
        .toast(toasts)
        // A question left by `AskPocketdIntent`. Collected here and not in the
        // intent because `perform()` runs before this scene exists on a cold
        // launch, so there is nowhere to put it yet.
        //
        // On appearance AND on becoming active: the first covers a launch the
        // intent caused, the second covers the app already being in memory, and
        // a phrase said twice must not ask twice — which is why `take()` clears
        // the slot rather than reading it.
        .onAppear { collectIntentQuestion() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { collectIntentQuestion() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsUp = false
        }
        // A tap on the Today widget, or a Shortcut. `DeepLink` is the whole
        // parser and anything it does not recognise is `nil`, so an unknown
        // URL does nothing at all rather than landing somewhere surprising.
        .onOpenURL { url in
            guard let link = DeepLink(url: url) else { return }
            switch link {
            case .today: navigator.go(.today)
            case .ask: navigator.go(.ask)
            case .you: navigator.go(.you)
            }
        }
        // Asked from here rather than from the model, because a review request
        // is a SwiftUI environment action and only a view holds one. The model
        // decides WHEN — see `ReviewMoment` — and this is only the hand that
        // raises it.
        .onChange(of: model.wantsReviewPrompt) { _, wants in
            guard wants else { return }
            requestReview()
            model.reviewPromptShown()
        }
    }

    /// The selected tab's content.
    ///
    /// Only the selected one is built. A `ZStack` of all four with opacity
    /// would keep their scroll positions, and would also run four screens'
    /// `task` modifiers at once — including the one that starts a generation.
    ///
    /// Ask is not wrapped in a `NavigationStack` here because it still brings
    /// its own; wrapping it would stack two navigation bars on one screen. Its
    /// rebuild drops the inner one and this switch grows a wrapper.
    ///
    /// It also ends above the capsule rather than scrolling under it, and that
    /// is not a preference. It is a bottom-anchored screen — a composer — and a
    /// `safeAreaInset` applied from out here does not reach past its own
    /// `NavigationStack`: the first build put the chat composer half off the
    /// bottom of the phone, under the tab bar. A real spacer in a `VStack`
    /// cannot be ignored by anything inside it.
    ///
    /// Today, Routines and You do scroll under, and own that inset themselves —
    /// see `PDMetric.tabBarClearance` where their scroll views apply it.
    @ViewBuilder
    private var selected: some View {
        switch navigator.tab {
        case .today:
            NavigationStack {
                TodayView()
            }
        case .ask:
            reservingTabBar {
                AskView()
            }
        case .routines:
            RoutinesView()
        case .you:
            YouTab()
        }
    }

    /// Lays a screen out above the floating bar rather than behind it.
    ///
    /// Nothing is reserved while the keyboard is up: the capsule stays at the
    /// bottom of the phone underneath it — see `ignoresSafeArea(.keyboard)`
    /// above — so holding the strip open would only push the composer a bar's
    /// height clear of the keys it is sitting on.
    private func reservingTabBar<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
            Color.clear.frame(height: keyboardIsUp ? 0 : PDMetric.tabBarReserve)
        }
    }

    /// Puts a question from Siri or Shortcuts into Ask.
    ///
    /// Sent only when a model is actually resident. Without one, `send()` is a
    /// no-op that would leave somebody staring at their own words in a text
    /// field with no reply and no explanation — so the question is left in the
    /// box, ready to send, and Ask's own empty state says what is missing.
    private func collectIntentQuestion() {
        // A tap on the "Ask Pocketd" control, independent of any Siri
        // question below — see AskLaunch.
        if AskLaunch.take() != nil {
            navigator.go(.ask)
            model.askComposerFocusRequested = true
        }
        guard let question = IntentInbox.take() else { return }
        navigator.ask(question, send: model.loadedModelID != nil)
    }

}

// MARK: - You's stack

/// The You tab, with its stack bound to the `Navigator`.
///
/// Its own view so the path binding lives next to the stack that uses it, and
/// so that `openYou(_:)` from a card on Today lands somewhere real rather than
/// setting a property nothing is watching.
private struct YouTab: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var navigation = navigator

        NavigationStack(path: $navigation.youPath) {
            YouView()
                .navigationDestination(for: YouRoute.self) { route in
                    YouRouteView(route: route)
                }
        }
    }
}
