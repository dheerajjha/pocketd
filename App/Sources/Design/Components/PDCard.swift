import SwiftUI

/// The surface everything in this app sits on.
///
/// One radius, one border, one very soft shadow. A screen is a stack of these
/// with 16pt between them; nothing else is a container. White cards on the
/// canvas; `fillTile` grey only for a tile nested *inside* one of these.
///
/// The border is not decoration. On a near-white canvas a white card with only
/// a shadow is a smudge — the hairline is what says where the card ends, and
/// the shadow is only what lifts it.
struct PDCard<Content: View>: View {
    var padding: CGFloat = PDSpacing.cardPadding
    var radius: CGFloat = PDRadius.card
    /// The warm pair, for a card on the onboarding canvas where pure white
    /// reads as a hole punched in the paper.
    var warm: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pdCardSurface(
                radius: radius,
                fill: warm ? .pd.cardWarm : .pd.card,
                stroke: warm ? .pd.cardStrokeWarm : .pd.cardStroke
            )
    }
}

#Preview("Card light") {
    PDCardPreview()
}

#Preview("Card dark") {
    PDCardPreview().preferredColorScheme(.dark)
}

private struct PDCardPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.cardGap) {
                PDCard {
                    VStack(alignment: .leading, spacing: PDSpacing.s) {
                        SectionLabel("Last 7 nights")
                        Text("You have one thing on this morning and nothing after four.")
                            .pdLead()
                    }
                }
                HStack(spacing: PDSpacing.tileGap) {
                    PDCard(radius: PDRadius.smallCard) {
                        Text("Left of a pair").font(Font.pd.headline).foregroundStyle(Color.pd.ink)
                    }
                    PDCard(radius: PDRadius.smallCard) {
                        Text("Right of a pair").font(Font.pd.headline).foregroundStyle(Color.pd.ink)
                    }
                }
                PDCard(warm: true) {
                    Text("A warm card, for the onboarding canvas.")
                        .font(Font.pd.body)
                        .foregroundStyle(Color.pd.ink)
                }
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}
