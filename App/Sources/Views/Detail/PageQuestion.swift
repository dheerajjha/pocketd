import PocketdKit
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
/// The source travels with the tap. A recent question on the same page can
/// continue that discussion; a recent question about another subject cannot.
@MainActor
enum PageQuestion {

    /// The chip above the composer, for `question`.
    static func suggestion(_ question: String, topic: ConversationTopic, navigator: Navigator, model: AppModel) -> ContextComposer.Suggestion {
        ContextComposer.Suggestion(question) {
            let action: AskEntryRequest.Action = unfinished(question).map { .draft($0) }
                ?? .send(question, usingCloud: model.isUsingPrivateCloudCompute)
            navigator.requestAsk(.page(topic), action)
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
        topic: ConversationTopic?,
        placeholder: String = "Ask anything else",
        navigator: Navigator,
        model: AppModel
    ) -> ContextComposer {
        let entry: ConversationEntry = topic.map(ConversationEntry.page) ?? .main
        return ContextComposer(
            suggestion: question.map { suggestion($0, topic: topic ?? TodayQuestion.topic(for: $0), navigator: navigator, model: model) },
            placeholder: placeholder,
            onAsk: { navigator.requestAsk(entry, .keyboard) },
            // No mic at all where nothing can listen: a button that only opens
            // the keyboard would be a mic that lies.
            onMic: canListen ? { navigator.requestAsk(entry, .voice) } : nil
        )
    }
}
