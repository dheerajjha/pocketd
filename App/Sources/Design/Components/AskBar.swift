import SwiftUI

/// The composer, pinned above the tab bar.
///
/// A 52pt capsule floating over the conversation rather than a bar attached to
/// the bottom of it, which is what lets the last message scroll under it
/// instead of being cut off by it.
///
/// The mic is hold-to-talk and the send button only appears when there is
/// something to send — two controls in the same slot, because a permanent
/// disabled arrow next to a permanent mic is two dead controls at the exact
/// place a person is looking for one live one. Each is drawn at 36pt and
/// tappable at 44.
///
/// Hold-to-talk is a gesture VoiceOver cannot perform — its double-tap is a
/// press and a release in the same instant, which started listening and
/// stopped it again. So the mic also has an accessibility action: double-tap
/// starts listening, and double-tap again stops and sends.
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
                        .font(Font.pd.body)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .frame(width: 36, height: 36)
                        .pdHitTarget()
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
                // The placeholder is not a label: VoiceOver stops reading it
                // the moment there is a character in the field, and a text
                // field announced as nothing but its contents gives no clue
                // what typing into it will do.
                .accessibilityLabel("Your question")
                // 12pt from the capsule's edge with nothing before it — the
                // bar's own 8 plus 4 — the same as the circle at the far end,
                // whose 36pt glyph sits inside a 44pt target.
                .padding(.leading, onAttach == nil ? PDSpacing.xxs : 0)

            trailingControl
        }
        // 4 + a 44pt target + 4 is the 52pt bar. Across, the 8pt inset plus
        // the 4pt of transparent target around each 36pt circle puts the
        // circles 12pt from the ends, where they were before the targets grew.
        .padding(.horizontal, PDSpacing.xs)
        .padding(.vertical, PDSpacing.xxs)
        .frame(minHeight: PDMetric.askBarHeight)
        // The same surface as Today's `ContextComposer`, so the field somebody
        // taps on Today and the field the conversation opens with are one
        // material, not two.
        .pdGlass(barShape)
        .overlay {
            if isListening {
                barShape.strokeBorder(Color.pd.accent, lineWidth: 1)
            }
        }
        .animation(PDMotion.gentle, value: canSend)
        .animation(PDMotion.gentle, value: isListening)
    }

    /// A capsule at one line. Once a question runs to two or more lines the
    /// radius stays at half the one-line height, so the bar becomes a rounded
    /// rectangle — a capsule that tall curves in across the first and last
    /// lines of text.
    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PDMetric.askBarHeight / 2, style: .continuous)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if canSend {
            Button {
                Haptics.send()
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    // A glyph in a fixed 36pt circle: sized by the circle.
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.pd.onPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.pd.primaryButton, in: Circle())
                    .pdHitTarget()
            }
            .buttonStyle(PDPressStyle())
            .accessibilityLabel("Send")
        } else if showsMic {
            Image(systemName: isListening ? "waveform" : "mic")
                .font(Font.pd.body)
                .foregroundStyle(isListening ? Color.pd.onPrimary : Color.pd.inkSecondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(isListening ? Color.pd.accent : Color.clear)
                )
                .pdHitTarget()
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
                .accessibilityLabel(isListening ? "Stop listening" : "Speak")
                .accessibilityHint(isListening ? "Sends what you said" : "Double-tap to start, and again to stop")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    if isListening {
                        onMicEnd()
                    } else {
                        Haptics.tap()
                        onMic()
                    }
                }
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
