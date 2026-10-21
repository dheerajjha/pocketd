import Observation
import SwiftUI

/// The four places a person can ask for by name.
///
/// No longer tabs. The tab bar is gone — one home, with everything else one
/// tap from it (spec §2) — but the four words survive as verbs, because "go to
/// Routines" is still how half the app asks to move: the header's ⏰, a deep
/// link, the intro's last step. What each one means now is on
/// `Navigator.go(_:)`.
enum AppTab: Hashable, CaseIterable {
    case today, ask, routines, you
}

/// The pages one level under Today: one per tile, and a routine's result.
///
/// Pushed rather than presented, because each is a place — the numbers behind a
/// tile, compared with your usual — and Back should land on the tile it came
/// from. A routine's result carries the routine's id rather than a copy of it,
/// so a sweep that settles a run while the page is open shows up on it.
enum DetailKind: Hashable {
    case day
    case reminders
    case sleep
    case activity
    case routineResult(UUID)
}

/// Everything the one stack can hold.
///
/// One element type for the whole app rather than a path per area, because
/// there is one stack now: Today is its root and every other screen is pushed
/// onto it, so "Brain, from a card on Today" and "Sleep, then You" are the same
/// kind of thing — a list of places — and `NavigationStack(path:)` wants that
/// list in one type.
///
/// You's pages ride in `youPage` rather than being flattened in here, so that
/// `YouRoute` stays the one switch `YouRouteView` covers, and a new page under
/// You does not touch anything that pushes Routines or a tile.
///
/// The conversation is not a route. It is a sheet over wherever you are; see
/// `Navigator.isAskPresented`.
enum Route: Hashable {
    case detail(DetailKind)
    case routines
    case you
    case youPage(YouRoute)
}

/// Everywhere under You that is its own screen.
///
/// Pushed rather than presented, because they are all places rather than
/// interruptions — you go to Brain, you do something, you come back — and a
/// sheet that can push further is a stack wearing a disguise.
enum YouRoute: Hashable {
    /// Both brains — built into iPhone, and the private download — under the
    /// only word for a model that a person who has never heard "model" can use.
    case brain
    /// "More brains": every catalogue brain and Hugging Face search, one level
    /// below Brain.
    case addBrain
    /// The technical detail behind Brain — quantisation, context, speed,
    /// sampling. One of the few screens where the jargon is allowed out.
    case brainAdvanced
    /// "Use from your laptop": the LAN server, under what it is for rather than
    /// what it is.
    case devices
    case deskMode
    /// What leaves this phone, as promises.
    case privacy
    /// The proof behind those promises — files, keys, byte counts,
    /// connections — one level under Privacy.
    case privacyDetails
    /// "Server settings".
    case settings
    /// "Assistant instructions", under Advanced.
    case instructions
    case diagnostics
}

extension YouRoute: Identifiable {
    var id: Self { self }
}

/// A question handed to the conversation from somewhere else.
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
/// One observable object in the environment rather than closures threaded
/// through every view: a screen often needs to move somewhere it cannot see —
/// a chip on a detail page asks a question in the conversation sheet, a notice
/// in that sheet opens Brain two levels down, a notification tap lands on a
/// routine's result — and a closure cannot say "and then".
///
/// The whole app is one `NavigationStack` rooted at Today, plus one sheet for
/// the conversation. `path` is the stack and `isAskPresented` is the sheet;
/// everything else here is a way of setting those two that reads as what the
/// caller meant.
///
/// `@MainActor` because every property here is read during a SwiftUI update.
@MainActor
@Observable
final class Navigator {
    /// The one stack. Empty is Today, which is the whole thesis of v2 in one
    /// line: the first thing anyone sees is their own day.
    var path: [Route] = []

    /// Whether the conversation sheet is up.
    ///
    /// A flag beside the stack rather than a route on it: the conversation is
    /// presented over wherever you are — Sleep, a routine's result — and closing
    /// it returns you there. A pushed conversation would spend that place's
    /// Back button on itself.
    var isAskPresented = false

