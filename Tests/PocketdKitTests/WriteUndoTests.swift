import Foundation
import Testing
@testable import PocketdKit

/// The Undo pill is a promise on a store page, so it has to be right in the
/// direction that matters: never offered where pressing it would remove
/// something the user did not just create.
///
/// Every case below is a way the join between a write and the card that reports
/// it could land on the wrong thing — a different tool, a stale write, a list
/// that merely mentions the words, a title that is a substring of another.
@Suite("Undo on a write card")
struct WriteUndoTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func reminderWrite(
        _ title: String,
        ago seconds: TimeInterval = 0,
        identifier: String = "x-1"
    ) -> PersonalDataWrite {
        PersonalDataWrite(
            kind: .reminder,
            identifier: identifier,
            title: title,
            madeAt: now.addingTimeInterval(-seconds)
        )
    }

    private func reminderCard(_ lede: String) -> AnswerCard {
        AnswerCard(
            source: PersonalDataToolNames.reminders,
            symbol: "checklist",
            title: "Reminders",
            lede: lede
        )
    }

    @Test("the card a create produces carries the write that made it")
    func theMotivatingCase() {
        // The exact sentence `PersonalDataWrites.confirmation` writes.
        let card = reminderCard("Reminder set: \"Call the dentist\" for 4:00 PM.")
        let write = reminderWrite("Call the dentist")

        #expect(WriteUndo.offer(for: card, from: [write], now: now) == write)
    }

    @Test("a calendar create is matched by the calendar card, not the reminders one")
    func kindsDoNotCross() {
        let event = PersonalDataWrite(kind: .event, identifier: "e-1", title: "Lunch", madeAt: now)
        let calendarCard = AnswerCard(
            source: PersonalDataToolNames.calendar,
            symbol: "calendar",
            title: "Calendar",
            lede: "Added \"Lunch\" to your calendar for tomorrow at 1:00 PM."
        )
        // Same words, wrong tool. A reminders card quoting "Lunch" must not
        // offer to delete a calendar event.
        let impostor = reminderCard("Reminder set: \"Lunch\" for tomorrow.")

        #expect(WriteUndo.offer(for: calendarCard, from: [event], now: now) == event)
        #expect(WriteUndo.offer(for: impostor, from: [event], now: now) == nil)
    }

    @Test("a write older than the window is no longer offered")
    func theOfferExpires() {
        let card = reminderCard("Reminder set: \"Call the dentist\" for 4:00 PM.")

        #expect(WriteUndo.offer(for: card, from: [reminderWrite("Call the dentist", ago: 299)], now: now) != nil)
        #expect(WriteUndo.offer(for: card, from: [reminderWrite("Call the dentist", ago: 300)], now: now) == nil)
        #expect(WriteUndo.offer(for: card, from: [reminderWrite("Call the dentist", ago: 3_600)], now: now) == nil)
    }

    @Test("a card with rows in it is a reading, whatever it quotes")
    func aListIsNeverAWrite() {
        // The failure this prevents: somebody creates "Call the dentist", then
        // asks what is open, and the list that comes back grows an Undo button
        // that deletes a reminder they were only looking at.
        let list = AnswerCard(
            source: PersonalDataToolNames.reminders,
            symbol: "checklist",
            title: "Open reminders",
            lede: "Here is what is open, including \"Call the dentist\".",
            sections: [.list(AnswerCard.Items(eyebrow: "2 reminders", items: [
                AnswerCard.Item(text: "Call the dentist"),
                AnswerCard.Item(text: "Buy milk"),
            ]))]
        )

        #expect(WriteUndo.offer(for: list, from: [reminderWrite("Call the dentist")], now: now) == nil)
    }

    @Test("an unquoted mention is not a match")
    func onlyTheQuotedTitleCounts() {
        // "That reminder is already on the list" — no write happened, and the
        // sentence names nothing in quotes.
        let card = reminderCard("That reminder is already on the list for 4:00 PM.")
        #expect(WriteUndo.offer(for: card, from: [reminderWrite("Call the dentist")], now: now) == nil)

        // The title is present but bare. Quoting is what the confirmation does,
        // so anything without quotes came from somewhere else.
        let bare = reminderCard("Reminder set: Call the dentist for 4:00 PM.")
        #expect(WriteUndo.offer(for: bare, from: [reminderWrite("Call the dentist")], now: now) == nil)
    }

    @Test("the newer of two writes with the same title wins")
    func newestWins() {
        let card = reminderCard("Reminder set: \"Bins\" for 7:00 AM.")
        let older = reminderWrite("Bins", ago: 200, identifier: "r-old")
        let newer = reminderWrite("Bins", ago: 4, identifier: "r-new")

        #expect(WriteUndo.offer(for: card, from: [older, newer], now: now)?.identifier == "r-new")
        #expect(WriteUndo.offer(for: card, from: [newer, older], now: now)?.identifier == "r-new")
    }

    @Test("a longer title is not matched by a card quoting a shorter one")
    func substringsDoNotMatch() {
        // "Call" is a prefix of "Call the dentist". The quotes are what stop
        // the shorter write claiming the longer card.
        let card = reminderCard("Reminder set: \"Call the dentist\" for 4:00 PM.")
        #expect(WriteUndo.offer(for: card, from: [reminderWrite("Call")], now: now) == nil)
    }

    @Test("a card with no source or no sentence is never a write")
    func theEmptyShapes() {
        let write = reminderWrite("Call the dentist")
        let sourceless = AnswerCard(lede: "Reminder set: \"Call the dentist\" for 4:00 PM.")
        let sentenceless = AnswerCard(source: PersonalDataToolNames.reminders, title: "Reminders")

        #expect(WriteUndo.offer(for: sourceless, from: [write], now: now) == nil)
        #expect(WriteUndo.offer(for: sentenceless, from: [write], now: now) == nil)
    }

    @Test("what the card says once it has been taken back")
    func theUndoneSentence() {
        #expect(
            WriteUndo.undoneSentence(for: reminderWrite("Call the dentist"))
                == "Removed the reminder \"Call the dentist\"."
        )
        #expect(
            WriteUndo.undoneSentence(
                for: PersonalDataWrite(kind: .event, identifier: "e", title: "Lunch", madeAt: now)
            ) == "Removed \"Lunch\" from your calendar."
        )
    }
}
