import PocketdKit
import SwiftUI

/// The shape every screen of the intro has.
///
/// One ornament, a headline that ends in a full stop, an optional calm
/// sentence, whatever that screen is actually asking for, and a pinned footer:
/// an optional primer, the one black button, and an optional "Not now →".
/// Written once because five screens that each lay this out themselves is five
/// chances for one of them to be 4pt off, and because the headline landing in
/// exactly the same place every time is most of what makes an intro feel made.
///
/// The footer is pinned with `pdBottomBar`, so the content scrolls *above* it —
/// at every text size, which is how the button stays reachable at AX sizes —
/// and on iOS 26 passes under it behind the system's scroll-edge effect rather
/// than showing through the gaps. The primer lives in the footer, directly
/// above the button it describes. The old morning-brief screen kept it at the
/// end of the scroll, where the pinned button sat on top of it: the one line
/// saying what the iOS sheet was about to ask was the one line nobody could
/// read.
struct OnboardingPage<Content: View>: View {
    /// What sits above the headline.
    enum Ornament {
        /// A 52pt icon tile, the onboarding treatment.
        case icon(String)
        /// The orb, for the one screen with nothing yet to name.
        case orb
    }

    /// A button and what it does. A small struct rather than four parallel
    /// parameters, so a caller cannot pass a title with no action.
    struct Action {
        var title: String
        var isEnabled: Bool = true
        var isLoading: Bool = false
        var run: () -> Void

        init(_ title: String, isEnabled: Bool = true, isLoading: Bool = false, run: @escaping () -> Void) {
            self.title = title
            self.isEnabled = isEnabled
            self.isLoading = isLoading
            self.run = run
        }
    }

    var ornament: Ornament
    var headline: String
    var secondary: String?
    /// Markdown, with the iOS button's name in bold. Above the button.
    var primer: String?
    var primary: Action
    /// The quiet way past an optional screen: "Not now →".
    var escape: Action?
    @ViewBuilder var content: Content

    init(
        ornament: Ornament,
        headline: String,
        secondary: String? = nil,
        primer: String? = nil,
        primary: Action,
        escape: Action? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.ornament = ornament
        self.headline = headline
        self.secondary = secondary
        self.primer = primer
        self.primary = primary
        self.escape = escape
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.m) {
                switch ornament {
                case let .icon(symbol):
                    IconTile(symbol: symbol)
                        .padding(.bottom, PDSpacing.xxs)
                case .orb:
                    ThinkingOrb(size: 96)
                        .padding(.bottom, PDSpacing.xxs)
                        .accessibilityHidden(true)
                }

                Text(headline)
                    .pdHero()
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if let secondary {
                    Text(secondary)
                        .pdSubtitle()
                        .foregroundStyle(Color.pd.inkSecondaryWarm)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content
                    .padding(.top, PDSpacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PDSpacing.heroGutter)
            .padding(.top, PDSpacing.l)
            .padding(.bottom, PDSpacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .pdBottomBar(scrim: .pd.canvasWarm) { footer }
    }

    private var footer: some View {
        VStack(spacing: PDSpacing.xxs) {
            if let primer {
                Primer(primer, warm: true)
                    .padding(.bottom, PDSpacing.s)
            }
            PrimaryButton(
                title: primary.title,
                isLoading: primary.isLoading,
                isEnabled: primary.isEnabled,
                action: primary.run
            )
            if let escape {
                TextLink(escape.title, tint: .pd.inkSecondaryWarm, action: escape.run)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, PDSpacing.heroGutter)
        .padding(.top, PDSpacing.s)
        .padding(.bottom, PDSpacing.xs)
    }
}

/// The canvas a single step sits on, for previews.
///
/// The steps are drawn by `OnboardingFlow`, which owns the wash and the stripe;
/// a preview of one step on a white background is a preview of a screen this
/// app does not have.
struct OnboardingStepPreview<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ProgressStripe(fraction: 0.4)
                .padding(.horizontal, PDSpacing.heroGutter)
                .padding(.top, PDSpacing.m)
            content
        }
        .background {
            ZStack(alignment: .top) {
                Color.pd.canvasWarm
                PDGradient.canvasWashWarm.frame(height: 400)
            }
            .ignoresSafeArea()
        }
    }
}
