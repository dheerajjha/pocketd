import SwiftUI

/// The composer, pinned above the tab bar.
///
/// A 52pt capsule floating over the conversation rather than a bar attached to
/// the bottom of it, which is what lets the last message scroll under it
/// instead of being cut off by it.
///
/// The mic is hold-to-talk and the send button only appears when there is
/// something to send — two controls in the same 36pt slot, because a permanent
/// disabled arrow next to a permanent mic is two dead controls at the exact
/// place a person is looking for one live one.
struct AskBar: View {
    @Binding var text: String
    var placeholder: String = "Ask anything"
    var isListening: Bool = false
    var canSend: Bool = false
    /// Hidden entirely when the device cannot recognise speech on-device. A mic
    /// that would have to upload audio does not belong in this app.
    var showsMic: Bool = true
    var onMic: () -> Void = {}
    var onMicEnd: () -> Void = {}
    var onSend: () -> Void = {}
    var onAttach: (() -> Void)?
    /// A focus state owned by the screen, for the callers that have to put the
    /// cursor here without a tap — a phrase from Siri, the Control Center
    /// button, a question handed over from Today. `nil` keeps the bar's own.
    var focus: FocusState<Bool>.Binding?

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: PDSpacing.xs) {
            if let onAttach {
                Button {
                    Haptics.tap()
                    onAttach()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.pd.inkSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(PDPressStyle())
                .accessibilityLabel("Add a photo")
            }

            TextField(isListening ? "Listening…" : placeholder, text: $text, axis: .vertical)
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.ink)
                .tint(Color.pd.accent)
                .lineLimit(1...4)
                .focused(focus ?? $isFocused)
                .submitLabel(.send)
                .disabled(isListening)

            trailingControl
        }
        .padding(.horizontal, PDSpacing.s)
        .padding(.vertical, PDSpacing.xs)
        .frame(minHeight: PDMetric.askBarHeight)
        .background(Color.pd.fillFloat, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isListening ? Color.pd.accent : Color.pd.cardStroke, lineWidth: 1)
        )
        .pdFloatShadow()
        .animation(PDMotion.gentle, value: canSend)
        .animation(PDMotion.gentle, value: isListening)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if canSend {
            Button {
                Haptics.send()
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.pd.onPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.pd.primaryButton, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PDPressStyle())
            .accessibilityLabel("Send")
        } else if showsMic {
            Image(systemName: isListening ? "waveform" : "mic")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(isListening ? Color.pd.onPrimary : Color.pd.inkSecondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(isListening ? Color.pd.accent : Color.clear)
                )
                .contentShape(Circle())
                // A long-press gesture rather than a Button, because this is
                // hold-to-talk: the press start and the release are both
                // events, and a Button only reports the end of one.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isListening else { return }
                            Haptics.tap()
                            onMic()
                        }
                        .onEnded { _ in
                            guard isListening else { return }
                            onMicEnd()
                        }
                )
                .accessibilityLabel("Hold to speak")
                .accessibilityAddTraits(.isButton)
        }
    }
}

#Preview("Ask bar light") {
    AskBarPreview()
}

#Preview("Ask bar dark") {
    AskBarPreview().preferredColorScheme(.dark)
}

private struct AskBarPreview: View {
    @State private var empty = ""
    @State private var typed = "What's on tomorrow?"

    var body: some View {
        VStack(spacing: PDSpacing.m) {
            Spacer()
            AskBar(text: $empty)
            AskBar(text: $typed, canSend: true, onAttach: {})
            AskBar(text: $empty, isListening: true)
            AskBar(text: $empty, showsMic: false)
        }
        .padding(PDSpacing.gutter)
        .pdCanvas()
    }
}
