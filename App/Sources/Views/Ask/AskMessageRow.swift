import PocketdKit
import SwiftUI

/// One turn in the conversation.
///
/// A question is a bubble and an answer is a card, and the asymmetry is the
/// point: what somebody typed is a remark, and what came back is a document —
/// with times, figures and rows in it that a bubble indented away from one
/// margin cannot hold.
///
/// One card per answer. The sentence the brain wrote is the card's lead, and
/// what the tools read — the day's events, the overdue reminders, last night's
/// sleep — sits underneath it in the same card. It used to be two surfaces, a
/// prose card and a data card, and a reader had to work out that they were one
/// reply.
struct AskMessageRow: View {
    let message: ChatMessage
    /// Writes still inside their undo window, for whichever block reports one.
    let writes: [PersonalDataWrite]
    /// The reply being written right now, so an answer whose data arrived
    /// before its sentence can say the sentence is coming.
    var isStreaming: Bool = false
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
                        .modifier(PDLineSpacing(4, relativeTo: .body))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(message.content)")
        // The context menu is a long press, which VoiceOver spends on its own
        // gestures. The same copy has to exist in the actions rotor.
        .accessibilityAction(named: "Copy", onCopy)
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

    @ViewBuilder
    private var assistant: some View {
        let answer = Answer(message)
        if answer.isOnlyStopped {
            StoppedLine()
                .accessibilityLabel("Pocketd: stopped")
        } else {
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.m) {
                    if let lead = answer.lead {
                        AnswerText(text: lead, isAboutData: !message.cards.isEmpty)
                    } else if isStreaming {
                        // The data came first, as it does when a tool runs, and
                        // the sentence about it is still being written.
                        WritingDots()
                    }
                    ForEach(Array(message.cards.enumerated()), id: \.offset) { index, card in
                        let omitsLede = index == 0 && answer.leadIsFirstCardsLede
                        let undo = undoOffer(for: card)
                        if index > 0 {
                            Rectangle()
                                .fill(Color.pd.divider)
                                .frame(height: 1)
                        }
                        // A write whose sentence is already the lead, once its
                        // Undo has expired, has nothing left to draw — and an
                        // empty block still costs the card a gap.
                        if !(omitsLede && card.sections.isEmpty && undo == nil) {
                            AnswerCardView(
                                card: card,
                                onCompleteReminder: onCompleteReminder,
                                undo: undo,
                                omitsLede: omitsLede
                            )
                        }
                    }
                    if answer.wasStopped {
                        StoppedLine()
                    }
                }
            }
            // Lets a reader lift one row rather than the whole answer.
            .textSelection(.enabled)
            .contextMenu { copyButton }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pocketd")
            .accessibilityAction(named: "Copy", onCopy)
        }
    }

    private func undoOffer(for card: AnswerCard) -> AnswerCardView.UndoOffer? {
        guard let write = WriteUndo.offer(for: card, from: writes),
              // A block already rewritten to say it was undone still names the
              // title, and must not pick up the Undo of a second write of it.
              card.lede != WriteUndo.undoneSentence(for: write)
        else { return nil }
        return AnswerCardView.UndoOffer(
            expiresAt: write.madeAt.addingTimeInterval(WriteUndo.window),
            action: { onUndo(write) }
        )
    }

    private var copyButton: some View {
        Button("Copy", systemImage: "doc.on.doc", action: onCopy)
    }
}

// MARK: - Taking an answer apart

/// What an assistant turn says, sorted into the parts the card draws.
///
/// The "Stopped." marker is the reader's, written by `ReplyMarker` when a reply
/// was cut short, and it is drawn as a quiet line of its own rather than as
/// the answer's lead: a stopped reply is not something Pocketd said.
///
/// A write's own sentence ("Reminder set: “Call Mom” for 6:00 PM.") becomes
/// the lead when the brain said nothing else — the engine withholds a
/// narration that only repeated the payload — so the card still opens with
/// its answer instead of with a header.
private struct Answer {
    var lead: String?
    var leadIsFirstCardsLede = false
    var wasStopped = false
    var isOnlyStopped = false

