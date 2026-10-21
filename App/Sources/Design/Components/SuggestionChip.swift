import SwiftUI

/// "What's on tomorrow?"
///
/// The one suggested question that floats above a composer. The chips are the
/// answer to the blank-page problem: an assistant that can read your calendar
/// is useless if nobody knows to ask it about the calendar. They are written
/// as the question a person would type, in sentence case with the question
/// mark, because that is what makes them read as examples rather than as
/// buttons.
///
/// **One at a time.** A row of three is a menu, and the third one scrolls off
/// the edge of the phone; one chip, chosen for what is on screen, is a
/// suggestion. This is why there is no chip flow layout in the system any
/// more. `ContextComposer` places it.
///
/// It floats, so it is glass (`pdGlass`) and 44pt tall: the visible chip *is*
/// the tap target.
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
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                Text(text)
                    .font(Font.pd.secondary.weight(.medium))
                    .foregroundStyle(Color.pd.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, PDSpacing.m)
            .padding(.vertical, PDSpacing.xs)
            .frame(minHeight: PDMetric.minHitTarget)
            .pdGlass(interactive: true)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(text)
        .accessibilityHint("Asks this question")
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
            SuggestionChip("What's on tomorrow?") {}
            SuggestionChip("Remind me to…", symbol: "bell") {}
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pdCanvas()
    }
}
