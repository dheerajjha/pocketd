import PocketdKit
import SwiftUI

/// Assistant instructions: a sentence or two Pocketd reads before every
/// conversation on this iPhone.
///
/// A page under Advanced rather than a sheet on the You root. It is a system
/// prompt, and most people never need one; the ones who do want room to read
/// what they wrote. The copy says what it does and leaves out the old warning
/// about every word costing the conversation room — true, and nothing a person
/// can act on except by keeping it short, which is what the page asks for.
///
/// Read by both brains (the built-in one folds it into its own instructions)
/// and by routines; never by other devices, whose requests bring their own.
struct InstructionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @FocusState private var focused: Bool

    /// What a fresh install reads. Kept in step with `AppModel.systemPrompt`'s
    /// initial value, which is where it actually comes from.
    static let standard = "You are a helpful assistant."

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isUnchanged: Bool { trimmedDraft == model.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        YouDetailScreen(
            title: "Assistant instructions",
            subtitle: "Pocketd reads this before every conversation on this iPhone. A sentence or two works best."
        ) {
            PDCard(padding: PDSpacing.m) {
                TextEditor(text: $draft)
                    .font(Font.pd.body)
                    .foregroundStyle(Color.pd.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .focused($focused)
                    .accessibilityLabel("Assistant instructions")
            }

            Text("For example: \u{201C}Keep answers to two sentences.\u{201D}")
                .font(Font.pd.footnote)
                .foregroundStyle(Color.pd.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PDSpacing.xxs)

            VStack(spacing: PDSpacing.xxs) {
                PrimaryButton(title: "Save", arrow: false, isEnabled: !isUnchanged) {
                    model.systemPrompt = trimmedDraft
                    Haptics.success()
                    focused = false
                    toasts.show("Saved")
                    dismiss()
                }
                if trimmedDraft != Self.standard {
                    SecondaryLink("Use the standard one") {
                        draft = Self.standard
                    }
                }
            }
            .padding(.top, PDSpacing.xs)
        }
        .onAppear { draft = model.systemPrompt }
    }
}

// MARK: - Previews

#Preview("Instructions light") {
    NavigationStack { InstructionsView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Instructions dark") {
    NavigationStack { InstructionsView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
