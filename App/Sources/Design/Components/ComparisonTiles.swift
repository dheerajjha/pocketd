import SwiftUI

/// Your usual, beside the latest: USUAL 7h 10m | LAST NIGHT 6h 36m.
///
/// The baseline on the left in grey, the current reading on the right in ink,
/// both at hero size in the *proportional* face, and an optional sentence
/// under them saying what the difference means. A number without a baseline
/// is trivia; two numbers side by side are a comparison anybody can make.
///
/// Two grey `fillTile` tiles, so it belongs **inside a white `PDCard`** — the
/// tile grey on the bare canvas is the heavy grey-box look the simpler app
/// removed. At the accessibility text sizes the tiles stack, so a 48pt figure
/// is never squeezed into half a phone.
struct ComparisonTiles: View {
    /// One side: a mono caps label over a figure, with an optional small unit.
    struct Reading {
        var label: String
        var value: String
        /// "steps", "bpm". Set small, in mono caps, after the figure.
        var unit: String?

        init(_ label: String, value: String, unit: String? = nil) {
            self.label = label
            self.value = value
            self.unit = unit
        }
    }

    let usual: Reading
    let current: Reading
    /// "29 minutes under your usual." Nil when the summary above already
    /// says it.
    var delta: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: PDSpacing.xs))
                : AnyLayout(HStackLayout(alignment: .top, spacing: PDSpacing.xs))
            layout {
                tile(usual, isBaseline: true)
                tile(current, isBaseline: false)
            }
            // Equal heights side by side: each tile fills to the taller one.
            .fixedSize(horizontal: false, vertical: true)

            if let delta {
                Text(delta)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func tile(_ reading: Reading, isBaseline: Bool) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            MiniLabel(reading.label)
            HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xxs) {
                Text(reading.value)
                    .font(Font.pd.statValue)
                    .foregroundStyle(isBaseline ? Color.pd.inkSecondary : Color.pd.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit = reading.unit {
                    Text(unit.uppercased())
                        .font(Font.pd.miniLabel)
                        .tracking(1.2)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
            }
        }
        .padding(PDSpacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.pd.fillTile, in: RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous))
    }

    private var accessibilityText: String {
        func spoken(_ reading: Reading) -> String {
            [reading.label, reading.value, reading.unit].compactMap { $0 }.joined(separator: " ")
        }
        return [spoken(usual), spoken(current), delta].compactMap { $0 }.joined(separator: ". ")
    }
}

#Preview("Comparison tiles light") {
    ComparisonTilesPreview()
}

#Preview("Comparison tiles dark") {
    ComparisonTilesPreview().preferredColorScheme(.dark)
}

#Preview("Comparison tiles AX") {
    ComparisonTilesPreview().dynamicTypeSize(.accessibility3)
}

private struct ComparisonTilesPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.cardGap) {
                PDCard {
                    ComparisonTiles(
                        usual: .init("Usual", value: "7h 10m"),
                        current: .init("Last night", value: "6h 36m"),
                        delta: "34 minutes under your usual."
                    )
                }
                PDCard {
                    ComparisonTiles(
                        usual: .init("Usual by now", value: "6,100", unit: "steps"),
                        current: .init("Today", value: "4,120", unit: "steps")
                    )
                }
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}
