import SwiftUI

/// A small action that belongs to the card it sits in.
///
/// "Read aloud", "Refresh", "Setup guide". Capsule, 37pt tall, symbol leading —
/// leading because the symbol is what the eye finds in a row of two or three of
/// these, and a trailing one makes the labels start at different places.
///
/// The exception is a pill that leaves the app, which takes `arrow.up.right`.
/// That symbol goes at the end, because there it is a consequence rather than a
/// category.
struct PillButton: View {
    let title: String
    var symbol: String = "arrow.up.right"
    /// Whether the symbol trails the label. Set for `arrow.up.right`; see
    /// above.
    var symbolTrails: Bool = false
    var tint: Color = .pd.ink
    var isOn: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: PDSpacing.xs) {
                if !symbolTrails { glyph }
                Text(title)
                    .font(Font.pd.secondary.weight(.semibold))
                if symbolTrails { glyph }
            }
            .foregroundStyle(isOn ? Color.pd.onPrimary : tint)
            .padding(.horizontal, PDSpacing.m)
            .frame(height: PDMetric.pillHeight)
            .background(
                isOn ? Color.pd.primaryButton : Color.pd.chip,
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.pd.cardStroke, lineWidth: isOn ? 0 : 1)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(title)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
    }
}

/// The same pill at link size — 24pt tall, used inline under a sentence.
struct LinkPill: View {
    let title: String
    var symbol: String = "arrow.up.right"
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: PDSpacing.xxs) {
                Text(title)
                    .font(Font.pd.caption.weight(.medium))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .regular))
            }
            .foregroundStyle(Color.pd.accent)
            .padding(.horizontal, PDSpacing.s)
            .frame(height: PDMetric.linkPillHeight)
            .background(Color.pd.accentSoft, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(title)
    }
}

#Preview("Pill button light") {
    PillButtonPreview()
}

#Preview("Pill button dark") {
    PillButtonPreview().preferredColorScheme(.dark)
}

private struct PillButtonPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            HStack(spacing: PDSpacing.xs) {
                PillButton(title: "Read aloud", symbol: "speaker.wave.2") {}
                PillButton(title: "Refresh", symbol: "arrow.clockwise") {}
            }
            HStack(spacing: PDSpacing.xs) {
                PillButton(title: "Stop", symbol: "stop.fill", isOn: true) {}
                PillButton(title: "Setup guide", symbolTrails: true) {}
            }
            LinkPill(title: "Privacy policy") {}
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pdCanvas()
    }
}
