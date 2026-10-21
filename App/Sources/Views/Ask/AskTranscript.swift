import PocketdKit
import SwiftUI

/// The conversation, scrolling.
///
/// Its own `View` because it reads `model.conversation` and nothing else: a
/// token arriving invalidates this and not the toolbar, the notice or the
/// composer. It must never read `model.draft` — see the note on `AskComposer`.
///
/// No clock times between messages. They were stamped by this view as messages
/// arrived on screen, so they vanished on every visit and invented a gap
/// wherever a conversation was reopened — decoration that was also wrong. What
/// is worth showing is the day, and only when it changes: a label over a
/// conversation that began before today, and one where a new day starts inside
/// it. That is what tells somebody reopening yesterday's thread that the
/// "tomorrow" in it means today.
struct AskTranscript: View {
    let writes: [PersonalDataWrite]
    let onCompleteReminder: (String) -> Void
    let onUndo: (PersonalDataWrite) -> Void
    let onCopy: (ChatMessage) -> Void
    let onFeedback: (Bool) -> Void
    /// Draws the orb with no generation behind it. Only ever true under the
    /// DEBUG launch argument — see `AskPreviewChat.showsPendingStates`.
    var forcedThinking: Bool = false

    @Environment(AppModel.self) private var model

    /// False once the reader has scrolled away from the bottom, which is the
    /// only reliable sign that they are reading something further up.
    @State private var followsStream = true

