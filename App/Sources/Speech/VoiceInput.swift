import AVFoundation
import Foundation
import Observation
import PocketdKit
import Speech

/// On-device dictation for Ask, including mic handoffs from Today. Recognition
/// audio must never go to a server: hide the mic for unsupported locales and
/// require local recognition on every request, even if the local assets fail.
@MainActor
@Observable
final class VoiceInput {

    /// Speech recognition and microphone permission, collapsed into one
    /// value.
    ///
    /// iOS shows these as two separate system prompts with two separate
    /// outcomes, and a caller that only wants to know whether the mic button
    /// should be enabled has no use for that distinction: either both are
    /// granted and listening can start, or one of them is not and it can't.
    /// `.unknown` covers "never asked" and "asked and still undetermined"
    /// alike, since both mean the same thing to a Start button — ask first.
    enum Authorization {
        case unknown
        case granted
        case denied
    }

    private(set) var isListening: Bool = false

    /// 0...1, smoothed. A waveform redrawn straight from a buffer's raw RMS
    /// jumps between silence and full scale on every unvoiced consonant; the
    /// exponential smoothing in `updateLevel` is what turns that into
    /// something that reads as speech rather than static.
    private(set) var level: Float = 0

    private(set) var authorization: Authorization = .unknown

    /// Whether this device can even try, checked live rather than cached: a
    /// recognizer for the current locale exists and can run without reaching
    /// a server. Apple's own guidance is to re-check per session rather than
    /// remember the answer, and the answer genuinely can change — a language
    /// pack finishes downloading, or Settings > General > Language changes
    /// under the app.
    var isSupported: Bool {
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var deadline: Task<Void, Never>?

    /// Identifies one recognition session. The recognizer can be slow to wind
    /// down after `endAudio()`, and its last callback for an old session can
    /// arrive after a new one has already begun; every callback below is
    /// stamped with the token that was current when it was scheduled and is
    /// dropped once that is no longer this one — the same trade `LlamaEngine`
    /// makes with its own generation token, so a stale answer never overwrites
    /// the one running now.
    private var token: UUID?
    private var onResult: (@MainActor (DictationHandoff.Event) -> Void)?

    /// End audio just ahead of Apple's roughly one-minute recognition limit.
    /// This stops capture; it doesn't supply either a final or a user release.
    private static let maxListenDuration: Duration = .seconds(58)
    private static let finalWait: Duration = .seconds(4)

    // MARK: - Permission

    /// Puts both system prompts to the user if either has never been shown,
    /// and reports whether listening can start. iOS shows each prompt at most
    /// once; calling this again after a decision re-reads that decision
    /// instead of asking again.
    func requestAuthorization() async -> Bool {
        guard !Task.isCancelled else { return false }
        let speechStatus = await Self.speechAuthorization()
        // Releasing a pending press cannot dismiss an OS prompt already on
        // screen, but it must not start the next prompt or open the mic.
        guard !Task.isCancelled else { return false }
        // Asking for the microphone after Speech Recognition was refused
        // would show a permission sheet for a capability that refusal already
        // makes useless, right after the user just said no to the thing next
        // to it.
        guard speechStatus == .authorized else {
            authorization = .denied
            return false
        }
        _ = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled else { return false }
        let current = Self.currentAuthorization()
        authorization = current
        return current == .granted
    }

    /// Re-derives `authorization` from the two system permissions, without
    /// prompting. A user who flips the Microphone switch off in Settings and
    /// comes back should see that the next time this is checked, not only the
    /// next time this class happens to ask.
    private static func currentAuthorization() -> Authorization {
        switch (SFSpeechRecognizer.authorizationStatus(), AVAudioApplication.shared.recordPermission) {
        case (.authorized, .granted):
            return .granted
        case (.denied, _), (.restricted, _), (_, .denied):
            return .denied
        default:
            return .unknown
        }
    }

    // MARK: - Listening

    func start(for sessionToken: UUID, onResult: @escaping @MainActor (DictationHandoff.Event) -> Void) {
        cancel()
        // `isAvailable` can be false even when local dictation works. Check the
        // actual recognizer's local capability; the request below enforces it.
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else {
            onResult(.failed("On-device speech recognition isn't available on this device."))
            return
        }

        let liveAuthorization = Self.currentAuthorization()
        authorization = liveAuthorization
        guard liveAuthorization == .granted else {
            onResult(.failed(Self.refusedSentence))
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // .measurement is Apple's own recommendation for feeding a speech
            // recognizer: it is the one mode that turns off the system's
            // voice-tuned signal processing, which a recognizer trained on
            // unprocessed audio does not expect.
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            onResult(.failed("Couldn't start the microphone. Try again."))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Never set to false. See the type-level comment — this one line is
        // the whole privacy guarantee this class makes.
        request.requiresOnDeviceRecognition = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            onResult(.failed("Couldn't start the microphone. Try again."))
            return
        }

        // The tap block runs on the audio engine's real-time render thread,
        // never the main actor — see `tapBlock`, which builds it outside this
        // actor and holds `self` weakly (the block is stored on `audioEngine`,
        // which `self` owns).
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.tapBlock(appendingTo: request, token: sessionToken, owner: self)
        )

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            onResult(.failed("Couldn't start the microphone. Try again."))
            return
        }

