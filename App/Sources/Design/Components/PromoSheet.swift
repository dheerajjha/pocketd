import SwiftUI

/// The first time somebody touches a feature, what it is for — and one way in.
///
///     .sheet(isPresented: $showsPromo) {
///         PromoSheet(
///             symbol: "alarm",
///             title: "Start every day briefed.",
///             benefits: [
///                 .init("sun.horizon", "Your day, waiting when you wake"),
///                 .init("exclamationmark.circle", "Overdue things, caught early"),
///                 .init("clock", "At the time you choose"),
///             ],
///             primaryTitle: "Set it up",
///             primer: "Next, tap **Allow** so Pocketd can tell you when your brief is ready.",
///             onPrimary: { … },
///             onSecondary: { showsPromo = false }
///         )
///     }
///
/// A hero, three benefit rows, one black button and a quiet "Not now". It
/// appears when the feature is first opened (Routines with none set up, Use
/// from your laptop), never as an interruption, and any permission it leads
/// to is asked *after* the person has chosen the feature.
///
/// The sheet content scrolls at large text sizes; the two buttons stay pinned
/// at the bottom.
struct PromoSheet: View {
    struct Benefit: Identifiable {
        var id: String { title }
        var symbol: String
        var title: String
        /// One grey line under the title. Usually not needed.
        var detail: String?

        init(_ symbol: String, _ title: String, detail: String? = nil) {
            self.symbol = symbol
            self.title = title
            self.detail = detail
        }
    }

    /// The hero icon tile. Nil for none.
    var symbol: String?
    /// The promise, as a sentence ending in "." — "Start every day briefed."
    let title: String
    /// One line under the hero. Optional; the benefits usually say it.
    var subtitle: String?
    let benefits: [Benefit]
    /// The verb on the one button — "Set it up", "Turn on".
    let primaryTitle: String
    /// A `Primer` (Markdown) directly above the button, when the button leads
    /// to an iOS permission sheet: "Next, tap **Allow** so Pocketd can tell
    /// you when your brief is ready."
    var primer: String?
    var secondaryTitle: String = "Not now"
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.xl) {
                if let symbol {
                    IconTile(symbol: symbol)
                }
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    Text(title)
                        .pdHero()
                        .foregroundStyle(Color.pd.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .pdSubtitle()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: PDSpacing.l) {
                    ForEach(benefits) { benefit in
                        benefitRow(benefit)
                    }
                }
            }
            .padding(.horizontal, PDSpacing.heroGutter)
            .padding(.top, PDSpacing.xxl)
            .padding(.bottom, PDSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: PDSpacing.xxs) {
                if let primer {
                    Primer(primer)
                        .padding(.bottom, PDSpacing.s)
                }
                PrimaryButton(title: primaryTitle, action: onPrimary)
                SecondaryLink(secondaryTitle, action: onSecondary)
            }
            .padding(.horizontal, PDSpacing.heroGutter)
            .padding(.top, PDSpacing.s)
            .padding(.bottom, PDSpacing.xs)
            .background(Color.pd.canvas.ignoresSafeArea(edges: .bottom))
        }
        .pdCanvas()
        .presentationDragIndicator(.visible)
    }

    private func benefitRow(_ benefit: Benefit) -> some View {
        HStack(alignment: .top, spacing: PDSpacing.m) {
            IconTile.small(benefit.symbol, fill: .pd.fillWarm, tint: .pd.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = benefit.detail {
                    Text(detail)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Level with the 30pt tile when the title is one line.
            .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Promo sheet light") {
    Color.pd.canvas
        .sheet(isPresented: .constant(true)) { PromoSheetPreview() }
}

#Preview("Promo sheet dark") {
    Color.pd.canvas
        .sheet(isPresented: .constant(true)) { PromoSheetPreview() }
        .preferredColorScheme(.dark)
}

private struct PromoSheetPreview: View {
    var body: some View {
        PromoSheet(
            symbol: "alarm",
            title: "Start every day briefed.",
            benefits: [
                .init("sun.horizon", "Your day, waiting when you wake"),
                .init("exclamationmark.circle", "Overdue things, caught early"),
                .init("clock", "At the time you choose"),
            ],
            primaryTitle: "Set it up",
            primer: "Next, tap **Allow** so Pocketd can tell you when your brief is ready.",
            onPrimary: {},
            onSecondary: {}
        )
    }
}
