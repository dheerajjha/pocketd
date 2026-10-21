import PocketdKit
import SwiftUI

/// The questions the conversation puts in somebody's mouth.
///
/// An assistant that can read a calendar is useless if nobody knows it can, and
/// "Ask me anything" is the worst prompt in software. These are written as the
/// sentence a person would actually type — sentence case, question mark, no
/// imperative — because that is what makes them read as examples rather than as
/// buttons.
struct AskSuggestion: Identifiable, Equatable {
    var id: String { text }
    /// What the row or chip says.
    let text: String
    let symbol: String
    /// What has to be on for this to be answerable, or `nil` where nothing is.
    let ability: Ability?
    /// What goes in the box when this is not sent as it stands. "Remind me
    /// to " — the person finishes the sentence, with the cursor after it.
    var stem: String?

    /// Whether a tap asks at once.
    var sends: Bool { stem == nil }

    /// The empty conversation's three examples: one look at the calendar, one
    /// at the reminders, and one that shows Pocketd can *do* something.
    ///
    /// The third is half a sentence, and deliberately so. An example that
    /// files a reminder the moment it is tapped would put "call Mom" in
    /// somebody's real Reminders because they wanted to see what the row did.
    static let examples: [AskSuggestion] = [
        AskSuggestion(text: "What's on today?", symbol: "calendar", ability: .calendar),
        AskSuggestion(text: "Anything overdue?", symbol: "checklist", ability: .reminders),
        AskSuggestion(text: "Remind me to…", symbol: "bell", ability: .reminders, stem: "Remind me to "),
    ]

    /// The one question worth asking next, chosen from what the last answer
    /// actually drew rather than from what it said.
    ///
    /// One chip and never a row of them. A row of follow-ups turns a
    /// conversation into a quiz; one is the obvious next thing, and it only
    /// exists because a card above it already narrowed the subject. It stays in
    /// that card's domain — the day after the day just read, the reminders due
    /// after the ones just listed — so the answer it gets is one the same tool
    /// can give.
    ///
    /// Two candidates each, so the chip never offers back the question that was
    /// just asked.
    static func followUp(
        after cards: [AnswerCard],
        lastQuestion: String?,
        now: Date = DemoClock.now,
        calendar: Calendar = .current
    ) -> AskSuggestion? {
        guard let card = cards.last(where: { $0.source != nil }), let source = card.source else { return nil }
        // A write is about the day it was for: after "Added lunch… for
        // tomorrow", "What else is on today?" asks about the wrong day.
        let written = writtenDay(of: card, now: now, calendar: calendar)
        let candidates: [String]
        let symbol: String
        let ability: Ability
        switch source {
        case PersonalDataToolNames.calendar:
            symbol = "calendar"
            ability = .calendar
            candidates = switch (card.title, written) {
            case ("Today", _): ["What's on tomorrow?", "What's on this week?"]
            case ("Tomorrow", _): ["What's on this week?", "What's on today?"]
            case ("This week", _): ["What's on next week?", "What's on tomorrow?"]
            case ("Next week", _): ["What's on this week?", "What's on tomorrow?"]
            case (_, .today?): ["What else is on today?", "What's on tomorrow?"]
            case (_, .tomorrow?): ["What else is on tomorrow?", "What's on today?"]
            case (_, nil): ["What's on this week?", "What's on today?"]
            }
        case PersonalDataToolNames.reminders:
            symbol = "checklist"
            ability = .reminders
            candidates = switch (card.title, written) {
            case ("Overdue", _): ["What's due today?", "What's due tomorrow?"]
            case ("Due today", _): ["What's due tomorrow?", "Anything overdue?"]
            case ("Due tomorrow", _): ["What's due this week?", "Anything overdue?"]
            case ("Due this week", _), ("Open reminders", _): ["Anything overdue?", "What's due today?"]
            case (_, .today?): ["What else is due today?", "Anything overdue?"]
            case (_, .tomorrow?): ["What else is due tomorrow?", "What's due today?"]
            case (_, nil): ["What's due this week?", "Anything overdue?"]
            }
        case PersonalDataToolNames.health:
            ability = .health
            if card.title == "Sleep" {
                symbol = "figure.walk"
                candidates = ["How active was I today?", "How did I sleep this week?"]
            } else {
                symbol = "bed.double"
                candidates = ["How did I sleep last night?", "How active was I today?"]
            }
        default:
            return nil
        }
        let asked = lastQuestion.map(normalised)
        guard let text = candidates.first(where: { normalised($0) != asked }) else { return nil }
        return AskSuggestion(text: text, symbol: symbol, ability: ability)
    }

    enum WrittenDay { case today, tomorrow }

    /// The day a write was for, read from its own sentence — "Reminder set:
    /// “Call Mom” for Thu, 22 Oct at 6:00 PM." — which the tool wrote with
    /// `PersonalDataFormat`, so the same formatter finds it. `nil` for a reading
    /// (it has rows) or for a day further off.
    static func writtenDay(of card: AnswerCard, now: Date, calendar: Calendar) -> WrittenDay? {
        guard card.sections.isEmpty, let lede = card.lede else { return nil }
        if lede.contains(PersonalDataFormat.day(now, timeZone: calendar.timeZone, calendar: calendar)) { return .today }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        if lede.contains(PersonalDataFormat.day(tomorrow, timeZone: calendar.timeZone, calendar: calendar)) { return .tomorrow }
        return nil
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

    /// Case and punctuation aside, so "what's on tomorrow" typed by hand still
    /// counts as the chip's own question.
    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }
}
