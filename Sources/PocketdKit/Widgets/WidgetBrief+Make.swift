import Foundation

public extension WidgetBrief {

    /// Denormalises a `DailyBrief` down to what a home screen may show.
    ///
    /// Here rather than on `WidgetBrief` itself so that the type and its store
    /// stay free of PocketdKit — see the note at the bottom of WidgetBrief.swift.
    /// Only the app ever calls this; the widget only reads.
    static func make(
        from brief: DailyBrief,
        name: String?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> WidgetBrief {
        let kind = TimeOfDayKind.from(now: now, calendar: calendar)
        let next = brief.snapshot.nextEvent(now: now)
        return WidgetBrief(
            greetingLine: BriefPrompt.displayName(name).map { "\(kind.greeting), \($0)" } ?? kind.greeting,
            firstSentence: firstSentence(of: brief.text),
            // Nil rather than "Nothing on" when the calendar is switched off, so
            // the widget can tell "your day is clear" from "I cannot see your
            // day" — the same distinction the tiles make, and the one that
            // decides whether the small widget is reassuring or wrong.
            nextEventTitle: brief.snapshot.calendar.isReadable ? next?.title : nil,
            nextEventTime: brief.snapshot.calendar.isReadable ? next?.start : nil,
            dueCount: brief.snapshot.reminders.isReadable ? brief.snapshot.dueToday.count : 0,
            generatedAt: brief.generatedAt
        )
    }

    /// The first sentence, or the whole thing if it is one sentence long.
    ///
    /// Split on the punctuation rather than by asking for a shorter generation,
    /// because the brief the user reads in the app and the line on their home
    /// screen have to be the same words. Two generations would drift, and the
    /// widget's version would be the one nobody proof-read.
    ///
    /// A decimal point is not a full stop. "You walked 4.2 km" has to survive,
    /// so a stop only ends a sentence when what follows is a space or nothing.
    static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            let next = trimmed.index(after: index)
            if character == "." || character == "!" || character == "?" {
                if next == trimmed.endIndex || trimmed[next] == " " {
                    return String(trimmed[trimmed.startIndex...index])
                }
            }
            index = next
        }
        return trimmed
    }
}
