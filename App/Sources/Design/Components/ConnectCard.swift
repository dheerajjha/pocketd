import SwiftUI

/// "Let it see your calendar."
///
/// The card that asks for one permission, and the most important card in the
/// app: three of these are the difference between an assistant that knows your
/// day and a chat box.
///
/// The `primer` is the line that raises the acceptance rate more than any copy
/// change — "Next, tap Allow Full Access." — because iOS's own sheet is the
/// screen people actually decline on, and it uses words nobody has been
/// prepared for. It appears only in `.connect`; once a thing is connected,
/// instructions for connecting it are clutter. It is a `Primer`, so the button
/// name can be bolded with `**…**`.
///
/// The simpler app replaces this card with a `SourceRow` (a small Connect pill
/// instead of a second full-width button under the screen's own Continue). It
/// stays for the screens that have not moved yet.
struct ConnectCard: View {
    enum State: Equatable {
        case connect
        case connected
        case needsAttention
    }

    let title: String
    let symbol: String
    let detail: String
    var state: State = .connect
    /// The sentence that prepares somebody for the system sheet. See above.
    var primer: String?
    /// The label on the action. Defaults per state.
    var actionTitle: String?
    var action: () -> Void

    private var resolvedActionTitle: String {
        if let actionTitle { return actionTitle }
        switch state {
        case .connect: return "Connect"
        case .connected: return "Connected"
        case .needsAttention: return "Open Settings"
        }
    }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.m) {
                HStack(alignment: .top, spacing: PDSpacing.m) {
                    IconTile(symbol: symbol, fill: tileFill, tint: tileTint)
                    VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                        // Title and pill share a line only while the title
                        // fits on it whole — "Remind / ers" broke inside the
                        // word beside the pill in v2.
                        if state != .connect {
                            AccessoryRowLayout(spacing: PDSpacing.xs) {
                                titleText
                                StatusPill(
                                    state == .connected ? .positive : .caution,
                                    state == .connected ? "Connected" : "Needs attention"
                                )
                            }
                        } else {
                            titleText
                        }
                        Text(detail)
                            .font(Font.pd.secondary)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .modifier(PDLineSpacing(3, relativeTo: .subheadline))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if state == .connect, let primer {
                    Primer(primer)
                }

                if state != .connected {
                    Button {
                        Haptics.tap()
                        action()
                    } label: {
                        Text(resolvedActionTitle)
                            .font(Font.pd.secondary.weight(.semibold))
                            .foregroundStyle(Color.pd.ink)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, PDSpacing.xs)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: PDMetric.minHitTarget)
                            .background(Color.pd.fillPill, in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.pd.cardStroke, lineWidth: 1)
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(PDPressStyle())
                    .accessibilityLabel("\(resolvedActionTitle) \(title)")
                }
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(Font.pd.headline)
            .foregroundStyle(Color.pd.ink)
    }

    private var tileFill: Color {
        switch state {
        case .connected: .pd.positiveSoft
        case .needsAttention: .pd.cautionSoft
        case .connect: .pd.accentTile
        }
    }

    private var tileTint: Color {
        switch state {
        case .connected: .pd.positive
        case .needsAttention: .pd.caution
        case .connect: .pd.accent
        }
    }
}

#Preview("Connect card light") {
    ConnectCardPreview()
}

#Preview("Connect card dark") {
    ConnectCardPreview().preferredColorScheme(.dark)
}

private struct ConnectCardPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.cardGap) {
                ConnectCard(
                    title: "Calendar",
                    symbol: "calendar",
                    detail: "Ask what's on tomorrow, or have it add an event for you.",
                    state: .connect,
                    primer: "Next, tap **Allow Full Access** so Pocketd can read your calendar."
                ) {}
                ConnectCard(
                    title: "Reminders",
                    symbol: "checklist",
                    detail: "Ask what's overdue, or say \u{201C}remind me at five\u{201D} and it will.",
                    state: .connected
                ) {}
                ConnectCard(
                    title: "Health",
                    symbol: "heart",
                    detail: "Ask how you slept or how active you've been.",
                    state: .needsAttention
                ) {}
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}
