import SwiftUI

/// One reading from the day: UP NEXT, DUE, SLEEP, STEPS.
///
/// The value is 27pt monospaced regular rather than bold, and that is
/// deliberate: four bold numbers in a 2×2 grid all shout, and the brief above
/// them is the thing worth reading. Mono also means "6h 36m" and "6h 02m" line
/// up with each other when the grid redraws.
///
/// The footnote is where the comparison goes — "usual 6,100" — because a number
/// without a baseline is trivia.
struct StatTile: View {
    let label: String
    var symbol: String?
    let value: String
    var unit: String?
    var footnote: String?
    var tint: Color = .pd.ink
    /// Greyed, for a baseline rather than a current reading.
    var isBaseline: Bool = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button {
                Haptics.tap()
                action()
            } label: { tile }
                .buttonStyle(PDPressStyle())
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            HStack(spacing: PDSpacing.xxs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                MiniLabel(label)
            }

            // Baseline-aligned so a tile with a unit and a tile without one
            // still put their digits on the same line across a row.
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Font.pd.statValue)
                    .foregroundStyle(isBaseline ? Color.pd.inkSecondary : tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
            }

            if let footnote {
                Text(footnote)
                    .font(Font.pd.caption)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PDSpacing.m)
        .background(Color.pd.fillTile, in: RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label). \(value) \(unit ?? ""). \(footnote ?? "")")
    }
}

#Preview("Stat tile light") {
    StatTilePreview()
}

#Preview("Stat tile dark") {
    StatTilePreview().preferredColorScheme(.dark)
}

private struct StatTilePreview: View {
    var body: some View {
        VStack(spacing: PDSpacing.tileGap) {
            HStack(spacing: PDSpacing.tileGap) {
                StatTile(
                    label: "Up next",
                    symbol: "calendar",
                    value: "Standup",
                    footnote: "in 2h 10m"
                )
                StatTile(
                    label: "Due",
                    symbol: "checklist",
                    value: "3",
                    unit: "today",
                    footnote: "1 overdue",
                    tint: .pd.caution
                )
            }
            HStack(spacing: PDSpacing.tileGap) {
                StatTile(
                    label: "Sleep",
                    symbol: "bed.double",
                    value: "6h 36m",
                    footnote: "24m under your usual"
                )
                StatTile(
                    label: "Steps",
                    symbol: "figure.walk",
                    value: "4,812",
                    footnote: "usual 6,100"
                )
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .pdCanvas()
    }
}
