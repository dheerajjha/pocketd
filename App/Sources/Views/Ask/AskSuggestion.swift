import PocketdKit
import SwiftUI

/// The questions the screen puts in somebody's mouth.
///
/// An assistant that can read a calendar is useless if nobody knows it can, and
/// "Ask me anything" is the worst prompt in software. These are written as the
/// sentence a person would actually type — sentence case, question mark, no
/// imperative — because that is what makes them read as examples rather than as
/// buttons.
///
/// Each one carries the ability it needs, so a row can offer to switch that on
/// instead of sending a question the app is about to have to refuse.
struct AskSuggestion: Identifiable, Equatable {
    var id: String { text }
    let text: String
    let symbol: String
    /// What has to be on for this to be answerable, or `nil` where nothing is.
    let ability: Ability?

    /// The empty screen's four openings: one per ability, plus the one that
    /// shows it can *do* something rather than only look things up.
    static let openings: [AskSuggestion] = [
        AskSuggestion(text: "What's on tomorrow?", symbol: "calendar", ability: .calendar),
        AskSuggestion(text: "Anything overdue?", symbol: "checklist", ability: .reminders),
        AskSuggestion(text: "How did I sleep this week?", symbol: "bed.double", ability: .health),
        AskSuggestion(text: "Remind me to call the dentist at 4", symbol: "bell", ability: .reminders),
    ]

    /// The one question worth asking next, chosen from what the last answer
    /// actually drew rather than from what it said.
    ///
    /// One chip and never a row of them. A row of follow-ups turns a
    /// conversation into a quiz, and the whole value of this one is that it is
    /// the obvious next thing — which only exists because a card above it
    /// already narrowed the subject.
    static func followUp(after cards: [AnswerCard]) -> AskSuggestion? {
        guard let source = cards.last(where: { $0.source != nil })?.source else { return nil }
        switch source {
        case PersonalDataToolNames.calendar:
            return AskSuggestion(text: "Does anything clash with it?", symbol: "calendar", ability: .calendar)
        case PersonalDataToolNames.reminders:
            return AskSuggestion(text: "What else is due today?", symbol: "checklist", ability: .reminders)
        case PersonalDataToolNames.health:
            return AskSuggestion(text: "Any trends across the week?", symbol: "chart.line.uptrend.xyaxis", ability: .health)
        default:
            return nil
        }
    }

    /// What the app says it is doing while a tool runs.
    ///
    /// Plain words for the three tools, and a plain fallback for anything else:
    /// a tool name is an implementation detail and "Running get_health_summary…"
    /// is the sentence this whole app exists not to show anybody.
    static func checkingSentence(forTool name: String) -> String {
        switch name {
        case PersonalDataToolNames.calendar: "Checking your calendar…"
        case PersonalDataToolNames.reminders: "Checking your reminders…"
        case PersonalDataToolNames.health: "Reading your health data…"
        default: "Looking that up…"
        }
    }
}
