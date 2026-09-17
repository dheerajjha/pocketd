import PocketdKit
import SwiftUI

/// What Ask looks like before anybody has asked anything.
///
/// Not a placeholder and not a `ContentUnavailableView`. This is the screen that
/// has to answer "what is this for", and the answer is four sentences a person
/// can tap — one per thing the phone can actually see, plus one that shows it
/// can change something rather than only look it up.
struct AskEmptyState: View {
    /// Send this question now.
    let onAsk: (AskSuggestion) -> Void
    /// Switch on what this question needs, first.
    let onConnect: (Ability) -> Void
    /// Whether the ability a row needs is already on.
    let isOn: (Ability) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                Text("Ask anything about\nyour day.")
                    .font(Font.pd.titleDetail)
                    .tracking(-0.4)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It can read your calendar, reminders and health, and set reminders for you.")
                    .pdSubtitle()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, PDSpacing.xs)
            .pdStaggerIn(0)

            ForEach(Array(AskSuggestion.openings.enumerated()), id: \.element.id) { index, opening in
                row(opening)
                    .pdStaggerIn(index + 1)
            }
        }
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.top, PDSpacing.s)
    }

    @ViewBuilder
    private func row(_ opening: AskSuggestion) -> some View {
        let needsConnecting = opening.ability.map { !isOn($0) } ?? false

        Button {
            if let ability = opening.ability, needsConnecting {
                onConnect(ability)
            } else {
                onAsk(opening)
            }
        } label: {
            PDCard(padding: PDSpacing.m, radius: PDRadius.smallCard) {
                HStack(spacing: PDSpacing.s) {
                    IconTile.small(opening.symbol)
                    Text(opening.text)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if needsConnecting {
                        connectPill
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.pd.inkTertiary)
                    }
                }
            }
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(opening.text)
        .accessibilityHint(needsConnecting ? "Turns on what this needs first" : "Asks this question")
    }

    /// Deliberately the same grey pill the reference uses for "Connect", not a
    /// coloured call to action. Being off is a choice somebody made, and a row
    /// that shouts at them for it is the thing this app does not do.
    private var connectPill: some View {
        Text("Connect")
            .font(Font.pd.caption.weight(.semibold))
            .foregroundStyle(Color.pd.ink)
            .padding(.horizontal, PDSpacing.s)
            .frame(height: PDMetric.linkPillHeight + 4)
            .background(Color.pd.fillPill, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1))
    }
}

#Preview("Empty, nothing connected") {
    ScrollView {
        AskEmptyState(onAsk: { _ in }, onConnect: { _ in }, isOn: { _ in false })
    }
    .pdCanvas()
}

#Preview("Empty, all connected — dark") {
    ScrollView {
        AskEmptyState(onAsk: { _ in }, onConnect: { _ in }, isOn: { _ in true })
    }
    .pdCanvas()
    .preferredColorScheme(.dark)
}
