import SwiftUI

/// A row of data inside a card: a title in ink, a grey line under it, a value
/// right-aligned in mono, and optionally a few ↗ links.
///
///     Lunch at The Arches                         1:00 PM
///     The Arches, Leith Walk · 1h
///     [Directions ↗] [Open in Calendar ↗]
///
/// The value is mono because a column of these is a column of times or
/// figures, and the reason to put them in a column is so they line up. It is
/// the only mono in a row; the title and the line under it are sentences.
///
/// Links are the row's own actions — act from the list, no detail page in
/// between — and ↗ means they leave the app (Maps, Calendar). They are small
/// chips drawn at 28pt and tappable at 44, and they wrap under each other
/// when a row cannot hold them side by side.
///
/// At the accessibility text sizes the value moves under the title instead of
/// squeezing it into a sliver beside a wide mono figure.
///
/// Rows sit in a `PDCard`, separated by `Divider()`s tinted `Color.pd.divider`.
struct DataRow: View {
    /// A ↗ action on a row: "Directions", "Open in Calendar".
    struct Link: Identifiable {
        var id: String { title }
        var title: String
        /// `arrow.up.right` for "leaves the app"; `arrow.right` for "goes
        /// somewhere in the app".
        var symbol: String = "arrow.up.right"
        var action: () -> Void

        init(_ title: String, symbol: String = "arrow.up.right", action: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.action = action
        }
    }

    let title: String
    var subtitle: String?
    var value: String?
    /// The value's colour: ink, or a meaning colour for a value that is one
    /// ("Overdue" in amber).
    var valueTint: Color = .pd.ink
    var links: [Link] = []

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    titleBlock
                    if let value {
                        valueText(value).multilineTextAlignment(.leading)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                    titleBlock
                    Spacer(minLength: 0)
                    if let value {
                        valueText(value)
                            .multilineTextAlignment(.trailing)
                            .layoutPriority(1)
                    }
                }
            }

            if !links.isEmpty {
                // Side by side while they fit; one under another when not.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PDSpacing.xs) { linkChips }
                    VStack(alignment: .leading, spacing: 0) { linkChips }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Font.pd.rowTitle)
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(Font.pd.monoValue)
            .foregroundStyle(valueTint)
            .lineLimit(2)
    }

    private var linkChips: some View {
        ForEach(links) { link in
            Button {
                Haptics.tap()
                link.action()
            } label: {
                HStack(spacing: PDSpacing.xxs) {
                    Text(link.title)
                        .font(Font.pd.footnote.weight(.semibold))
                    Image(systemName: link.symbol)
                        .font(Font.pd.tick)
                }
                .foregroundStyle(Color.pd.inkSecondaryWarm)
                .padding(.horizontal, PDSpacing.s)
                .padding(.vertical, PDSpacing.xxs)
                .frame(minHeight: 28)
                .background(Color.pd.fillWarm, in: Capsule(style: .continuous))
                .pdHitTarget(alignment: .leading)
            }
            .buttonStyle(PDPressStyle())
            .accessibilityLabel(link.title)
            .accessibilityHint(link.symbol == "arrow.up.right" ? "Opens another app" : "")
        }
    }
}

#Preview("Data rows light") {
    DataRowPreview()
}

#Preview("Data rows dark") {
    DataRowPreview().preferredColorScheme(.dark)
}

#Preview("Data rows AX") {
    DataRowPreview().dynamicTypeSize(.accessibility3)
}

private struct DataRowPreview: View {
    var body: some View {
        ScrollView {
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    SectionLabel("Later today")
                    DataRow(
                        title: "Lunch at The Arches",
                        subtitle: "The Arches, Leith Walk · 1h",
                        value: "1:00 PM",
                        links: [.init("Directions") {}, .init("Open in Calendar") {}]
                    )
                    Divider().overlay(Color.pd.divider)
                    DataRow(title: "Design review", subtitle: "Conference room B · 45m", value: "3:30 PM")
                    Divider().overlay(Color.pd.divider)
                    DataRow(title: "Monday", subtitle: "Usual 7h 10m", value: "6h 36m")
                }
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}
