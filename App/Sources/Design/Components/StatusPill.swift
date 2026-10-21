import SwiftUI

/// Connected. Off. Needs attention.
///
/// A word in a tinted capsule, with the tint carrying the same meaning
/// everywhere in the app: green is working, amber is your turn, grey is off on
/// purpose. Never red — a refused permission is not an error, it is a choice,
/// and this app does not scold.
struct StatusPill: View {
    enum Kind {
        case positive
        case caution
        case neutral

        var ink: Color {
            switch self {
            case .positive: .pd.positive
            case .caution: .pd.caution
            case .neutral: .pd.inkSecondary
            }
        }

        var fill: Color {
            switch self {
            case .positive: .pd.positiveSoft
            case .caution: .pd.cautionSoft
            case .neutral: .pd.chip
            }
        }

        /// A glyph only where it adds something. "Connected" earns a tick;
        /// "Off" does not need a symbol saying it is off.
        var symbol: String? {
            switch self {
            case .positive: "checkmark"
            case .caution: "exclamationmark"
            case .neutral: nil
            }
        }
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        HStack(spacing: PDSpacing.xxs) {
            if let symbol = kind.symbol {
                Image(systemName: symbol)
                    .font(Font.pd.tick.weight(.bold))
            }
            Text(text)
                .font(Font.pd.secondary.weight(.medium))
                // One word or two, never "Needs atte…" and never "Rea / dy":
                // one line that shrinks a little before it would truncate or
                // break inside a word. Where the pill goes is the row's call —
                // `AccessoryRowLayout` moves it under the title when the two
                // do not fit side by side — so it is only squeezed when there
                // is truly no room.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(kind.ink)
        .layoutPriority(1)
        .padding(.horizontal, PDSpacing.s)
        .padding(.vertical, 3)
        .frame(minHeight: PDMetric.linkPillHeight + 4)
        .background(kind.fill, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

#Preview("Status pill light") {
    StatusPillPreview()
}

#Preview("Status pill dark") {
    StatusPillPreview().preferredColorScheme(.dark)
}

private struct StatusPillPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            StatusPill(.positive, "Connected")
            StatusPill(.caution, "Needs attention")
            StatusPill(.neutral, "Off")
            HStack(spacing: PDSpacing.xs) {
                StatusPill(.positive, "Ready")
                StatusPill(.neutral, "Not connected")
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pdCanvas()
    }
}
