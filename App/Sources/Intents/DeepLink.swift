import Foundation

/// Where a `pocketd://` URL is asking the app to go.
///
/// A widget cannot select a tab. It runs in another process, and the two ways
/// out of one are an App Intent and a URL — `OpenAskIntent` is the first, and
/// this is the second. A tap on the Today widget has no parameters and no
/// dialog; all it can say is "the thing you were looking at", so the URL is the
/// whole message and this type is the whole parser.
///
/// A closed enum rather than a string handed to the router, and that is the
/// point of having a type at all: the URL arrives from outside this process and
/// anything can send one — Safari, a Shortcut, a message somebody was sent. It
/// carries no payload, so there is nothing here to sanitise and nothing a
/// crafted link can reach; an unrecognised host is `nil`, and the app does
/// nothing at all.
///
/// The scheme is declared in project.yml under `CFBundleURLTypes`. Without that
/// entry iOS does not route the URL to this app and `onOpenURL` is simply never
/// called — a failure with no error attached to it, which is why the two are
/// worth mentioning in each other's comments.
enum DeepLink: String, Equatable, Sendable {

    /// `pocketd://today` — the brief. What the Today widget's `widgetURL` sends.
    case today

    /// `pocketd://ask` — the composer. Not yet sent by anything: the "Ask
    /// Pocketd" control opens the app through `OpenAskIntent` instead, because a
    /// control has to run an intent and cannot open a URL. It is here so that a
    /// Shortcut, or the widget's own Ask affordance on a future family that
    /// cannot host a button, has a spelling to use that already works.
    case ask

    /// `pocketd://you` — the profile. Nothing on a home screen sends it yet; it
    /// is here so that a Shortcut, and the screenshot harness under `#if
    /// DEBUG`, can reach the tab by the same spelling as the other two rather
    /// than by a second mechanism that only one of them understands.
    case you

    static let scheme = "pocketd"

    /// `nil` for anything this app did not put on a home screen.
    ///
    /// Host *or* first path component, because the two spellings are easy to
    /// confuse and produce different URLs: `pocketd://today` parses with host
    /// "today" and an empty path, while `pocketd:///today` — one slash more,
    /// which is what a hand-written link or a Shortcut often produces — parses
    /// with no host and path "/today". Accepting both costs one line and avoids
    /// a bug that only shows up in somebody else's typing.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let target = url.host()?.lowercased()
            ?? url.pathComponents.first(where: { $0 != "/" })?.lowercased()
        guard let target, let link = DeepLink(rawValue: target) else { return nil }
        self = link
    }
}
