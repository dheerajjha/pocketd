import SwiftUI

/// A rounded square with one symbol in it.
///
/// Two sizes and they are different components wearing one name: 52pt with a
/// 16pt radius as the hero of an onboarding step, and 30pt with an 8pt radius
/// as the leading element of a row inside a card. Passing anything between them
/// produces something that looks like neither.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = PDMetric.iconTile
    var fill: Color = .pd.accentTile
    var tint: Color = .pd.accent

    /// The in-card size, named rather than passed as a number.
    static func small(_ symbol: String, fill: Color = .pd.accentSoft, tint: Color = .pd.accent) -> IconTile {
        IconTile(symbol: symbol, size: PDMetric.iconTileSmall, fill: fill, tint: tint)
    }

    private var radius: CGFloat {
        size >= PDMetric.iconTile ? PDRadius.iconTile : PDRadius.iconTileSmall
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

#Preview("Icon tile light") {
    IconTilePreview()
}

#Preview("Icon tile dark") {
    IconTilePreview().preferredColorScheme(.dark)
}

private struct IconTilePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xl) {
            HStack(spacing: PDSpacing.m) {
                IconTile(symbol: "brain")
                IconTile(symbol: "calendar")
                IconTile(symbol: "checklist")
                IconTile(symbol: "heart")
            }
            PDCard {
                VStack(spacing: PDSpacing.m) {
                    ForEach(["calendar", "checklist", "bed.double"], id: \.self) { symbol in
                        HStack(spacing: PDSpacing.s) {
                            IconTile.small(symbol)
                            Text("A row inside a card")
                                .font(Font.pd.rowTitle)
                                .foregroundStyle(Color.pd.ink)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pdCanvas()
    }
}
