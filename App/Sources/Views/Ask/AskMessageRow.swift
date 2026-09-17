import PocketdKit
import SwiftUI

/// One turn in the conversation.
///
/// A question is a bubble and an answer is a card, and the asymmetry is the
/// point: what somebody typed is a remark, and what came back is a document —
/// with times, figures and rows in it that a bubble indented away from one
/// margin cannot hold.
struct AskMessageRow: View {
    let message: ChatMessage
    /// Writes still inside their undo window, for whichever card reports one.
    let writes: [PersonalDataWrite]
    let onCompleteReminder: (String) -> Void
    let onUndo: (PersonalDataWrite) -> Void
    let onCopy: () -> Void

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistant
        }
    }

    // MARK: - The question

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: PDSpacing.xxl)
            VStack(alignment: .trailing, spacing: PDSpacing.xs) {
                if !message.images.isEmpty { photos }
                if !message.content.isEmpty {
                    // Left exactly as typed. People write literal asterisks and
                    // mean them, and a message that italicises what somebody
                    // wrote is not the message they sent.
                    Text(message.content)
                        .font(Font.pd.body)
                        .foregroundStyle(Color.pd.onPrimary)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PDSpacing.m)
                        .padding(.vertical, PDSpacing.s)
                        .background(
                            Color.pd.accent,
                            in: RoundedRectangle(cornerRadius: PDRadius.bubble, style: .continuous)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            // 78% of the page. A question that runs the full width stops
            // reading as one side of a conversation.
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.78 }
        }
        .textSelection(.enabled)
        .contextMenu { copyButton }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You said")
        // The context menu is a long press, which VoiceOver spends on its own
        // gestures. The same copy has to exist in the actions rotor.
        .accessibilityAction(named: "Copy message", onCopy)
    }

    /// Shown in the transcript, not just carried to the model. A question about
    /// a picture is unreadable later without the picture, and the conversation
    /// persists.
    private var photos: some View {
        HStack(spacing: PDSpacing.xs) {
            ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous))
                }
            }
        }
        .accessibilityLabel(
            message.images.count == 1
                ? "One attached photo"
                : "\(message.images.count) attached photos"
        )
    }

    // MARK: - The answer

    /// The prose, then the cards.
    ///
    /// The cards are separate surfaces at the full width of the page rather than
    /// contents of the prose card, because a card is a table and the points a
    /// nested surface gives up are points a row of times cannot spare.
    ///
    /// An empty message with cards under it draws no prose card at all. The
    /// engine withholds a narration that only repeated the payload — see
    /// `NarrationEcho` — and an empty bubble above a card that says everything
    /// reads as a reply that failed.
    private var assistant: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            if !message.content.isEmpty {
                PDCard {
                    MessageContentView(text: message.content)
                }
                .contextMenu { copyButton }
                .accessibilityAction(named: "Copy message", onCopy)
            }
            ForEach(Array(message.cards.enumerated()), id: \.offset) { _, card in
                AnswerCardView(
                    card: card,
                    onCompleteReminder: onCompleteReminder,
                    undo: undoOffer(for: card)
                )
                // Lets a reader lift one row rather than the whole answer,
                // which is the same thing the prose's own selection allows.
                .textSelection(.enabled)
                .contextMenu { copyButton }
                .accessibilityAction(named: "Copy message", onCopy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.content.isEmpty ? "Assistant replied" : "Assistant said")
    }

    private func undoOffer(for card: AnswerCard) -> AnswerCardView.UndoOffer? {
        guard let write = WriteUndo.offer(for: card, from: writes) else { return nil }
        return AnswerCardView.UndoOffer(
            expiresAt: write.madeAt.addingTimeInterval(WriteUndo.window),
            action: { onUndo(write) }
        )
    }

    private var copyButton: some View {
        Button("Copy", systemImage: "doc.on.doc", action: onCopy)
    }
}

/// What the reader looks at while the phone thinks.
///
/// The orb rather than a spinner, because seconds of nothing is how a person
/// decides an app is broken — and because a tool turn is two complete prefills
/// they cannot see. When one is running the line says which, in plain words:
/// "Checking your calendar…" is the difference between waiting and worrying.
struct AskThinkingRow: View {
    let toolName: String?

    var body: some View {
        HStack(spacing: PDSpacing.s) {
            ThinkingOrb(size: 24, dotCount: 6)
            Text(toolName.map(AskSuggestion.checkingSentence(forTool:)) ?? "Thinking…")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .animation(PDMotion.gentle, value: toolName)
        .accessibilityElement(children: .combine)
    }
}

/// Was that any good?
///
/// Under the last answer only. A persistent pair under every answer in a long
/// transcript is a row of buttons nobody presses; under the newest one it is a
/// question about something the reader has just read.
struct AskFeedbackRow: View {
    let onFeedback: (Bool) -> Void

    @State private var given: Bool?

    var body: some View {
        HStack(spacing: PDSpacing.xs) {
            button(positive: true, symbol: "hand.thumbsup", label: "Good answer")
            button(positive: false, symbol: "hand.thumbsdown", label: "Poor answer")
            Spacer(minLength: 0)
        }
        .padding(.top, PDSpacing.xxs)
    }

    private func button(positive: Bool, symbol: String, label: String) -> some View {
        let isChosen = given == positive
        return CircleIconButton(
            symbol: isChosen ? "\(symbol).fill" : symbol,
            label: label,
            size: 32,
            tint: isChosen ? .pd.accent : .pd.inkSecondary
        ) {
            guard given == nil else { return }
            given = positive
            onFeedback(positive)
        }
    }
}

#Preview("A turn, light") {
    ScrollView {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            AskMessageRow(
                message: .user("What's on tomorrow?"),
                writes: [],
                onCompleteReminder: { _ in },
                onUndo: { _ in },
                onCopy: {}
            )
            AskMessageRow(
                message: ChatMessage(
                    role: .assistant,
                    content: "Three things tomorrow, and the afternoon is the busy half.",
                    cards: [AnswerCard(
                        source: "calendar",
                        symbol: "calendar",
                        title: "Tomorrow",
                        sections: [.list(AnswerCard.Items(eyebrow: "2 events", items: [
                            AnswerCard.Item(text: "Standup", detail: "Thu 18 Sep, 09:30 – 09:45", symbol: "circle.fill"),
                            AnswerCard.Item(text: "Dentist", detail: "Thu 18 Sep, 17:15 – 18:00 · Marine Drive", symbol: "circle.fill"),
                        ]))]
                    )]
                ),
                writes: [],
                onCompleteReminder: { _ in },
                onUndo: { _ in },
                onCopy: {}
            )
            AskFeedbackRow(onFeedback: { _ in })
            AskThinkingRow(toolName: "calendar")
        }
        .padding(PDSpacing.gutter)
    }
    .pdCanvas()
}

#Preview("A turn, dark") {
    ScrollView {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            AskMessageRow(
                message: .user("Remind me to call the dentist at 4"),
                writes: [],
                onCompleteReminder: { _ in },
                onUndo: { _ in },
                onCopy: {}
            )
            AskThinkingRow(toolName: nil)
        }
        .padding(PDSpacing.gutter)
    }
    .pdCanvas()
    .preferredColorScheme(.dark)
}
