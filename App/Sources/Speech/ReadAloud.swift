import AVFoundation
import Foundation
import Observation

/// Reads a block of text aloud, for a speaker button on the Ask and Today
/// screens.
///
/// One synthesizer, one utterance at a time: calling `speak` while something
/// is already playing replaces it rather than queueing behind it, which is
/// what a second tap of "read this" should mean. `AVSpeechSynthesizerDelegate`
/// is how the synthesizer answers back, and its methods are not isolated to
/// any actor — AVFoundation calls them from whatever thread it pleases — so
/// every one of them below only reads out the plain, `Sendable` values it
/// needs and hops onto the main actor with `Task { @MainActor in }` before
/// touching anything this class stores. `MainActor.assumeIsolated` would be
/// cheaper, but it is also a promise Apple's docs do not make for this
/// delegate, and the failure mode for being wrong about it is a crash rather
/// than a dropped update.
@MainActor
@Observable
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {

    private(set) var isSpeaking: Bool = false
    /// The range of the utterance currently being spoken, in its own string,
    /// so a caller can highlight along with the voice. `nil` whenever nothing
    /// is speaking.
    private(set) var spokenRange: NSRange?

    private let synthesizer = AVSpeechSynthesizer()

    /// Identifies the utterance `speak` most recently started.
    ///
    /// The delegate methods below are handed the `AVSpeechUtterance` they are
    /// about, but that object is not `Sendable` and cannot cross the hop to
    /// the main actor. Its identity can: `ObjectIdentifier` is a plain,
    /// comparable value, and comparing it against this is what stops a
    /// cancellation callback for an utterance `speak` has already replaced
    /// from being mistaken for the end of the one now playing — without it,
    /// calling `speak` again before the previous line finished would let that
    /// old utterance's `didCancel` land a moment later and turn `isSpeaking`
    /// off underneath the new one.
    private var currentUtteranceID: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text`, replacing anything currently playing.
    func speak(_ text: String) {
        stop()
        let cleaned = Self.cleaned(text)
        guard !cleaned.isEmpty else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // No error surface on this class to report a session failure to —
            // a speaker button that silently does nothing is the honest
            // result of a session that would not open, and the next tap tries
            // again rather than getting stuck behind a stored message.
            return
        }

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = Self.bestVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0

        currentUtteranceID = ObjectIdentifier(utterance)
        spokenRange = nil
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Stops speaking. `isSpeaking` and `spokenRange` are cleared by the
    /// `didCancel` delegate callback this triggers, not here — that keeps
    /// there being exactly one place speech is considered "over".
    func stop() {
        guard isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    func toggle(_ text: String) {
        if isSpeaking {
            stop()
        } else {
            speak(text)
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.updateSpokenRange(characterRange, for: id)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finish(for: id)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finish(for: id)
        }
    }

    private func updateSpokenRange(_ range: NSRange, for id: ObjectIdentifier) {
        guard id == currentUtteranceID else { return }
        spokenRange = range
    }

    private func finish(for id: ObjectIdentifier) {
        guard id == currentUtteranceID else { return } // an old utterance winding down after `speak` replaced it
        isSpeaking = false
        spokenRange = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Voice

    /// The best installed voice for the language the system is currently set
    /// to. Personal Voice aside, `.premium` sounds meaningfully less robotic
    /// than `.enhanced`, and `.enhanced` than the default compact voice — but
    /// which of them a person has actually downloaded, at Settings >
    /// Accessibility > Spoken Content > Voices, varies per device, so this
    /// asks rather than assumes and falls back a step at a time.
    private nonisolated static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let installed = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        if let premium = installed.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = installed.first(where: { $0.quality == .enhanced }) { return enhanced }
        return installed.first ?? AVSpeechSynthesisVoice(language: language)
    }

    // MARK: - Text

    /// Collapses whitespace and drops the markdown characters this app's own
    /// answers are written in, so the voice says "bold", not "asterisk
    /// asterisk bold asterisk asterisk". A blunt per-character filter rather
    /// than a markdown parser: nothing here needs to know what the symbols
    /// meant, only that none of them are ever a word worth speaking. The one
    /// trade-off is a stray underscore inside a word — `my_variable` reads as
    /// "myvariable" — which is the right side to be wrong on for text a voice
    /// is about to read out loud rather than display.
    private nonisolated static func cleaned(_ text: String) -> String {
        var stripped = ""
        stripped.reserveCapacity(text.count)
        for character in text where !"*_#`".contains(character) {
            stripped.append(character)
        }
        return stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
