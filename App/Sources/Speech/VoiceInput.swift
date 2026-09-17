import AVFoundation
import Foundation
import Observation
import Speech

/// On-device speech-to-text for a microphone button on the Ask and Today
/// screens.
///
/// Everything here runs on-device — `requiresOnDeviceRecognition` is set to
/// `true` once, in `start()`, and nothing in this file ever sets it back to
/// `false`. That is not a performance choice, it is the whole point of the
/// class: this app's argument to the user is that nothing they say to it
/// leaves the phone, and `SFSpeechRecognizer`'s automatic fallback to a
/// server-side recognizer whenever the on-device one is unavailable would
/// break that argument silently rather than loudly. `isSupported` exists so a
/// caller can find out *before* offering the microphone at all, which is what
/// keeps this class from ever having to choose between refusing to listen and
/// quietly cheating.
///
/// On-device recognition does not exist for every locale, and — worth
/// knowing before this ever looks broken in testing — is unavailable in the
/// iOS Simulator. `isSupported` reports `false` there; that is expected, not
/// a bug in this class.
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

    private(set) var transcript: String = ""
    private(set) var isListening: Bool = false

    /// 0...1, smoothed. A waveform redrawn straight from a buffer's raw RMS
    /// jumps between silence and full scale on every unvoiced consonant; the
    /// exponential smoothing in `updateLevel` is what turns that into
    /// something that reads as speech rather than static.
    private(set) var level: Float = 0

    /// One plain sentence for whoever is looking at the screen, or `nil`.
    /// Never a raw error description — `SFSpeechRecognitionTask` and
    /// `AVAudioEngine` report failures as framework NSErrors written for a
    /// console, and `plainMessage(forDescription:)` is the only place that
    /// text is looked at, and only to classify it.
    private(set) var error: String?

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
    private var autoStopTask: Task<Void, Never>?

    /// Identifies one `start()` session. The recognizer can be slow to wind
    /// down after `stop()`, and its last callback for an old session can
    /// arrive after a new one has already begun; every callback below is
    /// stamped with the token that was current when it was scheduled and is
    /// dropped once that is no longer this one — the same trade `LlamaEngine`
    /// makes with its own generation token, so a stale answer never overwrites
    /// the one running now.
    private var token = UUID()

    /// Apple bounds a recognition request to about 60 seconds and ends it
    /// unasked, with an error, once it does. Stopping just ahead of that
    /// turns an internal limit nobody was told about into the same clean stop
    /// as tapping the mic again — whatever was heard is kept, and nothing
    /// that looks like a failure reaches `error`.
    private static let maxListenDuration: Duration = .seconds(58)

    // MARK: - Permission

    /// Puts both system prompts to the user if either has never been shown,
    /// and reports whether listening can start. iOS shows each prompt at most
    /// once; calling this again after a decision re-reads that decision
    /// instead of asking again.
    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        // Asking for the microphone after Speech Recognition was refused
        // would show a permission sheet for a capability that refusal already
        // makes useless, right after the user just said no to the thing next
        // to it.
        guard speechStatus == .authorized else {
            authorization = .denied
            return false
        }
        _ = await AVAudioApplication.requestRecordPermission()
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

    func start() {
        guard !isListening else { return }
        error = nil

        guard isSupported else {
            error = "On-device speech recognition isn't available on this device."
            return
        }

        let liveAuthorization = Self.currentAuthorization()
        authorization = liveAuthorization
        guard liveAuthorization == .granted else {
            error = "Pocketd needs microphone and Speech Recognition access. Turn them on in Settings."
            return
        }

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            error = "Speech recognition isn't available right now. Try again in a moment."
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
            self.error = "Couldn't start the microphone. Try again."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Never set to false. See the type-level comment — this one line is
        // the whole privacy guarantee this class makes.
        request.requiresOnDeviceRecognition = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0) // defensive: a previous session's tap should already be gone

        let sessionToken = UUID()
        token = sessionToken

        // The tap block runs on the audio engine's real-time render thread,
        // never the main actor, so nothing here touches `self` directly.
        // `request` is captured as the local it already is, the level is
        // computed by a nonisolated function, and only those two plain,
        // Sendable values cross the hop to the main actor below.
        //
        // `[weak self]` is repeated on this outer closure even though its own
        // body never names `self`: this closure is stored on `audioEngine`,
        // which `self` owns, and leaving it off let the compiler infer a
        // strong capture from the `self` used inside the `Task` nested in it
        // — a real retain cycle (self → audioEngine → tap → self), not just a
        // style warning, and exactly what `[weak self]` on the inner closure
        // alone looked like it was already preventing.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rmsLevel(of: buffer)
            Task { @MainActor [weak self] in
                self?.updateLevel(level, for: sessionToken)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            self.error = "Couldn't start the microphone. Try again."
            return
        }

        self.recognizer = recognizer
        self.request = request
        transcript = ""
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Neither `SFSpeechRecognitionResult` nor `Error` is Sendable, so
            // everything worth keeping is read out here, on whatever thread
            // the recognizer calls back on, and only plain values make the
            // hop to the main actor.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let description = error.map { String(describing: $0) }
            Task { @MainActor [weak self] in
                self?.handle(token: sessionToken, transcript: transcript, isFinal: isFinal, errorDescription: description)
            }
        }

        scheduleAutoStop(for: sessionToken)
    }

    /// Ends listening and keeps whatever has been transcribed so far.
    func stop() {
        guard isListening else { return }
        isListening = false
        level = 0
        autoStopTask?.cancel()
        autoStopTask = nil
        // Ends the audio rather than cancelling the task, so the recognizer
        // still hands back a final result for whatever was already said —
        // cancelling is what would throw away the last word spoken before the
        // tap landed on Stop. `request`, `task` and `recognizer` are
        // deliberately left in place for that final callback to arrive
        // against; `handle` clears them once it does.
        request?.endAudio()
        teardownAudioEngineAndSession()
    }

    /// Clears the transcript and any error for a fresh turn. Leaves
    /// `isListening` untouched — this is for wiping the slate between uses of
    /// the same instance, not for stopping one that is still listening.
    func reset() {
        transcript = ""
        error = nil
    }

    deinit {
        // A defensive net for a caller that goes away without calling
        // `stop()` first. Both calls are idempotent and safe even when
        // nothing is running.
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // MARK: - Session bookkeeping

    private func scheduleAutoStop(for sessionToken: UUID) {
        autoStopTask?.cancel()
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.maxListenDuration)
            guard !Task.isCancelled else { return }
            guard let self, self.token == sessionToken else { return }
            self.stop()
        }
    }

    private func handle(token callbackToken: UUID, transcript: String?, isFinal: Bool, errorDescription: String?) {
        guard callbackToken == token else { return } // a stale session's last word, arriving after the next one started
        if let transcript {
            self.transcript = transcript
        }
        guard let errorDescription else {
            if isFinal {
                task = nil
                request = nil
                recognizer = nil
            }
            return
        }
        // A cancellation or "no speech" error that follows our own `stop()`
        // is expected — `request.endAudio()` there is exactly what produces
        // one — and must never overwrite a transcript that already holds the
        // user's words with an error message.
        guard isListening else { return }
        isListening = false
        level = 0
        autoStopTask?.cancel()
        autoStopTask = nil
        teardownAudioEngineAndSession()
        task = nil
        request = nil
        recognizer = nil
        self.error = Self.plainMessage(forDescription: errorDescription)
    }

    private func updateLevel(_ raw: Float, for callbackToken: UUID) {
        guard callbackToken == token, isListening else { return }
        // Exponential smoothing: buffers arrive roughly 40 times a second at
        // this tap's buffer size, and a waveform that jumps straight to each
        // new value looks like noise rather than a level.
        let smoothing: Float = 0.3
        level += (raw - level) * smoothing
    }

    private func teardownAudioEngineAndSession() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
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
            return "Pocketd needs microphone and Speech Recognition access. Turn them on in Settings."
        }
        if text.contains("no speech") {
            return "Didn't catch any speech. Try again."
        }
        return "Listening stopped. Try again."
    }
}
