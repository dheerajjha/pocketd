import PocketdKit
import SwiftUI
import UIKit

/// The composer, pinned above the tab bar.
///
/// A 52pt capsule floating over the conversation rather than a bar attached to
/// the bottom of it, which is what lets the last message scroll under it
/// instead of being cut off by it.
///
/// Tap to start and tap again to finish, or hold and release. The 44pt mic
/// target stays in place until finalization; a second tap must never hit a
/// Send arrow over provisional words.
struct AskBar: View {
    @Binding var text: String
    var placeholder: String = "Ask anything"
    var micPhase: DictationHandoff.Phase = .idle
    var canSend: Bool = false
    /// Hidden entirely when the device cannot recognise speech on-device. A mic
    /// that would have to upload audio does not belong in this app.
    var showsMic: Bool = true
    var onMic: () -> DictationHandoff.Press.Session? = { nil }
    var onMicEnd: (UUID) -> Void = { _ in }
    var onMicCancel: (UUID) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onAttach: (() -> Void)?
    /// A focus state owned by the screen, for the callers that have to put the
    /// cursor here without a tap — a phrase from Siri, the Control Center
    /// button, a question handed over from Today. `nil` keeps the bar's own.
    var focus: FocusState<Bool>.Binding?

    @FocusState private var isFocused: Bool
    @State private var micPress = DictationHandoff.Press()

    private var micActive: Bool { micPhase != .idle }
    private var fieldPlaceholder: String {
        switch micPhase {
        case .idle: placeholder
        case .starting: "Starting microphone…"
        case .listening: "Listening…"
        case .awaitingFinish: "Tap to finish"
        case .finishing: "Finishing dictation…"
        }
    }

    private var micLabel: String {
        switch micPhase {
        case .idle: "Speak"
        case .starting: "Cancel dictation"
        case .listening, .awaitingFinish: "Finish dictation"
        case .finishing: "Finishing dictation"
        }
    }

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

            TextField(fieldPlaceholder, text: $text, axis: .vertical)
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.ink)
                .tint(Color.pd.accent)
                .lineLimit(1...4)
                .focused(focus ?? $isFocused)
                // Multiline fields insert a newline on the software Return key.
                // Sending is the separate control at the trailing edge.
                .submitLabel(.return)
                .disabled(micActive && micPhase != .finishing)
                // The placeholder is not a label: VoiceOver stops reading it
                // the moment there is a character in the field, and a text
                // field announced as nothing but its contents gives no clue
                // what typing into it will do.
                .accessibilityLabel("Your question")
                .accessibilityIdentifier("ask.composer")
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
            if micActive {
                barShape.strokeBorder(Color.pd.accent, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .animation(PDMotion.gentle, value: canSend)
        .animation(PDMotion.gentle, value: micPhase)
        .onDisappear(perform: cancelPress)
    }

    private func cancelPress() {
        if let id = micPress.cancel() { onMicCancel(id) }
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
        // Keep the same touch target mounted through partials, early finals and
        // even a recognition failure while the finger is still down.
        if canSend && !micActive && !micPress.isDown {
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
            .accessibilityIdentifier("ask.send")
        } else if showsMic || micActive || micPress.isDown {
            Image(systemName: micPhase == .finishing ? "ellipsis" : micActive ? "stop.fill" : "mic")
                .font(Font.pd.body)
                .foregroundStyle(micActive ? Color.pd.onPrimary : Color.pd.inkSecondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(micActive ? Color.pd.accent : Color.clear)
                )
                .pdHitTarget()
                .overlay {
                    MicContactTarget(down: { time in
                        micPress.begin(at: time) {
                            let session = onMic()
                            if case .started = session { Haptics.tap() }
                            return session
                        }
                    }, up: { time in
                        if let id = micPress.end(at: time) { onMicEnd(id) }
                    }, cancelled: cancelPress)
                    .frame(width: PDMetric.minHitTarget, height: PDMetric.minHitTarget)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(micLabel)
                .accessibilityHint(micActive ? "" : "Double-tap to start, and again to finish")
                .accessibilityIdentifier("ask.mic")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    switch onMic() {
                    case .started: Haptics.tap()
                    case .joined(let id): onMicEnd(id)
                    case nil: break
                    }
                }
                .disabled(micPhase == .finishing)
        }
    }
}

/// UIKit distinguishes a cancelled touch from a lift. A SwiftUI gesture state
/// resetting to false represents both, including when a permission sheet opens.
private struct MicContactTarget: UIViewRepresentable {
    var down: (TimeInterval) -> Void
    var up: (TimeInterval) -> Void
    var cancelled: () -> Void

    func makeUIView(context: Context) -> Control { Control() }
    func updateUIView(_ control: Control, context: Context) { control.contact = self }

    final class Control: UIControl {
        var contact: MicContactTarget?
        private var downInWindow: CGPoint = .zero

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            downInWindow = touch.location(in: nil)
            contact?.down(touch.timestamp)
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            // Resigning field focus moves the whole bar with the keyboard. A
            // stationary finger didn't slide away just because the bar moved.
            guard let touch else { contact?.cancelled(); return }
            let up = touch.location(in: nil)
            if hypot(up.x - downInWindow.x, up.y - downInWindow.y) > PDMetric.minHitTarget { contact?.cancelled() }
            else { contact?.up(touch.timestamp) }
        }

        override func cancelTracking(with event: UIEvent?) { contact?.cancelled() }
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
            AskBar(text: $empty, micPhase: .listening)
            AskBar(text: $empty, showsMic: false)
        }
        .padding(PDSpacing.gutter)
        .pdCanvas()
    }
}
