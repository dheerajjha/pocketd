import PocketdKit
import SwiftUI

/// What the conversation looks like before anybody has asked anything.
///
/// Not a placeholder and not a `ContentUnavailableView`. This is the screen that
/// has to answer "what is this for", and the answer is one line and three
/// sentences a person could have typed — quiet rows rather than chips, because
/// the one chip on this sheet is the follow-up above the composer, and three
/// glass capsules here would be a menu.
///
/// No promise about what Pocketd can read. "It can read your calendar,
/// reminders and health" sat directly above a brain that could not, and above a
/// notice saying so; what Pocketd can do right now is the notice's job, and the
/// one source row below is the only claim this screen makes — that Calendar or
/// Reminders is off, and here is the switch.
struct AskEmptyState: View {
    /// Whether the brain in use can read the calendar, reminders and health.
    /// A chat-only brain gets no day examples and no source row: it would
    /// answer "What's on today?" out of nothing, and connecting Calendar
    /// changes nothing for it. The notice under this says what to do instead.
    var readsYourDay: Bool = true
    /// Ask this, or start it in the box.
    let onExample: (AskSuggestion) -> Void
    /// Connect the source that is off.
    let onConnect: (Ability) -> Void
    /// Calendar or Reminders, whichever is off first, or `nil` when both are
    /// on. One row, not two: one thing to do at a time.
    let offSource: Ability?

    /// One column for the three glyphs, so the three sentences start on one
    /// line whatever the width of each symbol. Scaled with the text beside it.
    @ScaledMetric(relativeTo: .body) private var glyphColumn: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.l) {
            Text(readsYourDay ? "Ask about your day." : "Ask Pocketd anything.")
                .font(Font.pd.titleDetail)
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .pdStaggerIn(0)

            if readsYourDay {
                dayContent
            }
        }
        // Full width whatever is in it, so the heading stays on the left
        // when there are no rows to stretch the stack.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.top, PDSpacing.s)
    }

    @ViewBuilder
    private var dayContent: some View {
        if let offSource {
            PDCard {
                SourceRow(
                    symbol: offSource.symbolName,
                    title: offSource.title,
                    detail: Self.detail(for: offSource),
                    accessory: .connect { onConnect(offSource) }
                )
            }
            .pdStaggerIn(1)
        }

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(AskSuggestion.examples.enumerated()), id: \.element.id) { index, example in
                if index > 0 {
                    Rectangle()
                        .fill(Color.pd.divider)
                        .frame(height: 1)
                        .padding(.leading, glyphColumn + PDSpacing.s)
                }
                row(example)
            }
        }
        .pdStaggerIn(2)
    }

    private func row(_ example: AskSuggestion) -> some View {
        Button {
            Haptics.tap()
            onExample(example)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                Image(systemName: example.symbol)
                    .font(Font.pd.body)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .frame(width: glyphColumn)
                    .accessibilityHidden(true)
                Text(example.text)
                    .font(Font.pd.body)
                    .foregroundStyle(Color.pd.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if example.sends {
                    Image(systemName: "arrow.up")
                        .font(Font.pd.chevron)
                        .foregroundStyle(Color.pd.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, PDSpacing.s)
            .frame(minHeight: PDMetric.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(example.text)
        .accessibilityHint(example.sends ? "Asks this question" : "Starts this question for you to finish")
    }

    private static func detail(for ability: Ability) -> String {
        switch ability {
        case .calendar: "So Pocketd can see what's on"
        case .reminders: "So Pocketd can see what's due"
        case .health: "So Pocketd can see sleep and steps"
        case .localServer: ""
        }
    }
}

#Preview("Empty, calendar off") {
    ScrollView {
        AskEmptyState(onExample: { _ in }, onConnect: { _ in }, offSource: .calendar)
    }
    .pdCanvas()
}

#Preview("Empty, all on — dark") {
    ScrollView {
        AskEmptyState(onExample: { _ in }, onConnect: { _ in }, offSource: nil)
    }
    .pdCanvas()
    .preferredColorScheme(.dark)
}

#Preview("Empty, AX") {
    ScrollView {
        AskEmptyState(onExample: { _ in }, onConnect: { _ in }, offSource: .reminders)
    }
    .pdCanvas()
    .dynamicTypeSize(.accessibility3)
}
