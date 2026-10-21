import SwiftUI

/// "Ask about your day…", pinned to the bottom of Today and of every detail
/// page, with one suggested question floating above it.
///
/// Not a text field. It is the door to the conversation: tapping the field
/// calls `onAsk`, and the screen presents the conversation sheet with the
/// keyboard up. Typing happens there, in `AskBar`, so this owns no focus, no
/// draft and no send button — which is what lets every page carry one without
/// a page-sized pile of state. The suggestion asks its question at once; the
/// mic opens the conversation already listening.
///
/// Exactly one suggestion, chosen for what is on screen ("How did I sleep?" on
/// Today at breakfast, "Was this week better than last?" on Sleep). A row of
/// them is a menu.
///
/// Pin it with `.contextComposer(_:)`, which uses `pdBottomBar`: content
/// scrolls under it and the page fades beneath it rather than colliding.
struct ContextComposer: View {
    /// The one suggested question above the field.
    struct Suggestion {
        var text: String
        var symbol: String?
        var action: () -> Void

        init(_ text: String, symbol: String? = nil, action: @escaping () -> Void) {
            self.text = text
            self.symbol = symbol
            self.action = action
        }
    }

    var suggestion: Suggestion?
    /// "Ask about your day…" on Today; "Ask anything else" on a detail page,
    /// where the page above is already one answer.
    var placeholder: String = "Ask about your day…"
    /// The field was tapped: present the conversation, focused.
    let onAsk: () -> Void
    /// The mic was tapped: present the conversation, listening. Nil hides the
    /// mic — a phone without on-device speech has no mic anywhere.
    var onMic: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            if let suggestion {
                SuggestionChip(suggestion.text, symbol: suggestion.symbol, action: suggestion.action)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            field
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(PDMotion.gentle, value: suggestion?.text)
    }

    private var fieldShape: RoundedRectangle {
        // A capsule at one line; past that (a long placeholder at the largest
        // text sizes) a rounded rectangle, rather than a lozenge.
        RoundedRectangle(cornerRadius: PDMetric.askBarHeight / 2, style: .continuous)
    }

    private var field: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.tap()
                onAsk()
            } label: {
                Text(placeholder)
                    .font(Font.pd.body)
                    // A placeholder's look, but the secondary grey rather than
                    // the system's lighter one: this is the label of a button,
                    // and it has to pass contrast like one.
                    .foregroundStyle(Color.pd.inkSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, PDSpacing.l)
                    .padding(.trailing, onMic == nil ? PDSpacing.l : PDSpacing.xs)
                    .padding(.vertical, PDSpacing.xs)
                    .frame(minHeight: PDMetric.askBarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PDPressStyle())
            .accessibilityLabel(placeholder.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")))
            .accessibilityHint("Opens the conversation")

            if let onMic {
                Button {
                    Haptics.tap()
                    onMic()
                } label: {
                    Image(systemName: "mic")
                        .font(Font.pd.body)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .pdHitTarget()
                }
                .buttonStyle(PDPressStyle())
                .padding(.trailing, PDSpacing.xs)
                .accessibilityLabel("Ask by voice")
            }
        }
        .frame(minHeight: PDMetric.askBarHeight)
        .pdGlass(fieldShape, interactive: true)
    }
}

extension View {
    /// Pins `composer` to the bottom of this screen, with the gutter around it.
    ///
    ///     ScrollView { … }
    ///         .contextComposer(ContextComposer(
    ///             suggestion: .init("How did I sleep?") { ask("How did I sleep?") },
    ///             onAsk: { openConversation() },
    ///             onMic: { openConversation(listening: true) }
    ///         ))
    func contextComposer(_ composer: ContextComposer, scrim: Color = .pd.canvas) -> some View {
        pdBottomBar(scrim: scrim) {
            composer
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.xs)
                .padding(.bottom, PDSpacing.xs)
        }
    }
}

#Preview("Context composer light") {
    ContextComposerPreview()
}

#Preview("Context composer dark") {
    ContextComposerPreview().preferredColorScheme(.dark)
}

private struct ContextComposerPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.cardGap) {
                ForEach(0..<6, id: \.self) { index in
                    PDCard {
                        Text("Content \(index + 1) scrolls under the composer.")
                            .font(Font.pd.body)
                            .foregroundStyle(Color.pd.ink)
                    }
                }
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
        .contextComposer(ContextComposer(
            suggestion: .init("How did I sleep?") {},
            onAsk: {},
            onMic: {}
        ))
    }
}
