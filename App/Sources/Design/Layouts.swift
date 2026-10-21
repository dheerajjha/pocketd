import SwiftUI

// MARK: - Tile grid

/// Tiles in columns, every tile in a row as tall as the tallest one, tops
/// aligned.
///
/// Not `Grid`. A `GridRow` centres cells of different heights against each
/// other, which is how v2's Today tiles ended up six points out of line, and
/// it has no way to say "fill the row" to a cell. This layout measures each
/// row at the column width, then proposes that row's height to every tile in
/// it — so a tile whose body is `frame(maxHeight: .infinity)` fills the row and
/// pins its last line to the bottom, and its neighbour does the same.
///
/// `VerdictGrid` wraps it with the one-column switch at the accessibility
/// sizes; use that rather than this directly.
struct TileGridLayout: Layout {
    var columns: Int = 2
    var spacing: CGFloat = PDSpacing.tileGap

    private var columnCount: Int { max(1, columns) }

    private func columnWidth(for width: CGFloat) -> CGFloat {
        let gaps = spacing * CGFloat(columnCount - 1)
        return max(0, (width - gaps) / CGFloat(columnCount))
    }

    /// Each row's height at `columnWidth`.
    private func rowHeights(subviews: Subviews, columnWidth: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columnCount).map { start in
            let end = min(start + columnCount, subviews.count)
            return (start..<end)
                .map { subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            // No width offered (a horizontal scroll view, a sizing pass): the
            // widest tile's own width, times the columns.
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = widest * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1)
        }
        let heights = rowHeights(subviews: subviews, columnWidth: columnWidth(for: width))
        let total = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(for: bounds.width)
        let heights = rowHeights(subviews: subviews, columnWidth: column)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for slot in 0..<columnCount {
                let index = row * columnCount + slot
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(slot) * (column + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: column, height: height)
                )
            }
            y += height + spacing
        }
    }
}

// MARK: - Title, detail, accessory

/// A row of text with a control on the end — a Connect pill, a switch, a
/// status word — that keeps its words whole.
///
/// Three subviews in order: the title, the grey detail line, the accessory.
/// (Two works too: title and accessory.)
///
/// Inline when the title fits on one line beside the accessory: the text
/// column takes what the accessory leaves and the accessory is centred
/// against it, the way a Settings switch sits against a two-line label.
/// Otherwise **stacked**: title, detail, then the accessory under them at the
/// leading edge.
///
/// The test is measured, not prioritised: the title's *one-line* width must
/// fit beside the accessory, and the column left for the text must be at
/// least `minimumColumn` of the row, so a wide accessory ("Off in iOS
/// Settings ›") cannot leave the grey line two words a line. An `HStack`
/// cannot make either call: it shrinks the title first, because the
/// accessory is fixed-size, and the title then breaks inside a word —
/// "Remind / ers" beside a status pill, at the default text size, on Today
/// and in onboarding.
struct AccessoryRowLayout: Layout {
    /// Between the text column and the accessory, and above a stacked
    /// accessory.
    var spacing: CGFloat = PDSpacing.s
    /// Between the title and the detail.
    var lineGap: CGFloat = 2
    /// The smallest share of the row the text column may be left with
    /// before the accessory moves underneath instead.
    var minimumColumn: CGFloat = 0.55

    private struct Parts {
        var title: LayoutSubview
        var detail: LayoutSubview?
        var accessory: LayoutSubview
    }

    private func parts(_ subviews: Subviews) -> Parts? {
        switch subviews.count {
        case 2: return Parts(title: subviews[0], detail: nil, accessory: subviews[1])
        case 3: return Parts(title: subviews[0], detail: subviews[1], accessory: subviews[2])
        default: return nil
        }
    }

    private func isInline(width: CGFloat, title: LayoutSubview, accessory: LayoutSubview) -> Bool {
        let titleWidth = title.sizeThatFits(.unspecified).width
        let accessoryWidth = accessory.sizeThatFits(.unspecified).width
        let column = width - spacing - accessoryWidth
        return titleWidth <= column && column >= width * minimumColumn
    }

    private func textHeight(title: LayoutSubview, detail: LayoutSubview?, width: CGFloat) -> CGFloat {
        let proposal = ProposedViewSize(width: width, height: nil)
        let titleHeight = title.sizeThatFits(proposal).height
        guard let detail else { return titleHeight }
        let detailHeight = detail.sizeThatFits(proposal).height
        return detailHeight > 0 ? titleHeight + lineGap + detailHeight : titleHeight
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let found = parts(subviews) else { return .zero }
        let (title, detail, accessory) = (found.title, found.detail, found.accessory)
        let accessorySize = accessory.sizeThatFits(.unspecified)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            width = title.sizeThatFits(.unspecified).width + spacing + accessorySize.width
        }
        if isInline(width: width, title: title, accessory: accessory) {
            let column = width - spacing - accessorySize.width
            let text = textHeight(title: title, detail: detail, width: column)
            return CGSize(width: width, height: max(text, accessorySize.height))
        }
        // Stacked, the accessory may use the whole width — and wrap within
        // it — rather than run off the end at its one-line width.
        let stacked = accessory.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let text = textHeight(title: title, detail: detail, width: width)
        return CGSize(width: width, height: text + spacing + stacked.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let found = parts(subviews) else { return }
        let (title, detail, accessory) = (found.title, found.detail, found.accessory)
        let accessorySize = accessory.sizeThatFits(.unspecified)
        let inline = isInline(width: bounds.width, title: title, accessory: accessory)
        let column = inline ? bounds.width - spacing - accessorySize.width : bounds.width
        let text = textHeight(title: title, detail: detail, width: column)

        // Inline, the shorter of the two is centred against the taller.
        let rowHeight = inline ? max(text, accessorySize.height) : text
        var y = bounds.minY + (inline ? (rowHeight - text) / 2 : 0)
        let proposal = ProposedViewSize(width: column, height: nil)

        let titleHeight = title.sizeThatFits(proposal).height
        title.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: proposal)
        y += titleHeight
        if let detail {
            let detailHeight = detail.sizeThatFits(proposal).height
            if detailHeight > 0 { y += lineGap }
            detail.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: proposal)
        }

        if inline {
            accessory.place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + rowHeight / 2),
                anchor: .trailing,
                proposal: ProposedViewSize(accessorySize)
            )
        } else {
            accessory.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + text + spacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }
}
