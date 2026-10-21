import SwiftUI

/// One of Today's four tiles: a verdict, then the sentence that carries the
/// number.
///
/// UP NEXT · "Design review" · "In 3h 19m · Conference room B."
/// DUE · "1 overdue" · "Send the invoice was due yesterday."
/// SLEEP · "Rested" · "6h 36m — 29 min under your usual."
///
/// Verdict before number: the word is what a glance needs, and the figure is
/// in the sentence for whoever reads on. The tone colours the word and puts a
/// small ✓ or ! beside it — green is fine, amber is your turn, nothing is red.
///
/// A white bordered card on the canvas, not a grey box: grey `fillTile` is for
/// a tile *inside* a card. Label and verdict sit at the top, the sentence is
/// pinned to the bottom, and in a `VerdictGrid` every tile in a row is as tall
/// as the tallest, so the sentences of two neighbours end on one line.
///
/// `.off` is the tile for a source that is not connected — "Off" and "Turn on
/// to see what's next." — and its action is the connect door itself, not a
/// trip to You.
struct VerdictTile: View {
    enum Tone: Equatable, Sendable {
        /// Ink, no glyph. An event title, "Free", "3 today".
        case neutral
        /// Green with a ✓. "All clear", "Rested", "Ahead".
        case positive
        /// Amber with a !. "1 overdue", "Short night", "Behind".
        case caution
        /// Grey, no glyph: the source is not connected.
        case off
    }

    let label: String
    /// The label's glyph — "calendar", "checklist", "bed.double",
    /// "figure.walk". Grey, beside the mono label.
    var symbol: String?
    let status: String
    var tone: Tone = .neutral
    /// Overrides the tone's own ✓ or ! — a different glyph in the same soft
    /// circle. Nil keeps the tone's.
    var statusSymbol: String?
    let sentence: String
    /// The verdict's line limit at the regular sizes. Two for an event title;
    /// the accessibility sizes always allow more.
    var statusLineLimit: Int = 2
    /// What VoiceOver says the tap does — "Shows your reminders", "Turns on
    /// Health".
    var accessibilityHint: String?
    /// What VoiceOver reads for the whole tile, when the caller has a better
    /// sentence than "label. status. sentence" (the Kit's `TileVerdict`
    /// carries one).
    var spokenLabel: String?
    var action: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize
    /// The soft circle behind ✓ / !, scaled with the verdict it sits beside.
    @ScaledMetric(relativeTo: .title3) private var glyphCircle: CGFloat = 22
    /// The label glyph's slot: the widest of the four glyphs plus a gap.
    @ScaledMetric(relativeTo: .subheadline) private var labelGlyphSlot: CGFloat = 28
    /// Half the verdict's cap height: where the circle's centre meets the
    /// first line, so the glyph sits on the word rather than above it.
    @ScaledMetric(relativeTo: .title3) private var capMiddle: CGFloat = 7

    /// A tile for a source that is not connected.
    static func off(
        label: String,
        symbol: String? = nil,
        sentence: String,
        accessibilityHint: String? = nil,
        action: (() -> Void)? = nil
    ) -> VerdictTile {
        VerdictTile(
            label: label,
            symbol: symbol,
            status: "Off",
            tone: .off,
            sentence: sentence,
            accessibilityHint: accessibilityHint,
            action: action
        )
    }

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
        VStack(alignment: .leading, spacing: 0) {
            // The glyph sits in a fixed-width slot with no height of its own,
            // centred on the label: a tall glyph (figure.walk) and a short one
            // (bed.double) then leave neighbouring labels level, and the
            // labels start at one x across the grid.
            HStack(spacing: 0) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .frame(width: labelGlyphSlot, height: 0, alignment: .leading)
                }
                MiniLabel(label)
            }
            .padding(.bottom, PDSpacing.s)

            HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
                statusGlyph
                Text(status)
                    .font(Font.pd.verdict)
                    .foregroundStyle(statusColour)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : statusLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PDSpacing.s)

            Text(sentence)
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
                .modifier(PDLineSpacing(2, relativeTo: .subheadline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PDSpacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pdCardSurface(radius: PDRadius.smallCard)
        .contentShape(RoundedRectangle(cornerRadius: PDRadius.smallCard, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel ?? "\(label). \(status). \(sentence)")
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }

    private var statusColour: Color {
        switch tone {
        case .neutral: .pd.ink
        case .positive: .pd.positive
        case .caution: .pd.caution
        case .off: .pd.inkSecondary
        }
    }

    /// The tone's ✓ or !, or the caller's own symbol, and its soft circle.
    private var glyphStyle: (symbol: String, fill: Color)? {
        switch tone {
        case .positive: (statusSymbol ?? "checkmark", .pd.positiveSoft)
        case .caution: (statusSymbol ?? "exclamationmark", .pd.cautionSoft)
        case .neutral, .off: statusSymbol.map { ($0, .pd.fillTile) }
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if let style = glyphStyle {
            // Read here: the guide's closure is `@Sendable` and cannot touch
            // the view's main-actor state itself.
            let middle = capMiddle
            Image(systemName: style.symbol)
                .font(Font.pd.footnote.weight(.semibold))
                .foregroundStyle(statusColour)
                .frame(width: glyphCircle, height: glyphCircle)
                .background(style.fill, in: Circle())
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + middle
                }
                .accessibilityHidden(true)
        }
    }
}

/// Today's tiles: two columns, rows of equal height, tops aligned — and one
/// column at the accessibility text sizes, where half a phone is a few
/// letters wide.
///
///     VerdictGrid {
///         VerdictTile(label: "Up next", symbol: "calendar", status: "Design review", sentence: "In 3h 19m · Room B.")
///         VerdictTile(label: "Due", symbol: "checklist", status: "1 overdue", tone: .caution, sentence: "…")
///         VerdictTile(label: "Sleep", symbol: "bed.double", status: "Rested", tone: .positive, sentence: "…")
///         VerdictTile.off(label: "Activity", symbol: "figure.walk", sentence: "Turn on to see your steps.")
///     }
struct VerdictGrid<Content: View>: View {
    var spacing: CGFloat = PDSpacing.tileGap
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TileGridLayout(columns: typeSize.isAccessibilitySize ? 1 : 2, spacing: spacing) {
            content
        }
    }
}

#Preview("Verdict tiles light") {
    VerdictTilePreview()
}

#Preview("Verdict tiles dark") {
    VerdictTilePreview().preferredColorScheme(.dark)
}

#Preview("Verdict tiles AX") {
    VerdictTilePreview().dynamicTypeSize(.accessibility3)
}

private struct VerdictTilePreview: View {
    var body: some View {
        ScrollView {
            VerdictGrid {
                VerdictTile(
                    label: "Up next", symbol: "calendar",
                    status: "Design review with the team",
                    sentence: "In 3h 19m · Conference room B."
                ) {}
                VerdictTile(
                    label: "Due", symbol: "checklist",
                    status: "1 overdue", tone: .caution,
                    sentence: "Send the invoice was due yesterday."
                ) {}
                VerdictTile(
                    label: "Sleep", symbol: "bed.double",
                    status: "Rested", tone: .positive,
                    sentence: "6h 36m — about your usual."
                ) {}
                VerdictTile.off(
                    label: "Activity", symbol: "figure.walk",
                    sentence: "Turn on to see your steps."
                ) {}
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}
