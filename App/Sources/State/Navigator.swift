import Observation
import SwiftUI

/// The four things this app is.
///
/// Four and not five, and the names are the user's rather than the
/// implementation's: v1 shipped Abilities / Server / Models / Chat / Settings,
/// which is a list of subsystems. Today / Ask / Routines / You is a list of
/// reasons to open the app.
///
/// Lifted out of `RootView` because it is no longer that view's private state:
/// a chip on Today hands a question to Ask, a card on Today opens a route
/// inside You, and a notification tap lands on Routines. Every one of those is
/// a write to `Navigator.tab` from somewhere that cannot see `RootView`.
enum AppTab: Hashable, CaseIterable {
    case today, ask, routines, you
}

extension AppTab {
    /// For the accessibility label. The tab bar itself has no text — see
    /// `FloatingTabBar`.
    var title: String {
        switch self {
        case .today: "Today"
        case .ask: "Ask"
        case .routines: "Routines"
        case .you: "You"
        }
    }

    /// Outline symbols, regular weight. Nothing here is `.fill`: a filled
    /// glyph in a bar where one item is already marked by a capsule behind it
    /// says the same thing twice and makes the unselected ones look disabled.
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .ask: "bubble.left.and.bubble.right"
        case .routines: "clock.arrow.circlepath"
        case .you: "person"
        }
    }
}

/// Everywhere inside You that is its own screen.
///
/// Pushed onto the You tab's `NavigationStack` rather than presented, because
/// they are all places rather than interruptions — you go to Brain, you do
/// something, you come back — and a sheet that can push further is a stack
/// wearing a disguise.
enum YouRoute: Hashable {
    /// The model, under the only word for it a person who has never heard
    /// "model" can use.
    case brain
    /// Hugging Face search, one level below Brain.
    case addBrain
    /// The LAN server, under what it is for rather than what it is.
    case devices
    case deskMode
    /// What leaves this phone.
    case privacy
    case settings
    case diagnostics
}

extension YouRoute: Identifiable {
    var id: Self { self }

    /// Whether this route's screen still brings a `NavigationStack` of its own.
    ///
    /// Not a style question — it is a crash. Pushing a view that contains its
    /// own `NavigationStack` onto a stack whose path is bound to `[YouRoute]`
    /// traps inside SwiftUI: `NavigationColumnState.boundPathChange` writes the
    /// new stack back through the binding, cannot represent the nested
    /// controller as a `YouRoute`, and the `try!` in there kills the app. Found
    /// by tapping "Brain" in the simulator; it takes the whole process down,
    /// not just the screen.
    ///
    /// So those five are presented instead of pushed, and `Navigator` decides
    /// which is which rather than every caller remembering. Each one goes back
    /// to being a push the moment its own workstream removes the inner stack —
    /// delete the case from this list and the row becomes a `NavigationLink`
    /// again.
    var bringsOwnNavigationStack: Bool {
        switch self {
        case .brain, .addBrain, .devices, .privacy, .settings:
            true
        case .deskMode, .diagnostics:
            false
        }
    }
}

/// A question handed from one tab to another.
///
/// A value rather than a `String?` on the model, and it carries `send` for the
/// reason the two cases are genuinely different: a suggestion chip means "ask
/// this now", and a "Remind me to…" chip means "start this sentence and let me
/// finish it". A single draft string cannot say which.
///
/// `Identifiable` so a second identical question still arrives: tapping the
/// same chip twice is two requests, and an `onChange` keyed on the text alone
/// would swallow the second.
struct AskHandoff: Identifiable, Equatable {
    let id = UUID()
    var draft: String
    var send: Bool
}

/// Where the app is, and the only thing allowed to move it.
///
/// One observable object in the environment rather than a `(AppTab) -> Void`
/// threaded through every view. The closure worked while there were five tabs
/// and one destination; it stops working the moment a screen needs to push two
/// levels into another tab, because a closure cannot express "and then".
///
/// `@MainActor` because every property here is read during a SwiftUI update.
@MainActor
@Observable
final class Navigator {
    /// Where a returning launch lands.
    ///
    /// Today, and that is the whole thesis of v2 in one line: the first thing
    /// anyone sees is their own day, not a socket and not a list of files.
    var tab: AppTab = .today

    /// The You tab's stack. Owned here rather than by the view so that a
    /// "Choose a brain" button on Today can leave someone two levels deep in
    /// You without Today knowing what a `NavigationStack` is.
    var youPath: [YouRoute] = []

    /// A You route that is presented rather than pushed.
    ///
    /// Not in the original design, and it is here because of a crash rather
    /// than a preference — see `YouRoute.bringsOwnNavigationStack`. It goes
    /// away, along with that property, when the last legacy screen loses its
    /// inner `NavigationStack`.
    var youSheet: YouRoute?

    /// A question waiting for the Ask tab to pick it up.
    ///
    /// Not written straight into `AppModel.draft`, because handing over a
    /// question is a navigation event with a destination, and because `send`
    /// has nowhere to live on a string.
    var askHandoff: AskHandoff?

    init() {}

    /// Select a tab.
    func go(_ tab: AppTab) {
        self.tab = tab
    }

    /// Put a question in Ask, and go there.
    ///
    /// `send: false` leaves it in the box with the cursor after it, which is
    /// what a half-sentence like "Remind me to…" needs.
    func ask(_ draft: String, send: Bool = false) {
        askHandoff = AskHandoff(draft: draft, send: send)
        tab = .ask
    }

    /// Open a route inside You, from anywhere.
    ///
    /// Resets the stack rather than appending to it. Arriving at Brain from a
    /// card on Today should leave one screen behind it, not whatever the
    /// person was last looking at three days ago.
    ///
    /// Push or present is decided here and not by the caller, because getting
    /// it wrong crashes the app rather than looking wrong — see
    /// `YouRoute.bringsOwnNavigationStack`.
    func openYou(_ route: YouRoute) {
        tab = .you
        if route.bringsOwnNavigationStack {
            youPath = []
            youSheet = route
        } else {
            youSheet = nil
            youPath = [route]
        }
    }

    /// Take the pending question, if there is one.
    ///
    /// Clearing on read rather than on consumption, for the reason
    /// `IntentInbox` does the same: a scene that becomes active twice must not
    /// ask the same thing twice.
    func takeAskHandoff() -> AskHandoff? {
        defer { askHandoff = nil }
        return askHandoff
    }
}
