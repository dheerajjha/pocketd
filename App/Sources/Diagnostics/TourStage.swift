#if DEBUG
import Foundation
import PocketdKit

/// The App Store preview's motion, played by the app itself: `-pocketd.tour`.
///
/// The preview is recorded off a simulator with `simctl io recordVideo`, and
/// Xcode 27's simulator never delivers a tap, so without this nothing on screen
/// would move. It walks the path a person takes — Today, a tile's page, a
/// question and its answer, a reminder set, Routines — on a timer, through the
/// same `Navigator` calls a tap makes. The conversation is drawn with the card
/// builders `-pocketd.previewChat` uses, and the reminder is a real write with
/// a real Undo, as there.
///
///     xcrun simctl launch --console-pty <udid> dev.pocketd.app \
///         -pocketd.seedDemo -pocketd.skipIntro -pocketd.demoHealth \
///         -pocketd.demoRoutines -pocketd.demoTime 09:41 \
///         -pocketd.tour -pocketd.tourLead 6
///
/// `-pocketd.tourLead` is how many seconds Today holds before the first beat
/// (default 6), so the recorder can be started after launch. Every beat prints
/// its time on the console, so the edit can be cut on the beats rather than
/// guessed. Entirely inside `#if DEBUG`, imports included.
@MainActor
enum TourStage {
    private static var started = false
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isRequested: Bool { arguments.contains("-pocketd.tour") }

    private static var lead: Double {
        guard let index = arguments.firstIndex(of: "-pocketd.tourLead"),
              arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]) else { return 6 }
        return seconds
    }

    static func runIfRequested(model: AppModel, navigator: Navigator) async {
        guard isRequested, !started else { return }
        started = true
        let clock = ContinuousClock()
        let start = clock.now
        let lead = lead

        /// Waits for the beat. False when the task was cancelled — the shell
        /// went away — so the rest of the walk does not rush through at once.
        func beat(_ seconds: Double, _ name: String) async -> Bool {
            do {
                try await clock.sleep(until: start + .seconds(lead + seconds))
            } catch {
                return false
            }
            print("pocketd.tour \(name) t=\(String(format: "%.1f", lead + seconds))s")
            return true
        }

        guard await beat(0, "today") else { return }

        guard await beat(4.0, "sleep") else { return }
        navigator.open(.sleep)

        guard await beat(8.5, "back") else { return }
        navigator.go(.today)

        guard await beat(10.0, "ask") else { return }
        await model.newConversation()
        navigator.go(.ask)

        guard await beat(11.2, "question") else { return }
        ask("What's on tomorrow?", tool: PersonalDataToolNames.calendar, model)

        guard await beat(12.6, "answer") else { return }
        answer(content: AskPreviewChat.calendarSentence, cards: [AskPreviewChat.calendarCard()].compactMap { $0 }, model)

        guard await beat(15.0, "reminder-question") else { return }
        ask("Remind me to call the plumber at 5", tool: PersonalDataToolNames.reminders, model)

        guard await beat(16.2, "reminder-set") else { return }
        let written = await AskPreviewChat.writeARealReminder("Call the plumber", when: "5pm today", clearingWith: model)
        answer(content: "", cards: [written].compactMap { $0 }, model)

        guard await beat(19.8, "routines") else { return }
        navigator.go(.routines)

        _ = await beat(24.0, "end")
    }

    /// The question in its bubble, then the orb naming the tool it reads —
    /// the two things `send()` puts on screen before any word of the answer.
    private static func ask(_ question: String, tool: String, _ model: AppModel) {
        model.conversation.append(.user(question))
        model.conversation.append(ChatMessage(role: .assistant, content: "", cards: []))
        model.activeToolName = tool
        model.isGenerating = true
    }

    /// The reply in the slot the orb held.
    private static func answer(content: String, cards: [AnswerCard], _ model: AppModel) {
        if let last = model.conversation.indices.last, model.conversation[last].role == .assistant {
            model.conversation[last] = ChatMessage(role: .assistant, content: content, cards: cards)
        }
        model.activeToolName = nil
        model.isGenerating = false
    }
}
#endif
