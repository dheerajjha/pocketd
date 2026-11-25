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

    var authorization: Authorization { Self.currentAuthorization() }

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

    private struct Tap { let block: AVAudioNodeTapBlock }
    private let microphone = DictationMicrophone<Tap>(activate: VoiceInput.activateSession, install: VoiceInput.installTap)
    private var recognizer: SFSpeechRecognizer?
    private var capture: VoiceAudioCapture?
    private var task: SFSpeechRecognitionTask?
    private var endingPart = false
    private var finalDeadline: Task<Void, Never>?
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
    func requestAuthorization(while requested: @MainActor () -> Bool) async -> Bool {
        guard !Task.isCancelled, requested(), authorization != .denied else { return false }
        var speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined { speechStatus = await Self.speechAuthorization() }
        // Cancelling a pending turn cannot dismiss a visible OS prompt, but
        // it must not start the next prompt or open the mic.
        guard !Task.isCancelled, requested() else { return false }
        // Asking for the microphone after Speech Recognition was refused
        // would show a permission sheet for a capability that refusal already
        // makes useless, right after the user just said no to the thing next
        // to it.
        guard speechStatus == .authorized else { return false }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        return !Task.isCancelled && requested() && authorization == .granted
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

        guard authorization == .granted else {
            onResult(.failed(Self.refusedSentence))
            return
        }

        let capture = VoiceAudioCapture()
        do {
            try microphone.start(tap: Tap(block: Self.tapBlock(appendingTo: capture, token: sessionToken, owner: self)))
        } catch {
            onResult(.failed("Couldn't start the microphone. Try again."))
            return
        }

        self.recognizer = recognizer
        self.capture = capture
        endingPart = false
        token = sessionToken
        self.onResult = onResult
        isListening = true

        advanceCapture(for: sessionToken)

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
        stopCapture()
        advanceCapture(for: sessionToken)
    }

    /// Only one recognizer runs at a time. The audio tap can already be
    /// feeding the next request while the old one delivers its delayed final.
    private func advanceCapture(for id: UUID) {
        guard id == token, let capture, let recognizer else { return }
        capture.replenish()
        let state = capture.current(), index = state.part
        guard state.ready else { return }
        if task == nil {
            task = recognizer.recognitionTask(with: state.request, resultHandler: Self.handler(owner: self, id: id, part: index))
        }
        guard state.sealed, !endingPart else { return }
        endingPart = true
        state.request.endAudio()
        finalDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.finalWait) } catch { return }
            self?.finishPart(index, for: id, words: nil, timing: .init(), failure: .timedOut)
        }
    }

    func cancel() {
        clearSession(cancellingTask: true)
    }

    private nonisolated static func activateSession() throws -> () -> Void {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        return { try? session.setActive(false, options: [.notifyOthersOnDeactivation]) }
    }

    private enum CaptureError: Error { case noInput }

    private nonisolated static func installTap(_ tap: Tap) throws -> DictationMicrophone<Tap>.InstalledTap {
        let engine = AVAudioEngine()
        // This getter creates the hardware input on demand. It belongs only
        // here, after an explicit mic action and both grants, never in cleanup.
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap.block)
        return (startEngine: { engine.prepare(); try engine.start() }, removeTapAndStopEngine: {
            input.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        })
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
        appendingTo capture: VoiceAudioCapture,
        token: UUID,
        owner: VoiceInput
    ) -> AVAudioNodeTapBlock {
        { [weak owner] buffer, _ in
            let level = rmsLevel(of: buffer)
            let changed = capture.append(buffer, level: level)
            Task { @MainActor [weak owner] in
                owner?.updateLevel(level, for: token)
                if changed { owner?.advanceCapture(for: token) }
            }
        }
    }

    // MARK: - Session bookkeeping

    private nonisolated static func handler(owner: VoiceInput, id: UUID, part: Int) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak owner] result, error in
            let best = result?.bestTranscription, meta = result?.speechRecognitionMetadata
            let words = best?.formattedString, final = result?.isFinal == true
            let timing = DictationTiming(segments: best?.segments.map {
                .init(start: $0.timestamp, duration: $0.duration, substringRange: $0.substringRange)
            } ?? [], speechStart: meta?.speechStartTimestamp, speechDuration: meta?.speechDuration)
            let failure = error.map { String(describing: $0) }
            // SFSpeechRecognitionTask.h documents 1110 in this domain as
            // "Failed to recognize any speech." Other errors aren't silence.
            let noSpeech = error.map { ($0 as NSError).domain == "kAFAssistantErrorDomain" && ($0 as NSError).code == 1110 } == true
            // No SFTranscription/PCM objects or unqualified callbacks cross queues.
            DispatchQueue.main.async { [weak owner] in
                guard let owner, owner.token == id, owner.capture?.acceptsResult(from: part) == true else { return }
                if let failure {
                    if let words { owner.onResult?(.partial(words, timing: timing)) }
                    guard owner.token == id else { return }
                    let message = Self.plainMessage(forDescription: failure)
                    owner.finishPart(part, for: id, words: nil, timing: timing, failure: .failed(message), noSpeech: noSpeech)
                } else if final {
                    owner.finishPart(part, for: id, words: words, timing: timing, failure: nil)
                } else if let words { owner.onResult?(.partial(words, timing: timing)) }
            }
        }
    }

    private func finishPart(_ part: Int, for id: UUID, words: String?, timing: DictationTiming, failure: DictationHandoff.Event?, noSpeech: Bool = false) {
        guard id == token, let state = capture?.finish(at: part) else { return }
        finalDeadline?.cancel()
        if state.hasNext {
            let old = task
            task = nil
            endingPart = false
            if failure != nil { old?.cancel() }
            onResult?(.nextRequest(final: words, timing: timing))
            advanceCapture(for: id)
        } else if part > 0, state.quietOnly, noSpeech || (failure == nil && (words ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            resolve(.emptyTail, for: id)
        } else {
            resolve(failure ?? .final(words ?? "", timing: timing), for: id, cancellingTask: failure != nil)
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
        finalDeadline?.cancel()
        finalDeadline = nil
        stopCapture()
        if cancellingTask { task?.cancel() }
        task = nil
        capture = nil
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

    private func stopCapture() {
        capture?.close()
        isListening = false
        level = 0
        microphone.stop()
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
        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .denied || speech == .restricted {
            return "Speech Recognition is off for Pocketd in iOS Settings."
        }
        if AVAudioApplication.shared.recordPermission == .denied {
            return "Microphone is off for Pocketd in iOS Settings."
        }
        return "Pocketd can't listen right now. Try again."
    }

    static let unavailableSentence = "Speech recognition isn't available on this iPhone right now."
}

/// The audio thread appends each buffer to exactly one Apple request. Requests
/// are preallocated off the render thread. The lock makes swapping the writer
/// atomic with ending it on the main actor; no PCM leaves the request or goes to disk.
private final class VoiceAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = [makeRequest()]
    private var spare: SFSpeechAudioBufferRecognitionRequest? = makeRequest()
    private var routing = DictationAudioRequests()

    private static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        return request
    }

    func append(_ buffer: AVAudioPCMBuffer, level: Float) -> Bool {
        lock.withLock {
            guard let write = routing.write(level: level, seconds: Double(buffer.frameLength) / buffer.format.sampleRate,
                                            spareReady: spare != nil) else { return false }
            requests[write.part].append(buffer)
            if write.opensNext, let spare {
                requests.append(spare)
                self.spare = nil
            }
            return write.opensNext || write.woke
        }
    }

    func replenish() {
        guard lock.withLock({ spare == nil }) else { return }
        let next = Self.makeRequest()
        lock.withLock { if spare == nil { spare = next } }
    }

    func current() -> (part: Int, request: SFSpeechAudioBufferRecognitionRequest, ready: Bool, sealed: Bool) {
        lock.withLock {
            let index = routing.reader
            let state = routing.state(at: index)
            return (index, requests[index], state.ready, state.sealed)
        }
    }

    func acceptsResult(from index: Int) -> Bool { lock.withLock { routing.acceptsResult(from: index) } }

    func finish(at index: Int) -> (hasNext: Bool, quietOnly: Bool)? {
        lock.withLock { routing.finish(at: index) }
    }

    func close() { lock.withLock { routing.close() } }
}
