import AppIntents
import Foundation

/// Asking the assistant from Siri, Shortcuts, Spotlight or the Action Button.
///
/// The gap this closes is competitive and specific: Enclave and Private LLM
/// both advertise Siri and Shortcuts on their App Store listing, and this app
/// had no App Intents at all. One implementation covers all four entry points.
///
/// It is also the one place where our version of the feature is not the same as
/// theirs. Their shortcut hands text to a model that knows nothing about the
/// person holding the phone. "Hey Siri, ask Pocketd what's on tomorrow" reads
/// an actual calendar, on the device, and the answer never leaves it.
///
/// `openAppWhenRun` is true and that is not laziness. The weights are between
/// one and three gigabytes and live in this process; an App Intents extension
/// runs under a memory budget that a model load would blow through instantly,
/// and the failure would be a silent kill rather than an error anybody could
/// read. Opening the app is the honest version.
struct AskPocketdIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Pocketd"

    static let description = IntentDescription(
        "Ask the assistant on this phone a question. It can read your calendar, your reminders and your Health data, and answers without anything leaving the device.",
        categoryName: "Assistant"
    )

    /// The model lives in the app. See the note above.
    static let openAppWhenRun: Bool = true

    @Parameter(
        title: "Question",
        description: "What to ask, in your own words.",
        requestValueDialog: "What would you like to ask?"
    )
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Pocketd \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.deliver(question)
        return .result()
    }
}

/// The phrases Siri will recognise without the user building a shortcut first.
///
/// Every phrase has to contain `\(.applicationName)` — Apple's rule, not a
/// style choice — so they all read "ask Pocketd ...". The list leans on the
/// three abilities rather than on the word "chat", because a question about a
/// chat is a question any of a dozen apps can take and a question about
/// tomorrow is one only this app can answer locally.
struct PocketdShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPocketdIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) what's on today",
                "Ask \(.applicationName) what's on tomorrow",
                "Ask \(.applicationName) what's due",
                "Ask \(.applicationName) to set a reminder",
                "Ask \(.applicationName) how I slept"
            ],
            shortTitle: "Ask Pocketd",
            systemImageName: "sparkles"
        )
    }
}