    private let bottomAnchor = "pocketd.ask.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let days = daySeparators(now: DemoClock.now)
                LazyVStack(alignment: .leading, spacing: PDSpacing.m) {
                    ForEach(Array(model.conversation.enumerated()), id: \.offset) { index, message in
                        if Self.isDrawn(message) {
                            VStack(alignment: .leading, spacing: PDSpacing.m) {
                                if let day = days[index] {
                                    SectionLabel(day)
                                        .padding(.leading, PDSpacing.xxs)
                                        .padding(.top, index == 0 ? 0 : PDSpacing.xs)
                                }
                                row(message, at: index)
                            }
                            .id(index)
                        }
                    }
                    if isThinking {
                        AskThinkingRow(toolName: forcedThinking ? PersonalDataToolNames.calendar : model.activeToolName)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.s)
                .padding(.bottom, PDSpacing.m)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .conversationScrollEdges()
            // Following is decided by the reader moving, never by the content
            // growing. Judged on geometry alone, a tall card arriving at once —
            // every card, at the largest text sizes — put the bottom out of
            // reach in one step, read as "they scrolled away", and the answer
            // was left sitting under the chip and the composer. The bottom is
            // the bottom of what can be seen, above the bar, not of the frame.
            //
            // And while following, any growth — a card, the thumbs that appear
            // when the answer ends, a taller chip pushing the bar up — keeps
            // the bottom in view. At the largest sizes the last of those come
            // after the last token, so scrolling on tokens alone stopped short.
            .onScrollGeometryChange(for: ScrollPosition.self) { geometry in
                ScrollPosition(
                    isNearBottom: geometry.visibleRect.maxY - geometry.contentInsets.bottom
                        >= geometry.contentSize.height - 80,
                    contentHeight: geometry.contentSize.height,
                    bottomInset: geometry.contentInsets.bottom
                )
            } action: { old, new in
                if old.contentHeight == new.contentHeight, old.bottomInset == new.bottomInset {
                    followsStream = new.isNearBottom
                } else if followsStream, !model.conversation.isEmpty {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: model.conversation.last?.content) { _, _ in
                guard !model.conversation.isEmpty, followsStream else { return }
                // Unanimated on purpose. Animating each token means sixty
                // overlapping scroll animations a second, and on a reply taller
                // than the screen they fight each other into a visible lurch.
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: model.conversation.last?.cards.count) { _, _ in
                guard followsStream else { return }
                withAnimation(PDMotion.standard) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: model.conversation.count) { _, count in
                guard count > 0 else { return }
                // Sending is an explicit request to be at the bottom, wherever
                // the reader had scrolled to.
                followsStream = true
                withAnimation(PDMotion.standard) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            // A conversation reopened from History, or restored on launch,
            // arrives before this view does, so no count ever changes and
            // nothing above scrolls it. Without this, opening it lands on the
            // first thing ever asked.
            //
            // A yield rather than `onAppear`: the `LazyVStack` has built nothing
            // at that point, so there is no bottom to scroll to yet.
            .task(id: model.currentConversationID) {
                guard !model.conversation.isEmpty else { return }
                await Task.yield()
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private struct ScrollPosition: Equatable {
        var isNearBottom: Bool
        var contentHeight: CGFloat
        var bottomInset: CGFloat
    }

    /// "Yesterday", "Monday", "Tue 20 Oct", "Today" — by the index of the
    /// message each one goes above.
    ///
    /// Over the first message when the conversation began before today, and
    /// above any later message said on a different day from the one before it.
    /// A message with no `sentAt` (anything written before the field existed)
    /// is taken to belong to the day before it: an unknown day is never a
    /// reason to draw a separator. A conversation held within today has none.
    private func daySeparators(now: Date) -> [Int: String] {
        let messages = model.conversation
        guard let first = messages.firstIndex(where: { $0.role == .user || $0.role == .assistant }) else { return [:] }
        var labels: [Int: String] = [:]
        var current = messages[first].sentAt ?? model.conversationStartedAt
        if Format.dayGap(from: current, to: now) != 0 {
            labels[first] = Format.day(current, relativeTo: now)
        }
        for index in messages.indices where index > first {
            guard let sent = messages[index].sentAt, Format.dayGap(from: current, to: sent) != 0 else { continue }
            labels[index] = Format.day(sent, relativeTo: now)
            current = sent
        }
        return labels
    }

    /// The orb belongs under the question it is answering, and only while there
    /// is nothing else to look at: once a card or a word lands, that is the
    /// progress indicator.
    private var isThinking: Bool {
        if forcedThinking { return true }
        guard model.isGenerating, let last = model.conversation.last else { return false }
        return last.role == .assistant && last.content.isEmpty && last.cards.isEmpty
    }

    /// Whether a turn has anything to draw. Not the empty slot a reply is
    /// about to be written into — the orb stands in for it until something
    /// arrives — and never a system or tool turn.
    private static func isDrawn(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .user: true
        case .assistant: !(message.content.isEmpty && message.cards.isEmpty)
        case .system, .tool: false
        }
    }

    private func row(_ message: ChatMessage, at index: Int) -> some View {
        let isLast = index == model.conversation.count - 1
        return VStack(alignment: .leading, spacing: PDSpacing.xs) {
            AskMessageRow(
                message: message,
                writes: writes,
                isStreaming: isLast && model.isGenerating,
                onCompleteReminder: onCompleteReminder,
                onUndo: onUndo,
                onCopy: { onCopy(message) }
            )
            if isLast, showsFeedback(for: message) {
                AskFeedbackRow(onFeedback: onFeedback)
                    // A fresh pair per answer rather than one that
                    // remembers the last verdict: two answers are two
                    // questions.
                    .id(model.conversation.count)
            }
        }
    }

    /// Under the latest answer, once it is finished and said something. Not
    /// under a reply that was stopped: there is nothing there to rate.
    private func showsFeedback(for message: ChatMessage) -> Bool {
        guard !model.isGenerating, !forcedThinking, message.role == .assistant else { return false }
        guard !ReplyMarker.isMarkedStopped(message.content) else { return false }
        return !(message.content.isEmpty && message.cards.isEmpty)
    }
}

extension View {
    /// How the conversation meets the glass above and below it.
    ///
    /// Soft under the toolbar: the bar did not find this scroll view on its
    /// own — it sits under a bottom bar and a reader — and a question bubble
    /// drawn crisply behind a glass ✕ reads as two things colliding.
    ///
    /// Hard under the composer, because the composer is a text field: a blue
    /// bubble refracted through glass, under the placeholder somebody is about
    /// to type over, is two lines of text on top of each other.
    @ViewBuilder
    func conversationScrollEdges() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            self
        }
    }
}
