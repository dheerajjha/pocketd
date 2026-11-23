import AppIntents
import Foundation

/// Asking the assistant from Siri, Shortcuts, Spotlight or the Action Button.
///
/// The intent hands the question to the app so the same brain choice and
/// connected sources apply as in Ask. Downloaded models also need the app's
/// memory budget rather than an extension's.
struct AskPocketdIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Pocketd"

    static let description = IntentDescription(
        // Plain, and no promise about what it can read: that depends on what
        // is connected and on the brain, and Shortcuts shows this line to
        // somebody who may have connected neither.
        //
        // No Apple product names in any App Intent or App Shortcut string:
        // App Store processing rejects the binary for them (ITMS-90626,
        // "cannot contain 'iphone'"), and nothing fails until the upload.
        "Ask Pocketd about your day using the brain you chose in the app.",
        categoryName: "Assistant"
    )

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
/// style choice — so they all read "ask Pocketd ...".
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
