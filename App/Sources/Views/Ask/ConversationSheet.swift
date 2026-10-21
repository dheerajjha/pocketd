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
/// No title in the bar. Three controls and the conversation under them say
/// what this is; a word in the middle of the bar would be the one thing on the
/// screen nobody reads. The title is kept for VoiceOver, which announces the
/// screen it lands on.
///
/// Toasts are its own. The app's toast layer is drawn on the root view, which
/// is underneath this sheet — an "Undo" raised from in here would appear behind
/// the conversation, where nobody can reach it.
struct ConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var toasts = ToastCenter()
    @State private var isShowingHistory = false

    var body: some View {
        NavigationStack {
            AskView()
                .navigationTitle("Conversation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbar { toolbar }
        }
        .environment(toasts)
        // Clear of the composer and the one chip or notice above it, so a
        // toast never sits on the thing it is about.
        .toast(toasts, bottomInset: PDMetric.askBarHeight + PDMetric.minHitTarget + PDSpacing.xl)
        .sheet(isPresented: $isShowingHistory) {
            ConversationHistoryView()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.pd.canvas)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                isShowingHistory = true
            } label: {
                // Not ⏰. That glyph is Routines, in Today's header, and one
                // clock meaning two places is how the old History button got
                // mistaken for the Routines tab.
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Past conversations")

            Button {
                Haptics.tap()
                Task { await model.newConversation() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New conversation")
            // Nothing to leave yet. A blank page that offers a blank page is
            // a button that does nothing, which reads as broken.
            .disabled(model.conversation.isEmpty)
        }
    }
}
