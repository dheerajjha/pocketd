import PhotosUI
import PocketdKit
import SwiftUI

/// The bottom of the Ask screen: what is attached, what to ask next, and the bar.
///
/// Its own `View` for one specific reason, and it is the difference between a
/// chat that types smoothly and one that locks up. SwiftUI registers an
/// observable read against whichever body performed it. While the composer was a
/// computed property of the chat screen, reading `model.draft` registered
/// against the *screen's* body — so every keystroke invalidated the whole
/// transcript and re-applied the `ForEach` over every message. A sampled hang
/// showed 1371 of 1371 main-thread frames inside one `CATransaction.commit`,
/// recursing through `LazyStack.sizeThatFits`, with no inference on the stack at
/// all: the model was not slow, the layout was rebuilding itself per letter.
///
/// Keeping the draft in here means a keystroke invalidates a bar, not a
/// transcript. Nothing above this view may read `model.draft`.
struct AskComposer: View {
    /// The one question worth offering after the last answer, or `nil`.
    let followUp: AskSuggestion?

    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    @FocusState private var isFocused: Bool
    @State private var voice = VoiceInput()
    @State private var picked: [PhotosPickerItem] = []
    @State private var isPickingPhoto = false
    @State private var levels: [Float] = []

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            if !model.attachments.isEmpty { attachments }
            if voice.isListening {
                VoiceWaveform(levels: levels)
            } else if model.isGenerating {
                stopPill
            } else if let followUp, !model.conversation.isEmpty {
                SuggestionChip(followUp.text, symbol: followUp.symbol) {
                    model.draft = followUp.text
                    model.send()
                }
            }

