import SwiftUI

/// One reading: a number with a label, nested inside a card.
///
/// Today's tiles are `VerdictTile`s now — a verdict word before the number.
/// This is the reading itself, for the places a number *is* the answer: the
/// health grid inside an answer card. It sits on `fillTile`, which is only
/// right nested inside a white card; on the bare canvas use a `VerdictTile`.
///
/// The value is `statValue` — proportional, regular rather than bold: four bold
/// numbers in a grid all shout. A tile whose value is words — an event title,
/// or "Free" — sets `isText` for the semibold word face.
///
/// The footnote is where the comparison goes — "usual 6,100" — because a number
/// without a baseline is trivia.
struct StatTile: View {
    let label: String
    var symbol: String?
    let value: String
    var unit: String?
    var footnote: String?
    /// The value is words rather than a figure, so it is set in the headline
    /// face instead of the mono one.
    var isText: Bool = false
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
                        .font(Font.pd.miniLabel)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                MiniLabel(label)
            }

            // Baseline-aligned so a tile with a unit and a tile without one
            // still put their digits on the same line across a row.
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(isText ? Font.pd.statText : Font.pd.statValue)
                    .foregroundStyle(isBaseline ? Color.pd.inkSecondary : tint)
                    // Words may take two lines; a figure stays on one and
                    // shrinks a little before it would break "6h 36m" apart.
                    .lineLimit(isText ? 2 : 1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        // A unit is one word: it may not fit, but it may not
                        // break ("bp / m"). The figure beside it shrinks first.
                        .fixedSize()
                }
            }

            if let footnote {
                Text(footnote)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    footnote: "in 2h 10m",
                    isText: true
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
