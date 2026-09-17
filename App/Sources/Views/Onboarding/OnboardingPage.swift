import PocketdKit
import SwiftUI

/// The shape every screen of the intro has.
///
/// One ornament, one two-line headline that ends in a full stop, one calm
/// sentence, whatever that screen is actually asking for, and a pinned button
/// with an optional way out under it. Written once because eight screens that
/// each lay this out themselves is eight chances for one of them to be 4pt off,
/// and because the thing that makes an intro feel made rather than assembled is
/// that the headline lands in exactly the same place every time.
///
/// The footer is a `safeAreaInset` rather than an overlay: the content scrolls
/// *above* it and never under it. On the reference the pinned CTA floats over
/// the scroll, which works there because no screen is taller than the phone —
/// here the brain card at an accessibility text size is, and copy hidden behind
/// a button is worse than a button that never overlaps anything.
struct OnboardingPage<Content: View>: View {
    /// What sits above the headline.
    enum Ornament {
        /// A 52pt icon tile, the onboarding treatment.
        case icon(String)
        /// The orb, for the one screen with no ability to name.
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
    var secondary: String
    var primary: Action
    var escape: Action?
    @ViewBuilder var content: Content

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

                Text(secondary)
                    .pdSubtitle()
                    .foregroundStyle(Color.pd.inkSecondaryWarm)
                    .fixedSize(horizontal: false, vertical: true)

                content
                    .padding(.top, PDSpacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PDSpacing.heroGutter)
            .padding(.top, PDSpacing.l)
            .padding(.bottom, PDSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: PDSpacing.xxs) {
                PrimaryButton(
                    title: primary.title,
                    isLoading: primary.isLoading,
                    isEnabled: primary.isEnabled,
                    action: primary.run
                )
                if let escape {
                    SecondaryLink(escape.title, action: escape.run)
                }
            }
            .padding(.horizontal, PDSpacing.heroGutter)
            .padding(.top, PDSpacing.s)
            .padding(.bottom, PDSpacing.xs)
        }
    }
}

// MARK: - Welcome

/// Screen one. The only claim, and the three words under it that back it up.
///
/// The orb rather than an icon tile because there is no ability to name yet —
/// what is being introduced is the thing itself, and a breathing shape says
/// "this is alive and it is here" faster than any glyph of a brain.
struct OnboardingWelcomeStep: View {
    var onContinue: () -> Void

    /// Three facts, not three features. Each is a thing every other assistant
    /// on the store cannot say, and all three fit on one line in mono.
    private static let claims = ["No account", "No cloud", "Free"]

    var body: some View {
        OnboardingPage(
            ornament: .orb,
            headline: "Meet Pocketd.",
            secondary: """
            An assistant that lives on your phone. It can see your day, and \
            nothing you say leaves the device.
            """,
            primary: .init("Get started", run: onContinue)
        ) {
            HStack(spacing: PDSpacing.xs) {
                ForEach(Array(Self.claims.enumerated()), id: \.offset) { position, claim in
                    if position > 0 {
                        Text("·")
                            .font(Font.pd.miniLabel)
                            .foregroundStyle(Color.pd.inkTertiary)
                    }
                    MiniLabel(claim, tint: .pd.inkSecondaryWarm)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No account. No cloud. Free.")
        }
    }
}

#Preview("Welcome light") {
    OnboardingStepPreview { OnboardingWelcomeStep(onContinue: {}) }
}

#Preview("Welcome dark") {
    OnboardingStepPreview { OnboardingWelcomeStep(onContinue: {}) }
        .preferredColorScheme(.dark)
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
            ProgressStripe(fraction: 0.5)
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
