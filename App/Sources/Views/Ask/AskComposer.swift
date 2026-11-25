import AVFAudio
import PhotosUI
import PocketdKit
import SwiftUI

/// The bottom of the conversation: what is attached, the one thing above the
/// bar, and the bar.
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
///
/// It never asks whether a brain can answer. `model.send()` holds a question
/// until one can and the notice above says so; a composer that refused to send
/// left somebody staring at their own words with no reply and no reason.
struct AskComposer<Accessory: View>: View {
    /// The notice, the Stop pill or the follow-up chip — whichever the
    /// conversation needs above the bar. Drawn here only so the waveform can
    /// take its place while the microphone is open; it reads its own state.
    @ViewBuilder var accessory: Accessory

    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @Environment(\.scenePhase) private var scenePhase

    @FocusState private var isFocused: Bool
    @State private var voice = VoiceInput()
    @State private var dictation = DictationHandoff()
    @State private var voiceStart: Task<Void, Never>?
    @State private var authorizedTurn: UUID?
    @State private var picked: [PhotosPickerItem] = []
    @State private var pickingForConversation: UUID?
    @State private var isPickingPhoto = false
    @State private var levels: [Float] = []
    /// One line above the bar just before iOS asks for Speech Recognition for
    /// the first time. The system's prompt says speech "will be sent to
    /// Apple"; this says first what Pocketd actually does with it.
    @State private var primer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            if !model.attachments.isEmpty { attachments }
            if voice.isListening {
                VoiceWaveform(levels: levels)
            } else if let primer {
                Primer(primer)
                    .padding(.horizontal, PDSpacing.xxs)
                    .transition(.opacity)
            } else if dictation.canContinue {
                HStack {
                    Primer("The mic has stopped.")
                    TextLink("Continue dictating", symbol: "mic") {
                        guard dictation.canContinue, acceptsDictation,
                              dictation.owns(draft: model.draft, in: model.currentConversationID) else { return }
                        cancelDictation()
                        startListening()
                    }
                    .accessibilityIdentifier("ask.mic.continue")
                }
            } else if micPhase != .idle {
                Primer(micPhase == .starting ? "Starting microphone…" : micPhase == .finishing ? "Finishing dictation…" : "Tap the stop button to finish.")
                    .padding(.horizontal, PDSpacing.xxs)
            } else {
                accessory
            }

