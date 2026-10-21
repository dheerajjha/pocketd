import PocketdKit
import SwiftUI

// The pieces the four detail pages share: a labelled group, rows in one card,
// the "Show N more" pill, and the way out for a source that is not connected.
// Built from A1's components; nothing here draws a surface of its own.

// MARK: - A labelled group

/// NOW · LATER TODAY · LAST 7 NIGHTS, and the card it labels.
///
/// The label sits closer to its own card than to the card above it, so a page
/// of three groups reads as three groups rather than as six things evenly
/// spaced — which is what a label straight inside `DetailPage`'s 16pt stack
/// would be.
struct PageSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            SectionLabel(title)
            content
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Rows in one card

/// Rows inside one white card, a hairline between each, and an optional
/// footer (the "Show N more" pill) under the last.
///
/// The first row starts at the card's own padding and the last ends at it:
/// padding every row evenly would leave a gap above the first that the card's
/// padding already provides.
struct RowCard<Item: Identifiable, Row: View, Footer: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row
    @ViewBuilder var footer: Footer

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row, @ViewBuilder footer: () -> Footer) {
        self.items = items
        self.row = row
        self.footer = footer()
    }

    var body: some View {
        PDCard(padding: PDSpacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().overlay(Color.pd.divider)
                    }
                    row(item)
                        .padding(.top, index == 0 ? PDSpacing.xxs : PDSpacing.s)
                        .padding(.bottom, index == items.count - 1 ? PDSpacing.xxs : PDSpacing.s)
                }
                footer
            }
        }
    }
}

extension RowCard where Footer == EmptyView {
    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.init(items, row: row) { EmptyView() }
    }
}

// MARK: - Show N more

/// "Show 3 more" / "Show less": a small warm pill, centred under a group.
///
/// A pill rather than a link because it does not go anywhere — it opens the
/// group it sits in. Drawn 28pt tall, tappable at 44.
struct ShowMoreButton: View {
    let hiddenCount: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(isExpanded ? "Show less" : "Show \(hiddenCount) more")
                .font(Font.pd.footnote.weight(.semibold))
                .foregroundStyle(Color.pd.inkSecondaryWarm)
                .padding(.horizontal, PDSpacing.m)
                .padding(.vertical, PDSpacing.xxs)
                .frame(minHeight: 28)
                .background(Color.pd.fillWarm, in: Capsule(style: .continuous))
                .pdHitTarget()
        }
        .buttonStyle(PDPressStyle())
        .frame(maxWidth: .infinity)
        .padding(.top, PDSpacing.xs)
        .accessibilityHint(isExpanded ? "Shows fewer" : "Shows the rest of this group")
    }
}

// MARK: - A source that is not connected

/// The way out on a page whose source is off: the one connect door, or the
/// Settings app when iOS has already said no.
///
/// Only the action; the page's own summary is the sentence ("Connect your
/// calendar to see your day here."), and saying it twice would be a card
/// apologising under a heading that already did.
struct ConnectSourceLink: View {
    @Environment(AppModel.self) private var model

    let ability: Ability
    let availability: TodaySnapshot.Availability

    var body: some View {
        switch availability {
        case .off:
            TextLink("Connect \(ability.title)") { connect() }
        case .refused:
            TextLink("Open Settings", symbol: "arrow.up.right") { connect() }
        case .connected, .unavailable:
            EmptyView()
        }
    }

    /// Through the door in both cases: it raises the iOS sheet when iOS has
    /// never been asked and opens Settings when it refused, and it reads the
    /// day again afterwards so this page fills in without another tap.
    private func connect() {
        Task { await model.connect(ability, from: .today) }
    }
}
