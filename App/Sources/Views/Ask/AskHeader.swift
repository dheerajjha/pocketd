import PocketdKit
import SwiftUI

/// The bar across the top of Ask: history, the word "Ask", a new conversation.
///
/// Not a `NavigationStack` toolbar. This screen has no navigation bar, because a
/// system bar would spend 96pt saying one word and would draw a hard line across
/// the top of a page whose whole point is that it runs off the edges.
struct AskHeader: View {
    let onHistory: () -> Void
    let onNew: () -> Void

    var body: some View {
        ZStack {
            Text("Ask")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.pd.ink)

            HStack {
                CircleIconButton(
                    symbol: "clock.arrow.circlepath",
                    label: "Past conversations",
                    action: onHistory
                )
                Spacer(minLength: 0)
                CircleIconButton(
                    symbol: "plus",
                    label: "New conversation",
                    action: onNew
                )
            }
        }
        .padding(.horizontal, PDSpacing.gutter)
    }
}

/// What is thinking, in one line, under the title.
///
/// The model has a name and the name is not the point: somebody who has never
/// heard the word "model" needs to know whether there is anything in there at
/// all, and what to do if there is not. So the state is first — ready, loading,
/// missing — and the real name sits beside it for the one person in fifty who
/// wants it.
struct AskBrainChip: View {
    let name: String?
    let isLoading: Bool
    let onChoose: () -> Void

    private var dot: Color {
        if name != nil { return .pd.positive }
        return isLoading ? .pd.caution : .pd.inkTertiary
    }

    private var text: String {
        if let name { return "\(name) · ready" }
        return isLoading ? "Loading brain…" : "No brain"
    }

    var body: some View {
        HStack(spacing: PDSpacing.xs) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Font.pd.caption)
                .foregroundStyle(Color.pd.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if name == nil, !isLoading {
                Button(action: onChoose) {
                    Text("Choose")
                        .font(Font.pd.caption.weight(.semibold))
                        .foregroundStyle(Color.pd.accent)
                }
                .buttonStyle(PDPressStyle())
            }
        }
        .padding(.horizontal, PDSpacing.s)
        .frame(height: 28)
        .background(Color.pd.chip, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text)
    }
}

#Preview("Header light") {
    VStack(spacing: PDSpacing.m) {
        AskHeader(onHistory: {}, onNew: {})
        AskBrainChip(name: "Qwen3 1.7B", isLoading: false, onChoose: {})
        AskBrainChip(name: nil, isLoading: true, onChoose: {})
        AskBrainChip(name: nil, isLoading: false, onChoose: {})
    }
    .padding(.vertical, PDSpacing.xl)
    .pdCanvas()
}

#Preview("Header dark") {
    VStack(spacing: PDSpacing.m) {
        AskHeader(onHistory: {}, onNew: {})
        AskBrainChip(name: "Qwen3 1.7B", isLoading: false, onChoose: {})
        AskBrainChip(name: nil, isLoading: false, onChoose: {})
    }
    .padding(.vertical, PDSpacing.xl)
    .pdCanvas()
    .preferredColorScheme(.dark)
}
