import PocketdKit
import SwiftUI

/// The four numbers under the brief: UP NEXT, DUE, SLEEP, STEPS.
///
/// Every string and every tone comes from `TodayTiles` in the Kit rather than
/// from this file, and that is deliberate: the interesting bugs in a tile are
/// all in its empty states — "0" when Health is off is a lie, "Free" when the
/// calendar was never connected is a worse one — and testing those in a `body`
/// means booting a simulator. Here there is only layout and the tap.
struct TodayTileGrid: View {
    let snapshot: TodaySnapshot
    /// One column instead of two. Set at accessibility type sizes, where a
    /// 27pt monospaced figure and a two-line footnote do not share a half
    /// screen with anything.
    var oneColumn: Bool = false
    let open: (TodayTile) -> Void

    /// Recomputed on every redraw rather than stored, because "in 2h 10m" is a
    /// function of the clock and a stored one would still be saying it at half
    /// past eleven. The parent redraws this once a minute.
    private var now: Date { Date() }

    var body: some View {
        Grid(horizontalSpacing: PDSpacing.tileGap, verticalSpacing: PDSpacing.tileGap) {
            if oneColumn {
                ForEach(TodayTile.allCases, id: \.self) { tile in
                    GridRow { cell(tile) }
                }
            } else {
                GridRow {
                    cell(.upNext)
                    cell(.due)
                }
                GridRow {
                    cell(.sleep)
                    cell(.steps)
                }
            }
        }
    }

    private func cell(_ kind: TodayTile) -> some View {
        let tile = value(for: kind)
        return StatTile(
            label: Self.label(for: kind),
            symbol: Self.symbol(for: kind),
            value: tile.value,
            unit: tile.unit,
            footnote: tile.footnote,
            tint: Self.tint(for: tile.tone)
        ) {
            open(kind)
        }
    }

    private func value(for kind: TodayTile) -> TodayTiles.Tile {
        switch kind {
        case .upNext: TodayTiles.upNext(snapshot, now: now)
        case .due: TodayTiles.due(snapshot)
        case .sleep: TodayTiles.sleep(snapshot)
        case .steps: TodayTiles.steps(snapshot)
        }
    }

    /// Uppercased by `MiniLabel` itself; written here in sentence case so the
    /// string is readable where it lives.
    private static func label(for kind: TodayTile) -> String {
        switch kind {
        case .upNext: "Up next"
        case .due: "Due"
        case .sleep: "Sleep"
        case .steps: "Steps"
        }
    }

    private static func symbol(for kind: TodayTile) -> String {
        switch kind {
        case .upNext: "calendar"
        case .due: "checklist"
        case .sleep: "bed.double"
        case .steps: "figure.walk"
        }
    }

    /// The Kit names the feeling; the view picks the colour. That split is what
    /// lets the same tile be right in light mode, dark mode, and under a
    /// palette nobody has designed yet.
    private static func tint(for tone: TodayTiles.Tone) -> Color {
        switch tone {
        case .neutral: .pd.ink
        case .positive: .pd.positive
        case .caution: .pd.caution
        }
    }
}

// MARK: - Previews

#Preview("Tiles light") {
    TilePreview()
}

#Preview("Tiles dark") {
    TilePreview().preferredColorScheme(.dark)
}

private struct TilePreview: View {
    var body: some View {
        VStack(spacing: PDSpacing.cardGap) {
            TodayTileGrid(snapshot: TodayPreviewData.full) { _ in }
            TodayTileGrid(snapshot: TodayPreviewData.nothingConnected) { _ in }
        }
        .padding(PDSpacing.gutter)
        .pdCanvas()
    }
}