        self.recognizer = recognizer
        self.request = request
        token = sessionToken
        self.onResult = onResult
        isListening = true

        task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.resultHandler(token: sessionToken, owner: self)
        )

        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.maxListenDuration) } catch { return }
            self?.stop(for: sessionToken)
        }
    }

    /// Ends capture, not recognition: further partials and the final still
    /// belong to the same callback. The deadline only abandons the request.
    func stop(for sessionToken: UUID) {
        guard token == sessionToken, isListening else { return }
        deadline?.cancel()
        stopCapture(endingAudio: true)
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.finalWait) } catch { return }
            self?.resolve(.timedOut, for: sessionToken, cancellingTask: true)
        }
    }

    func cancel() {
        clearSession(cancellingTask: true)
    }

    deinit {
        // A defensive net for a caller that goes away without calling
        // `cancel()` first. Both calls are idempotent and safe even when
        // nothing is running.
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // MARK: - Callbacks the system makes on its own threads

    // Every closure below is handed to the system and called back on a
    // thread of the system's choosing — the audio engine's real-time render
    // thread, the recogniser's queue, TCC's reply queue. Written inline in
    // this main-actor class, Swift 6 makes each one main-actor-isolated and
    // checks that at run time: tapping "Don't Allow" on the Speech
    // Recognition prompt crashed the app ("BUG IN CLIENT OF LIBDISPATCH:
    // Block was expected to execute on queue com.apple.main-thread"), and the
    // tap block would have done the same on the first buffer of audio. Built
    // in `nonisolated` functions instead, so the closures belong to no actor,
    // and only plain values hop to the main actor.

    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// The block `installTap` calls per buffer: appends it to the request and
    /// reports its level. `owner` is held weakly — the block is stored on
    /// `audioEngine`, which `owner` owns, so a strong capture is a cycle.
    private nonisolated static func tapBlock(
        appendingTo request: SFSpeechAudioBufferRecognitionRequest,
        token: UUID,
        owner: VoiceInput
    ) -> AVAudioNodeTapBlock {
        { [weak owner] buffer, _ in
            request.append(buffer)
            let level = rmsLevel(of: buffer)
            Task { @MainActor [weak owner] in
                owner?.updateLevel(level, for: token)
            }
        }
    }

    /// The recogniser's result handler. Neither `SFSpeechRecognitionResult`
    /// nor `Error` is Sendable, so everything worth keeping is read out here,
    /// on whatever thread the recogniser calls back on.
    private nonisolated static func resultHandler(
        token: UUID,
        owner: VoiceInput
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak owner] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let description = error.map { String(describing: $0) }
            // Keep callbacks in delivery order: a terminal error can follow
            // immediately behind the last usable partial.
            DispatchQueue.main.async { [weak owner] in
                owner?.handle(token: token, transcript: transcript, isFinal: isFinal, errorDescription: description)
            }
        }
    }

    // MARK: - Session bookkeeping

    private func handle(token callbackToken: UUID, transcript: String?, isFinal: Bool, errorDescription: String?) {
        guard callbackToken == token else { return }
        if let errorDescription {
            // An error can carry a transcription, but it cannot confirm one.
            if let transcript { onResult?(.partial(transcript)) }
            resolve(.failed(Self.plainMessage(forDescription: errorDescription)), for: callbackToken)
        } else if isFinal {
            // The recognizer may finish while the mic is still held.
            resolve(.final(transcript ?? ""), for: callbackToken)
        } else if let transcript {
            onResult?(.partial(transcript))
        }
    }

    private func resolve(_ event: DictationHandoff.Event, for sessionToken: UUID, cancellingTask: Bool = false) {
        guard token == sessionToken else { return }
        let report = onResult
        clearSession(cancellingTask: cancellingTask)
        report?(event)
    }

    private func clearSession(cancellingTask: Bool) {
        // Invalidate before touching Speech: a callback may already be queued.
        token = nil
        onResult = nil
        deadline?.cancel()
        deadline = nil
        stopCapture()
        if cancellingTask { task?.cancel() }
        task = nil
        request = nil
        recognizer = nil
    }

    private func updateLevel(_ raw: Float, for callbackToken: UUID) {
        guard callbackToken == token, isListening else { return }
        // Exponential smoothing: buffers arrive roughly 40 times a second at
        // this tap's buffer size, and a waveform that jumps straight to each
        // new value looks like noise rather than a level.
        let smoothing: Float = 0.3
        level += (raw - level) * smoothing
    }

    private func stopCapture(endingAudio: Bool = false) {
        guard isListening else { return }
        isListening = false
        level = 0
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        if endingAudio { request?.endAudio() }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Translating the framework

    /// A buffer's loudness on a log scale, folded to 0...1.
    ///
    /// `nonisolated` and `static`: this runs on the audio engine's own
    /// real-time thread, once per buffer, and must never wait on the main
    /// actor just to compute a square root.
    private nonisolated static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channel[0]
        var sumOfSquares: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frameCount))
        // -50 dB is close to silence for a phone microphone and 0 dB is
        // clipping; the range between them is what actually moves on a
        // waveform. Below the floor this reads as flat zero rather than a
        // jitter nobody asked to see.
        let decibels = 20 * log10(max(rms, 0.00001))
        let minDecibels: Float = -50
        let normalized = (decibels - minDecibels) / -minDecibels
        return min(max(normalized, 0), 1)
    }

    /// Every error this class can produce, boiled down to one sentence a
    /// person mid-conversation can act on. Matched the same way
    /// `AppModel.friendlyMessage` matches server errors: by substring, on the
    /// framework's own description, because neither `Speech` nor
    /// `AVFoundation` gives a typed reason here worth switching over.
    private static func plainMessage(forDescription text: String) -> String {
        let text = text.lowercased()
        if text.contains("permission") || text.contains("denied") || text.contains("not authorized") {
            return refusedSentence
        }
        if text.contains("no speech") || text.contains("code=1110") {
            return "Pocketd didn't hear anything. Try again."
        }
        // The on-device recogniser itself: its language files are missing or
        // being replaced, or Dictation is off. Seen on the simulator as
        // kLSRErrorDomain 300, "Failed to initialize recognizer", on every
        // attempt — "Try again" there only fails again, so it says why instead.
        if text.contains("klsrerrordomain") || text.contains("initialize recognizer")
            || text.contains("asset") || text.contains("dictation") || text.contains("unavailable") {
            return unavailableSentence
        }
        if text.contains("audio") || text.contains("microphone") {
            return "Pocketd couldn't use the microphone. Try again."
        }
        return "Pocketd couldn't turn that into words. Try again."
    }

    /// Which permission is missing, by name — the Settings switch somebody has
    /// to find is either Microphone or Speech Recognition, and saying both
    /// sends them looking for one that is already on.
    static var refusedSentence: String {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            return "Speech Recognition is off for Pocketd in iOS Settings."
        }
        if AVAudioApplication.shared.recordPermission != .granted {
            return "Microphone is off for Pocketd in iOS Settings."
        }
        return "Pocketd can't listen right now. Try again."
    }

    static let unavailableSentence = "Speech recognition isn't available on this iPhone right now."

    /// Whether iOS has never asked for Speech Recognition — the moment a
    /// primer goes up, before the system's own prompt.
    static var hasNeverAsked: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
            || AVAudioApplication.shared.recordPermission == .undetermined
    }
}