            AskBar(
                text: draft,
                placeholder: "Ask anything…",
                micPhase: micPhase,
                canSend: canSend,
                showsMic: !awaitingDispatch && !model.isGenerating && (dictation.id != nil || voice.isSupported),
                onMic: startOrJoinMic,
                onMicEnd: { receive(.release, for: $0) },
                onMicCancel: { id in
                    if dictation.id == id && dictation.isHeld { cancelDictation() }
                },
                onSend: send,
                onAttach: model.loadedModelSeesImages ? {
                    pickingForConversation = model.currentConversationID
                    isPickingPhoto = true
                } : nil,
                focus: $isFocused
            )
        }
        .photosPicker(
            isPresented: $isPickingPhoto,
            selection: $picked,
            maxSelectionCount: 4,
            matching: .images,
            photoLibrary: .shared()
        )
        .task(id: picked) { await loadPicked() }
        .onChange(of: voice.level) { _, level in
            guard voice.isListening else { return }
            levels = Array((levels + [level]).suffix(VoiceWaveform.barCount))
        }
        .onAppear(perform: arrive)
        .onDisappear(perform: cancelDictation)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let id = authorizedTurn { openAuthorizedMic(id) }
            // System permission sheets can make the scene inactive. Keep that
            // pending request, but never keep an interrupted recording/final.
            if phase == .background || (phase == .inactive && micPhase != .starting) { cancelDictation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { note in
            if let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               type == AVAudioSession.InterruptionType.began.rawValue, dictation.id != nil { cancelDictation() }
        }
        .onChange(of: model.currentConversationID) { _, _ in cancelIfDraftChanged() }
        .onChange(of: model.draft) { _, _ in cancelIfDraftChanged() }
        .onChange(of: dictation.id == nil ? nil : dictationDestination) { _, current in
            if let current { dictation.observeDestination(current) }
        }
        .onChange(of: navigator.askHandoff?.id) { _, _ in takeHandoff(arriving: false) }
        .onChange(of: model.askComposerFocusRequested) { _, _ in takeFocusRequest(arriving: false) }
        .onChange(of: model.isGenerating) { _, generating in
            if generating { cancelDictation() }
        }
    }

    private var draft: Binding<String> {
        Binding(get: { model.draft }, set: { text in
            guard text != model.draft else { return }
            // Retire the turn synchronously, even if the user then undoes the
            // edit back to the exact words the recognizer last previewed.
            if dictation.id != nil { cancelDictation() }
            model.draft = text
        })
    }

    /// Byte-for-byte the predicate `AppModel.send()` guards on, minus the
    /// brain: a question with nothing to answer it yet is still sent, and held.
    ///
    /// Two deciders answering one question is how a button lights up over a
    /// `send()` that returns immediately: `.whitespaces` does not include
    /// newlines, so a draft of one Return once left this enabled and the tap
    /// landed on nothing.
    private var canSend: Bool {
        !model.isGenerating
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.attachments.isEmpty)
    }

    private func send() {
        cancelDictation()
        isFocused = false
        model.send()
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
                            .font(Font.pd.secondary)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .pdHitTarget(alignment: .topTrailing)
                    }
                    .padding(-PDSpacing.xs)
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
        guard let conversation = pickingForConversation, conversation == model.currentConversationID else {
            picked = []
            return
        }
        for item in picked {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw),
                  let shrunk = image.downscaled(to: 896)?.jpegData(compressionQuality: 0.8)
            else { continue }
            guard !Task.isCancelled else { return }
            guard model.currentConversationID == conversation else {
                if pickingForConversation == conversation { picked = [] }
                return
            }
            model.attach(shrunk)
        }
        picked = []
    }

    // MARK: - Voice

    private var micPhase: DictationHandoff.Phase { dictation.phase(isListening: voice.isListening) }

    private var awaitingDispatch: Bool { model.waitingQuestion != nil || IntentInbox.questions.isWaiting }

    private var dictationDestination: DictationHandoff.Destination {
        .resolve(chosen: model.brainChoice, effective: model.effectiveBrain, residentID: model.loadedModelID,
                 canAnswer: model.brainStatus.canAnswer, cloud: model.cloudStatus, selection: model.brainChoiceIntent)
    }

    private func startOrJoinMic() -> DictationHandoff.Press.Session? {
        dictation.startOrJoin { startListening() }
    }

    // A dismissal or a new handoff can precede SwiftUI's onDisappear/onChange.
    // Check again at delivery, on the same actor as the draft write and send.
    private var acceptsDictation: Bool {
        scenePhase != .background && UIApplication.shared.applicationState != .background && navigator.isAskPresented && navigator.askHandoff == nil
            && !model.askComposerFocusRequested && !model.isGenerating && !awaitingDispatch
    }

    private func stillWantsMic(_ id: UUID) -> Bool {
        acceptsDictation && dictation.awaitsCapture(for: id, draft: model.draft, in: model.currentConversationID)
    }

    @discardableResult
    private func startListening(after delay: Duration? = nil) -> UUID? {
        guard acceptsDictation, dictation.id == nil else { return nil }
        isFocused = false
        levels = []
        let id = dictation.begin(draft: model.draft, in: model.currentConversationID, destination: dictationDestination,
                                 hasAttachments: !model.attachments.isEmpty)
        voiceStart = Task { @MainActor in
            if let delay {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            if voice.authorization != .granted {
                if voice.authorization == .unknown {
                    withAnimation(PDMotion.gentle) {
                        primer = "Pocketd turns your voice into text on this iPhone. iOS may ask for access."
                    }
                    // Long enough to be read before the system's alert dims
                    // the screen; it stays readable beneath it.
                    do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                }
                // iOS shows each prompt once; asking again after a decision
                // re-reads it rather than nagging.
                let granted = await voice.requestAuthorization { stillWantsMic(id) }
                guard !Task.isCancelled, dictation.id == id else { return }
                guard stillWantsMic(id) else { cancelDictation(); return }
                withAnimation(PDMotion.gentle) { primer = nil }
                guard granted else {
                    voiceStart = nil
                    receive(.failed(VoiceInput.refusedSentence), for: id)
                    return
                }
            }
            guard dictation.id == id, !Task.isCancelled else { return }
            voiceStart = nil
            authorizedTurn = id
            openAuthorizedMic(id)
        }
        return id
    }

    private func openAuthorizedMic(_ id: UUID) {
        guard dictation.id == id, authorizedTurn == id else { return }
        guard acceptsDictation else { cancelDictation(); return }
        // TCC may return before its sheet has given the app the audio session
        // back. The active transition resumes this exact turn, at most once.
        guard scenePhase == .active, UIApplication.shared.applicationState == .active else { return }
        authorizedTurn = nil
        guard dictation.beginCapture(for: id, draft: model.draft, in: model.currentConversationID) else { cancelDictation(); return }
        voice.start(for: id) { receive($0, for: id) }
    }

    private func receive(_ event: DictationHandoff.Event, for id: UUID) {
        guard dictation.id == id else { return }
        guard acceptsDictation, micPhase == .starting || UIApplication.shared.applicationState == .active else {
            cancelDictation(); return
        }
        switch dictation.receive(event, for: id, draft: model.draft, in: model.currentConversationID, destination: dictationDestination,
                                 hasAttachments: !model.attachments.isEmpty) {
        case .preview(let words):
            model.draft = words
        case .endAudio:
            voice.stop(for: id)
        case .submit(let words):
            model.draft = words
            model.record(.voiceAskUsed)
            isFocused = false
            model.send()
        case .reviewFinal(let words):
            model.draft = words
            isFocused = true
            toasts?.show("Review your question, then tap Send.", symbol: "pencil", tint: .pd.accent)
        case .review(let message):
            toasts?.show(message, symbol: "mic.slash", tint: .pd.caution)
            isFocused = true
        case .cancel:
            cancelDictation()
        case nil:
            break
        }
    }

    private func cancelIfDraftChanged() {
        if dictation.id != nil, !dictation.owns(draft: model.draft, in: model.currentConversationID) {
            cancelDictation()
        }
    }

    private func cancelDictation() {
        dictation.cancel()
        authorizedTurn = nil
        voiceStart?.cancel()
        voiceStart = nil
        voice.cancel()
        primer = nil
        levels = []
    }

    // MARK: - Arriving with something to say

    /// The sheet has just come up.
    ///
    /// Every way in wants the cursor in the box — the field on Today, a detail
    /// page's composer, `pocketd://ask`, the "Ask Pocketd" control — except a
    /// question that is being sent: its answer is about to appear, and the
    /// keyboard would cover it.
    private func arrive() {
        if navigator.askHandoff != nil {
            takeHandoff(arriving: true)
        } else if model.askComposerFocusRequested {
            takeFocusRequest(arriving: true)
        } else {
            focus(after: true)
        }
    }

    /// The shell selected the source's thread before presenting Ask. A stem
    /// stays editable; a submitted question leaves room to read the answer.
    private func takeHandoff(arriving: Bool) {
        guard let handoff = navigator.takeAskHandoff(), handoff.conversation == model.currentConversationID else { return }
        cancelDictation()
        if handoff.focus { focus(after: arriving) } else { isFocused = false }
    }

    /// The "Ask Pocketd" control, or a page's mic: the cursor in the box, and
    /// the microphone open where this phone can hear on-device.
    ///
    /// Both, in that order. Listening alone left nowhere to type when it
    /// failed — a mic tap that ended in a toast and an empty, unfocused box.
    /// The box is greyed while the microphone is open and takes the cursor
    /// back when it closes without sending.
    private func takeFocusRequest(arriving: Bool) {
        guard model.askComposerFocusRequested else { return }
        model.askComposerFocusRequested = false
        if dictation.id != nil { cancelDictation() }
        focus(after: arriving)
        guard voice.isSupported, !model.isGenerating else { return }
        startListening(after: arriving ? .milliseconds(500) : nil)
    }

    /// Puts the cursor in the box. On arrival the sheet is still sliding up,
    /// and a field that is not in a window yet cannot take focus — so the
    /// request waits for the presentation to land.
    private func focus(after arriving: Bool) {
        Task {
            if arriving { try? await Task.sleep(for: .milliseconds(450)) }
            if dictation.id == nil, navigator.isAskPresented { isFocused = true }
        }
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
            Text("Listening… Tap to finish.")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
        }
        .frame(minHeight: 24)
        .padding(.horizontal, PDSpacing.s)
        .accessibilityElement()
        .accessibilityLabel("Listening. Tap the stop button to finish.")
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
