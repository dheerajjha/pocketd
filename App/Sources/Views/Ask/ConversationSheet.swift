import PocketdKit
import SwiftUI

/// The conversation, as a sheet any screen can open.
///
/// It was a tab, and a tab is a place you have to go to: a question about the
/// Sleep tile meant leaving the tile, finding the Ask tab and typing the
/// question again. As a sheet it comes to the question instead — Today, a
/// detail page, Siri and the Control Center button all open this one view, and
/// closing it puts you back exactly where you were.
///
/// Its own `NavigationStack`, the one exception to "no screen brings its own
/// stack": a sheet is a separate presentation with nothing above it to push
/// onto, and the native bar is what gives ✕, History and New chat their
/// system look and their 44pt targets.
///
/// A cloud conversation names its provider above the transcript so it stays
/// readable even when the toolbar hides its title or moves to the side.
///
/// Toasts are its own. The app's toast layer is drawn on the root view, which
/// is underneath this sheet — an "Undo" raised from in here would appear behind
/// the conversation, where nobody can reach it.
struct ConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    let toasts: ToastCenter

    var body: some View {
        @Bindable var navigation = navigator
        NavigationStack {
            AskView()
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let topic = model.conversationTopic {
                            Text("\(topic.label) conversation")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.pd.inkSecondary)
                                .padding(.vertical, PDSpacing.xxs)
                                .accessibilityIdentifier("ask.topic")
                        }
                        providerDisclosure
                    }
                }
                .navigationTitle("Conversation")
                .navigationBarTitleDisplayMode(.inline)
                .hiddenConversationTitle()
                .toolbar { toolbar }
        }
        .environment(toasts)
        // Clear of the composer and the one chip or notice above it, so a
        // toast never sits on the thing it is about.
        .toast(toasts, bottomInset: PDMetric.askBarHeight + PDMetric.minHitTarget + PDSpacing.xl)
        .sheet(isPresented: $navigation.isHistoryPresented) {
            ConversationHistoryView()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.pd.canvas)
    }

    @ViewBuilder
    private var providerDisclosure: some View {
        if model.isUsingPrivateCloudCompute {
            Text(AppleCloudStatus.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.pd.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.vertical, PDSpacing.xxs)
                .frame(maxWidth: .infinity)
                .background(Color.pd.canvas)
                .accessibilityLabel("Selected: \(AppleCloudStatus.title)")
                .accessibilityIdentifier("ask.cloud.provider")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                navigator.isAskPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("ask.close")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                navigator.pendingAsk = nil
                navigator.askHandoff = nil
                navigator.isHistoryPresented = true
            } label: {
                // Not ⏰. That glyph is Routines, in Today's header, and one
                // clock meaning two places is how the old History button got
                // mistaken for the Routines tab.
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Past conversations")
            .accessibilityIdentifier("ask.history")

            NewConversationButton()
        }
    }
}

/// Reading the draft here, rather than in the sheet, keeps each keystroke
/// from invalidating the transcript. A draft is something worth leaving.
private struct NewConversationButton: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    var body: some View {
        Button {
            Haptics.tap()
            navigator.startNewChat(in: model, toasts: toasts)
        } label: { Image(systemName: "square.and.pencil") }
        .accessibilityLabel("New conversation")
        .accessibilityIdentifier("ask.new")
        .disabled(model.conversation.isEmpty && model.draft.isEmpty && model.attachments.isEmpty)
    }
}

extension Navigator {
    /// Both New buttons use the same failure surface and ownership check. A
    /// dismissed sheet or newer selection cannot be switched by a late save.
    func startNewChat(in model: AppModel, toasts: ToastCenter?) {
        let ticket = beginManualSelection()
        Task {
            let result = await model.newConversation(while: { manualSelection == ticket && isAskPresented && !isHistoryPresented })
            guard finishManualSelection(ticket) else { return }
            if result == .saveFailed { toasts?.showSaveFailure() }
        }
    }
}

extension ToastCenter {
    func showSaveFailure() {
        show(ConversationChange.saveFailureMessage, symbol: "exclamationmark.circle", tint: .pd.caution, seconds: 5)
    }
}

private extension View {
    @ViewBuilder
    func hiddenConversationTitle() -> some View {
        if #available(iOS 18.0, *) {
            self.toolbar(removing: .title)
        } else {
            // Keep the navigation title for announcements, without drawing
            // another heading between the same three toolbar controls.
            self.toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