    /// A question waiting for the conversation sheet to pick it up.
    ///
    /// Not written straight into `AppModel.draft`, because handing over a
    /// question is a navigation event with a destination, and because `send`
    /// has nowhere to live on a string.
    var askHandoff: AskHandoff?

    init() {}

    // MARK: - Moving

    /// Go to one of the four named places.
    ///
    /// - `.today` pops to the root and puts the sheet away: Today is home, and
    ///   asking for home means everything on top of it goes.
    /// - `.ask` presents the conversation over wherever you are, on the
    ///   conversation that is open.
    /// - `.routines` and `.you` push. If the place is already on the stack —
    ///   You, three levels under it — you are taken back to it rather than
    ///   handed a second copy, so Back still means what it says.
    ///
    /// Everything except `.ask` puts the sheet away, because a push under a
    /// sheet happens where nobody can see it.
    func go(_ tab: AppTab) {
        switch tab {
        case .today:
            isAskPresented = false
            path.removeAll()
        case .ask:
            isAskPresented = true
        case .routines:
            show(.routines)
        case .you:
            show(.you)
        }
    }

    /// Put a question in the conversation, and open it.
    ///
    /// `send: false` leaves it in the box with the cursor after it, which is
    /// what a half-sentence like "Remind me to…" needs. The sheet goes over the
    /// page that asked, so closing it lands back there.
    func ask(_ draft: String, send: Bool = false) {
        askHandoff = AskHandoff(draft: draft, send: send)
        isAskPresented = true
    }

    /// Open a page under You, from anywhere.
    ///
    /// Lands on You and then the page, so Back from Brain is You and Back from
    /// You is wherever this was called from — not whatever under You somebody
    /// was last looking at three days ago. From *inside* You, where Back should
    /// go to the page you were on, append to `path` instead.
    func openYou(_ route: YouRoute) {
        isAskPresented = false
        path = pathThroughYou + [.youPage(route)]
    }

    /// Push a page under Today: a tile's numbers, or a routine's result.
    ///
    /// A second tap on the same tile before the first push lands is one
    /// request, not two pages of Sleep.
    func open(_ detail: DetailKind) {
        isAskPresented = false
        guard path.last != .detail(detail) else { return }
        path.append(.detail(detail))
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

    // MARK: - Arriving from outside

    /// Lands a `pocketd://` link: a widget tap, a Shortcut, a link somebody was
    /// sent.
    ///
    /// Routines and You replace the stack rather than pushing onto it. A link
    /// arrives from outside the app, so whatever was on screen when the app was
    /// last left is not where the person came from, and Back should go home.
    /// Ask keeps the stack: the sheet goes over whatever is there, and closing
    /// it should not have thrown that away.
    func follow(_ link: DeepLink) {
        switch link {
        case .today: go(.today)
        case .ask: go(.ask)
        case .routines: land(on: .routines)
        case .you: land(on: .you)
        }
    }

    /// Lands a tap on a routine's notification. The model decides where (see
    /// `AppModel.takeRoutineTap()`); this only takes the person there, with
    /// Today one Back away for the same reason a link gets it.
    func follow(_ tap: RoutineTapDestination) {
        switch tap {
        case .today: go(.today)
        case let .result(id): land(on: .detail(.routineResult(id)))
        case .routines: land(on: .routines)
        }
    }

    // MARK: - Pieces

    /// Back to `route` if it is already on the stack, or push it.
    private func show(_ route: Route) {
        isAskPresented = false
        if let index = path.lastIndex(of: route) {
            path.removeSubrange(path.index(after: index)...)
        } else {
            path.append(route)
        }
    }

    /// Today, then `route`, and nothing else. For arrivals from outside.
    private func land(on route: Route) {
        isAskPresented = false
        path = [route]
    }

    /// The stack up to and including You, with You added if it is not there.
    private var pathThroughYou: [Route] {
        guard let you = path.lastIndex(of: .you) else { return path + [.you] }
        return Array(path[...you])
    }
}