            AskBar(
                text: $model.draft,
                placeholder: "Ask anything…",
                isListening: voice.isListening,
                canSend: canSend,
                showsMic: voice.isSupported && !model.isGenerating,
                onMic: startListening,
                onMicEnd: finishListening,
                onSend: send,
                onAttach: model.loadedModelSeesImages ? { isPickingPhoto = true } : nil,
                focus: $isFocused
            )
        }
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.bottom, PDSpacing.xs)
        .photosPicker(
            isPresented: $isPickingPhoto,
            selection: $picked,
            maxSelectionCount: 4,
            matching: .images,
            photoLibrary: .shared()
        )
        .task(id: picked) { await loadPicked() }
        // Live, so the words appear as they are said rather than all at once on
        // release — which is the difference between dictation you can correct
        // and dictation you have to trust.
        .onChange(of: voice.transcript) { _, text in
            guard voice.isListening else { return }
            model.draft = text
        }
        .onChange(of: voice.level) { _, level in
            guard voice.isListening else { return }
            levels = Array((levels + [level]).suffix(VoiceWaveform.barCount))
        }
        .onAppear {
            takeHandoff()
            takeFocusRequest()
        }
        .onChange(of: navigator.askHandoff?.id) { _, _ in takeHandoff() }
        .onChange(of: model.askComposerFocusRequested) { _, _ in takeFocusRequest() }
    }

    /// Byte-for-byte the predicate `AppModel.send()` guards on.
    ///
    /// Two deciders answering one question is how a button lights up over a
    /// `send()` that returns immediately: `.whitespaces` does not include
    /// newlines, so a draft of one Return once left this enabled and the tap
    /// landed on nothing.
    private var canSend: Bool {
        !model.isGenerating
            && model.loadedModelID != nil
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.attachments.isEmpty)
    }

    private func send() {
        isFocused = false
        model.send()
    }

    private var stopPill: some View {
        PillButton(title: "Stop", symbol: "stop.fill") {
            model.stopGenerating()
        }
    }

    // MARK: - Attachments

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PDSpacing.xs) {
                ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, data in
                    thumbnail(data, at: index)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 62)
    }

    /// Extracted purely so the body type-checks: SwiftUI builds one expression
    /// per view body, and this one grew past what the solver will attempt.
    @ViewBuilder
    private func thumbnail(_ data: Data, at index: Int) -> some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: PDRadius.iconTileSmall, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {
                        model.removeAttachment(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .padding(2)
                    .accessibilityLabel("Remove photo \(index + 1)")
                }
        }
    }

    /// Reads the picked items into memory and hands them to the model.
    ///
    /// Downscaled first: a modern iPhone photo is several thousand pixels wide
    /// and the projector sees a few hundred, so sending the original spends
    /// memory and encode time to produce the same tokens. It also has to be
    /// data rather than a file URL — the wire format carries base64, and a
    /// paired laptop cannot open a path on this phone.
    private func loadPicked() async {
        guard !picked.isEmpty else { return }
        for item in picked {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw),
                  let shrunk = image.downscaled(to: 896)?.jpegData(compressionQuality: 0.8)
            else { continue }
            model.attach(shrunk)
        }
        picked = []
    }

    // MARK: - Voice

    private func startListening() {
        guard !voice.isListening, !model.isGenerating else { return }
        levels = []
        Task {
            if voice.authorization != .granted {
                // iOS shows each prompt once; asking again after a decision
                // re-reads it rather than nagging.
                guard await voice.requestAuthorization() else { return }
            }
            voice.reset()
            voice.start()
        }
    }

    private func finishListening() {
        guard voice.isListening else { return }
        voice.stop()
        Task {
            // The recogniser's last callback arrives after `endAudio()`, and it
            // carries the final word. Sending before it lands is how "remind me
            // at four" becomes "remind me at".
            try? await Task.sleep(for: .milliseconds(400))
            levels = []
            let said = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !said.isEmpty else { return }
            model.draft = said
            model.record(.voiceAskUsed)
            guard model.loadedModelID != nil else {
                // Nothing to answer with. The words stay in the box rather than
                // disappearing into a send that cannot happen.
                isFocused = true
                return
            }
            model.send()
        }
    }

    // MARK: - Arriving with something to say

    /// A question handed over from Today, Siri or a Shortcut.
    private func takeHandoff() {
        guard let handoff = navigator.takeAskHandoff() else { return }
        model.draft = handoff.draft
        guard handoff.send, model.loadedModelID != nil else {
            isFocused = true
            return
        }
        model.send()
    }

    /// A tap on the Control Center button, which asks for the cursor and — where
    /// the phone can hear on-device — for the microphone too.
    private func takeFocusRequest() {
        guard model.askComposerFocusRequested else { return }
        model.askComposerFocusRequested = false
        isFocused = true
        guard voice.isSupported else { return }
        startListening()
    }
}

/// What the microphone is hearing, drawn.
///
/// A rolling history of the smoothed level rather than a decorative animation,
/// because the one question somebody holding a mic button has is "can it hear
/// me" — and a waveform that moves whether or not anybody is speaking answers it
/// wrongly.
struct VoiceWaveform: View {
    static let barCount = 28
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.pd.accent.opacity(index < levels.count ? 0.9 : 0.25))
                    .frame(width: 3, height: height(at: index))
            }
            Spacer(minLength: 0)
            Text("Listening…")
                .font(Font.pd.caption)
                .foregroundStyle(Color.pd.inkSecondary)
        }
        .frame(height: 24)
        .padding(.horizontal, PDSpacing.s)
        .accessibilityElement()
        .accessibilityLabel("Listening")
    }

    private func height(at index: Int) -> CGFloat {
        guard index < levels.count else { return 3 }
        return 3 + CGFloat(levels[index]) * 21
    }
}

private extension UIImage {
    /// Longest edge capped, aspect preserved. Vision projectors work from a
    /// fixed small grid, so anything larger is bytes the model never reads.
    func downscaled(to longestEdge: CGFloat) -> UIImage? {
        let longest = max(size.width, size.height)
        guard longest > longestEdge else { return self }
        let scale = longestEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
