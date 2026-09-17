import SwiftUI

/// "What's on tomorrow?"
///
/// The chips are the answer to the blank-page problem: an assistant that can
/// read your calendar is useless if nobody knows to ask it about the calendar.
/// They are written as the question a person would type, in sentence case with
/// the question mark, because that is what makes them read as examples rather
/// than as buttons.
struct SuggestionChip: View {
    let text: String
    var symbol: String?
    let action: () -> Void

    init(_ text: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.text = text
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: PDSpacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                Text(text)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, PDSpacing.m)
            .frame(height: PDMetric.pillHeight)
            .background(Color.pd.chip, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(text)
        .accessibilityHint("Asks this question")
    }
}

/// Chips that wrap onto as many lines as they need.
///
/// `LazyVGrid` cannot do this — it wants columns of a known width, and these
/// are sentences of wildly different lengths. A flow layout is the right shape
/// and iOS 16's `Layout` protocol makes it about thirty lines.
struct ChipFlow: Layout {
    var spacing: CGFloat = PDSpacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = arrange(subviews: subviews, in: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Suggestion chip light") {
    SuggestionChipPreview()
}

#Preview("Suggestion chip dark") {
    SuggestionChipPreview().preferredColorScheme(.dark)
}

private struct SuggestionChipPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            SectionLabel("Try asking")
            ChipFlow {
                SuggestionChip("What's on tomorrow?") {}
                SuggestionChip("Anything overdue?") {}
                SuggestionChip("How did I sleep?") {}
                SuggestionChip("Remind me to…", symbol: "bell") {}
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pdCanvas()
    }
}
