import Speech
import SwiftUI

/// The one question a page offers above its composer, and what a tap on it
/// does.
///
/// Today and every page behind its tiles offer exactly one question, and they
/// all mean the same two things by it. A whole question ("What's on today?")
/// is asked at once. Half a sentence ("Remind me to…") is put in the box with
/// the cursor after it, because the person is the one who finishes it. The
/// ellipsis is how a page writes "half a sentence", so it is also how this
/// tells the two apart: no page has to carry a second flag saying which kind
/// its question is.
///
/// Nothing here talks to a brain. The page hands the question to the
/// `Navigator`, and the conversation sheet sends it through `askFresh`, which
/// starts a new conversation unless the open one was used in the last half
/// hour — so a question about sleep never lands at the bottom of yesterday's
/// chat about something else (the ask contract in TEAM-B).
@MainActor
enum PageQuestion {

    /// The chip above the composer, for `question`.
    static func suggestion(_ question: String, navigator: Navigator) -> ContextComposer.Suggestion {
        ContextComposer.Suggestion(question) { ask(question, navigator: navigator) }
    }

    /// Asks `question`, or starts it when it is unfinished.
    static func ask(_ question: String, navigator: Navigator) {
        if let stem = unfinished(question) {
            navigator.ask(stem, send: false)
        } else {
            navigator.ask(question, send: true)
        }
    }

    /// "Remind me to…" as the box should hold it — "Remind me to " with the
    /// cursor after the space — or nil for a whole question.
    static func unfinished(_ question: String) -> String? {
        guard question.hasSuffix("…") || question.hasSuffix("...") else { return nil }
        let stem = question
            .trimmingCharacters(in: CharacterSet(charactersIn: "…."))
            .trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? nil : stem + " "
    }

    /// The field itself: the conversation, on the conversation that is open.
    /// The sheet puts the cursor in its own box when it appears.
    static func openConversation(navigator: Navigator) {
        navigator.go(.ask)
    }

    /// The mic: the conversation, already listening.
    ///
    /// `askComposerFocusRequested` is the request the Control Center button
    /// makes — the cursor, and the microphone where the phone can hear on
    /// device — so the mic here asks for exactly what that button does.
    static func listen(navigator: Navigator, model: AppModel) {
        model.askComposerFocusRequested = true
        navigator.go(.ask)
    }

    /// Whether this phone can listen without a server, which is the only way
    /// Pocketd listens. Asked once a launch: a mic that appears or vanishes
    /// mid-session would be stranger than one that waits for the next launch
    /// to notice a language pack arriving.
    static let canListen: Bool = SFSpeechRecognizer()?.supportsOnDeviceRecognition ?? false

    /// A page's whole composer: its question, the placeholder, the door.
    ///
    /// "Ask anything else" on a detail page, where the page above is already
    /// one answer; Today passes its own "Ask about your day…".
    static func composer(
        _ question: String?,
        placeholder: String = "Ask anything else",
        navigator: Navigator,
        model: AppModel
    ) -> ContextComposer {
        ContextComposer(
            suggestion: question.map { suggestion($0, navigator: navigator) },
            placeholder: placeholder,
            onAsk: { openConversation(navigator: navigator) },
            // No mic at all where nothing can listen: a button that only opens
            // the keyboard would be a mic that lies.
            onMic: canListen ? { listen(navigator: navigator, model: model) } : nil
        )
    }
}