    init(_ message: ChatMessage) {
        wasStopped = ReplyMarker.isMarkedStopped(message.content)
        let words = ReplyMarker.strippingStopped(message.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLede = message.cards.first?.lede.flatMap { $0.isEmpty ? nil : $0 }
        if let write = Self.writeSentence(in: message) {
            // A write leads with the tool's own sentence, which always names
            // the day — "Reminder set: “Call Mom” for tomorrow at 6:00 PM." The
            // brain's version ("Reminder set: call mom at 6:00 PM.") dropped
            // the day while the block under it said Thursday.
            lead = write
            leadIsFirstCardsLede = true
        } else if !words.isEmpty {
            lead = words
            // A write that was undone says so in both places — see
            // `AppModel.markWriteUndone` — and once is enough.
            leadIsFirstCardsLede = words == firstLede
        } else if let firstLede {
            lead = firstLede
            leadIsFirstCardsLede = true
        }
        isOnlyStopped = wasStopped && lead == nil && message.cards.isEmpty
    }

    /// The sentence a write reported, when that one write is the whole answer:
    /// a calendar or reminders block with a sentence and no rows, and not a
    /// refusal (those carry the padlock).
    static func writeSentence(in message: ChatMessage) -> String? {
        guard message.cards.count == 1, let card = message.cards.first,
              card.sections.isEmpty, card.symbol != "lock",
              card.source == PersonalDataToolNames.calendar || card.source == PersonalDataToolNames.reminders,
              let lede = card.lede, !lede.isEmpty
        else { return nil }
        return lede
    }
}

/// The brain's words, at the size an answer deserves.
///
/// The sentence over the data — "Three things today, and the dentist is at
/// 4:30." — is the card's lead, in the lead face: it is the answer, and the
/// rows under it are the evidence. Everything else is prose and goes through
/// `MessageContentView` at body size: a story or a recipe set in 20pt is a
/// wall.
///
/// Decided by whether the answer drew something, not by how long the words
/// are, because the words arrive one at a time. Judged on length, an answer
/// began in the lead face and dropped to body size mid-sentence the moment it
/// grew past the limit — the whole reply jumping under the reader's eyes. A
/// tool's card arrives before the sentence about it, so this is settled
/// before the first word lands.
private struct AnswerText: View {
    let text: String
    /// The answer has a data block under it.
    let isAboutData: Bool

    var body: some View {
        if isAboutData, Self.isOneParagraph(text) {
            // In the app's spelling — "3:00 PM", "1 overdue reminder" — so the
            // sentence agrees with the rows under it. See `AnswerWords`.
            Text(Self.inline(AnswerWords.screened(text)))
                .pdLead()
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MessageContentView(text: text)
        }
    }

    static func isOneParagraph(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        guard MessageMarkdown.splitReasoning(from: text).reasoning == nil else { return false }
        let blocks = MessageMarkdown.blocks(of: text)
        guard blocks.count == 1, case .paragraph = blocks[0] else { return false }
        return true
    }

    /// Bold and italics survive; nothing else in one paragraph needs to.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// "Stopped." — quiet, grey, and never in a card of its own.
private struct StoppedLine: View {
    var body: some View {
        Label(ReplyMarker.stopped, systemImage: "stop.circle")
            .font(Font.pd.secondary)
            .foregroundStyle(Color.pd.inkSecondary)
            .padding(.leading, PDSpacing.xxs)
    }
}

/// Three dots in the lead's place while the sentence is on its way.
///
/// Still under Reduce Motion: the dots are a word ("still writing"), and they
/// say it without moving.
private struct WritingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let lit = reduceMotion ? -1 : Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(lit == index ? 1 : 0.35)
                }
            }
            .foregroundStyle(Color.pd.inkTertiary)
        }
        .frame(minHeight: 24, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Writing")
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
                .accessibilityHidden(true)
            Text(toolName.map(AskSuggestion.checkingSentence(forTool:)) ?? "Thinking…")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.leading, PDSpacing.xxs)
        .animation(PDMotion.gentle, value: toolName)
        .accessibilityElement(children: .combine)
    }
}

/// Was that any good?
///
/// Under the latest answer only. A pair under every answer in a long
/// transcript is a row of buttons nobody presses; under the newest one it is a
/// question about something the reader has just read. Drawn small, and a full
/// 44pt to a finger.
struct AskFeedbackRow: View {
    let onFeedback: (Bool) -> Void

    @State private var given: Bool?

    var body: some View {
        HStack(spacing: 0) {
            button(positive: true, symbol: "hand.thumbsup", label: "Good answer")
            button(positive: false, symbol: "hand.thumbsdown", label: "Poor answer")
            Spacer(minLength: 0)
        }
        // The targets overhang the gap above rather than pushing the next
        // question further down.
        .padding(.top, -PDSpacing.xs)
        .padding(.leading, -6)
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
        .accessibilityAddTraits(isChosen ? .isSelected : [])
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
                    content: "Two things tomorrow, and the afternoon is the busy half.",
                    cards: [AnswerCard(
                        source: "calendar",
                        symbol: "calendar",
                        title: "Tomorrow",
                        sections: [.list(AnswerCard.Items(eyebrow: "2 events", items: [
                            AnswerCard.Item(text: "Standup", detail: "Thu, Oct 22, 9:30 AM – 9:45 AM", symbol: "circle.fill"),
                            AnswerCard.Item(text: "Dentist", detail: "Thu, Oct 22, 5:15 PM – 6:00 PM · Marine Drive", symbol: "circle.fill"),
                        ]))]
                    )]
                ),
                writes: [],
                onCompleteReminder: { _ in },
                onUndo: { _ in },
                onCopy: {}
            )
            AskFeedbackRow(onFeedback: { _ in })
            AskMessageRow(
                message: .assistant("Stopped."),
                writes: [],
                onCompleteReminder: { _ in },
                onUndo: { _ in },
                onCopy: {}
            )
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
            AskMessageRow(
                message: ChatMessage(role: .assistant, content: "", cards: [AnswerCard(
                    source: "reminders",
                    symbol: "checklist",
                    title: "Reminders",
                    lede: "Reminder set: “Call the dentist” for 4:00 PM."
                )]),
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
