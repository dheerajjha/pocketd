import PocketdKit
import SwiftUI

/// The conversation, scrolling.
///
/// Its own `View` because it reads `model.conversation` and nothing else: a
/// token arriving invalidates this and not the header, the notices or the
/// composer. It must never read `model.draft` — see the note on `AskComposer`.
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

    /// When a message first appeared here. `ChatMessage` carries no clock, and
    /// within a conversation the indices only grow, so an index is a stable key
    /// for as long as the times mean anything. Messages this view did not watch
    /// arrive are simply absent rather than guessed at.
    @State private var arrived: [Int: Date] = [:]
    /// False once the reader has scrolled away from the bottom, which is the
    /// only reliable sign that they are reading something further up.
    @State private var followsStream = true

    private let bottomAnchor = "pocketd.ask.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PDSpacing.m) {
                    ForEach(Array(model.conversation.enumerated()), id: \.offset) { index, message in
                        VStack(alignment: .leading, spacing: PDSpacing.xs) {
                            if let stamp = timeSeparator(at: index) {
                                Text(stamp, format: .dateTime.hour().minute())
                                    .font(Font.pd.miniLabel)
                                    .foregroundStyle(Color.pd.inkTertiary)
                                    .frame(maxWidth: .infinity)
                            }
                            row(message, at: index)
                        }
                        .id(index)
                    }
                    if isThinking {
                        AskThinkingRow(toolName: forcedThinking ? PersonalDataToolNames.calendar : model.activeToolName)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.xs)
                .padding(.bottom, PDSpacing.l)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 80
            } action: { _, isNearBottom in
                followsStream = isNearBottom
            }
            .onChange(of: model.conversation.last?.content) { _, _ in
                guard !model.conversation.isEmpty, followsStream else { return }
                // Unanimated on purpose. Animating each token means sixty
                // overlapping scroll animations a second, and on a reply taller
                // than the screen they fight each other into a visible lurch.
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: model.conversation.count) { previous, count in
                guard count > 0 else { return }
                stampArrivals(upTo: count, grownFrom: previous)
                // Sending is an explicit request to be at the bottom, wherever
                // the reader had scrolled to.
                followsStream = true
                withAnimation(PDMotion.standard) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            // A conversation restored on launch arrives before this view does,
            // so no count ever changes and nothing above scrolls it. Without
            // this, reopening the app lands on the first thing you ever asked.
            //
            // A yield rather than `onAppear`: the `LazyVStack` has built nothing
            // at that point, so there is no bottom to scroll to yet.
            .task {
                guard !model.conversation.isEmpty else { return }
                await Task.yield()
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    /// The orb belongs under the reply it is waiting for, and only while there
    /// is nothing else to look at: once a token lands, the words are the
    /// progress indicator.
    private var isThinking: Bool {
        if forcedThinking { return true }
        guard model.isGenerating, let last = model.conversation.last else { return false }
        return last.role == .assistant && last.content.isEmpty
    }

    @ViewBuilder
    private func row(_ message: ChatMessage, at index: Int) -> some View {
        AskMessageRow(
            message: message,
            writes: writes,
            onCompleteReminder: onCompleteReminder,
            onUndo: onUndo,
            onCopy: { onCopy(message) }
        )
        if showsFeedback(at: index) {
            AskFeedbackRow(onFeedback: onFeedback)
                // A fresh pair per answer rather than one that remembers the
                // last verdict: two answers are two questions.
                .id(index)
        }
    }

    /// Under the last answer, once it is finished and has something in it.
    private func showsFeedback(at index: Int) -> Bool {
        guard !model.isGenerating, !forcedThinking, index == model.conversation.count - 1 else { return false }
        let message = model.conversation[index]
        return message.role == .assistant && !(message.content.isEmpty && message.cards.isEmpty)
    }

    // MARK: - Timestamps

    /// Sending appends the question and the empty answer together, so a turn
    /// grows the conversation by two. A larger jump is a conversation being
    /// restored, and those messages were written whenever they were written —
    /// stamping them "now" would be the view inventing history.
    private func stampArrivals(upTo count: Int, grownFrom previous: Int) {
        guard count - previous <= 2 else { return }
        for index in 0..<count where arrived[index] == nil {
            arrived[index] = DemoClock.now
        }
    }

    /// A time is worth showing where there is a gap worth noticing. Under every
    /// bubble of a conversation held in one sitting it is decoration, and the
    /// send and the reply it triggers would carry the same minute twice over.
    private func timeSeparator(at index: Int) -> Date? {
        guard let arrival = arrived[index] else { return nil }
        // An unknown neighbour is an unknown gap, which is exactly the case a
        // time answers: this is where the conversation was picked back up.
        guard index > 0, let previous = arrived[index - 1] else { return arrival }
        return arrival.timeIntervalSince(previous) >= 300 ? arrival : nil
    }
}
