import Foundation
import Testing
@testable import PocketdKit

/// The half of "manage my reminders" that decides whether it is trustworthy.
///
/// Reading somebody's calendar wrongly wastes a turn. Writing to it wrongly
/// leaves something behind that they did not ask for and may not find for
/// weeks — and on this app the text in the context is partly written by
/// strangers, because a meeting invite is. So most of what follows is about
/// what must NOT happen, and the spies below exist to assert that EventKit was
/// never reached rather than that it returned the right thing.
@Suite("Personal data writes")
struct PersonalDataWriteTests {

    /// Records whether it was asked to do anything at all.
    final class WriteSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _reminders: [NewReminder] = []
        private var _events: [NewEvent] = []
        private var _completed: [ReminderRow] = []

        var reminders: [NewReminder] { lock.lock(); defer { lock.unlock() }; return _reminders }
        var events: [NewEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        var completed: [ReminderRow] { lock.lock(); defer { lock.unlock() }; return _completed }
        var touched: Bool { !reminders.isEmpty || !events.isEmpty || !completed.isEmpty }

        func write(_ reminder: NewReminder) -> WriteResult {
            lock.lock(); _reminders.append(reminder); lock.unlock(); return .written
        }
        func write(_ event: NewEvent) -> WriteResult {
            lock.lock(); _events.append(event); lock.unlock(); return .written
        }
        func complete(_ row: ReminderRow) -> WriteResult {
            lock.lock(); _completed.append(row); lock.unlock(); return .written
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 1, minute: 45))!
    }

    private func create(
        title: String? = "Take the bins out",
        when: String? = "in 30 minutes",
        origin: RequestOrigin = .onDeviceChat,
        open rows: [ReminderRow] = [],
        spy: WriteSpy
    ) async -> [String: any Sendable] {
        await PersonalDataWrites.createReminder(
            title: title,
            when: when,
            now: now,
            calendar: calendar,
            origin: origin,
            existing: { .rows(rows, truncated: false) },
            write: { spy.write($0) }
        )
    }

    private func text(_ payload: [String: any Sendable]) -> String {
        payload["text"] as? String ?? ""
    }

    // MARK: - Who may write

    @Test("a network caller causes no write at all")
    func networkWritesNothing() async {
        // Not a refused write, not an empty one — none. The same property the
        // read tools assert, and it matters more here: a network client that
        // could file reminders on somebody's phone is a far worse thing to get
        // wrong than one that could read them.
        let spy = WriteSpy()
        let payload = await create(origin: .network(host: "192.168.1.44", port: 55_000), spy: spy)
        #expect(!spy.touched, "EventKit must not be reached at all")
        #expect(text(payload).contains("not available to network clients"))
    }

    @Test("a scheduled run reads but does not write")
    func scheduledRunWritesNothing() async {
        // The deliberate half of the gate. A scheduled task DOES get personal
        // data — that decision is recorded on `mayReachPersonalData` — and it
        // still may not change anything, because at 7am nobody is watching and
        // the context is full of calendar titles that strangers wrote.
        let spy = WriteSpy()
        let payload = await create(origin: .scheduledTask(id: UUID()), spy: spy)
        #expect(!spy.touched)
        #expect(text(payload).contains("cannot change anything"))
        // And the sentence tells it what it CAN do, so the run still produces
        // something useful rather than an apology.
        #expect(text(payload).contains("Say what needs doing"))
    }

    @Test("the chat tab writes")
    func chatWrites() async {
        let spy = WriteSpy()
        let payload = await create(spy: spy)
        #expect(spy.reminders.count == 1)
        #expect(spy.reminders.first?.title == "Take the bins out")
        #expect(payload["created"] as? Bool == true)
    }

    @Test("the two gates are separate questions")
    func readAndWriteAreDifferent() {
        // If these ever collapse into one property, a scheduled task silently
        // gains the ability to write.
        let scheduled = RequestOrigin.scheduledTask(id: UUID())
        #expect(scheduled.mayReachPersonalData)
        #expect(!scheduled.mayWritePersonalData)
        #expect(RequestOrigin.onDeviceChat.mayWritePersonalData)
        #expect(!RequestOrigin.network(host: "h", port: 1).mayWritePersonalData)
    }

    // MARK: - Times that must not be invented

    @Test("a repeating phrase files one repeating reminder, not one reminder")
    func recurrenceIsFiled() async {
        // "at 9" goes through the bare-clock parser, which uses the calendar it
        // is handed, so the hour here is deterministic — unlike anything that
        // reaches NSDataDetector, which resolves in the system zone.
        let spy = WriteSpy()
        let payload = await create(when: "every day at 9", spy: spy)
        let filed = spy.reminders.first
        #expect(filed?.repeats == .daily)
        #expect(calendar.component(.hour, from: filed?.due ?? now) == 9)
        // The pattern is read back for the same reason the time is: "every
        // weekday" and "every week" are one misparse apart and only the user
        // can tell which they meant.
        #expect(text(payload).contains("repeating every day"), "\(text(payload))")
    }

    @Test("every weekday is its own pattern, not a weekly one")
    func weekdayPattern() async {
        let spy = WriteSpy()
        _ = await create(when: "every weekday at 8am", spy: spy)
        #expect(spy.reminders.first?.repeats == .weekdays)
    }

    @Test("a repeating phrase with no time is still refused")
    func unreadableRecurrenceRefused() async {
        // The half of the old blanket refusal worth keeping. "every day" with
        // no hour is half a reminder, and filing it at whatever o'clock is the
        // failure the user discovers on the second morning.
        let spy = WriteSpy()
        let payload = await create(when: "every day", spy: spy)
        #expect(!spy.touched)
        #expect(text(payload).contains("how often and at what time"))
    }

    @Test("a daily reminder and a one-off at the same hour are different reminders")
    func recurrenceIsPartOfIdentity() async {
        // Filing the one-off over the daily — or declining to file the daily
        // because a one-off already matched — silently drops the repetition
        // that was the whole request.
        let nine = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 0))!
        let oneOff = ReminderRow(title: "Take the bins out", due: nine, dueHasTime: true, identifier: "x")
        let spy = WriteSpy()
        _ = await create(when: "every day at 9", open: [oneOff], spy: spy)
        #expect(spy.reminders.first?.repeats == .daily, "the daily one should still be filed")

        // And the same daily reminder asked for twice is still filed once.
        let daily = ReminderRow(title: "Take the bins out", due: nine, dueHasTime: true, identifier: "y", repeats: .daily)
        let again = WriteSpy()
        _ = await create(when: "every day at 9", open: [daily], spy: again)
        #expect(!again.touched)
    }

    @Test("an unreadable time writes nothing and asks")
    func unresolvedIsRefused() async {
        // Never a guessed hour. A reminder at a time nobody asked for is worse
        // than no reminder, because the user stops holding it in their head.
        let spy = WriteSpy()
        let payload = await create(when: "sometime soonish", spy: spy)
        #expect(!spy.touched)
        #expect(text(payload).contains("could not work out"))
        // The reply names an example, so the retry has somewhere to go.
        #expect(text(payload).contains("2am today"))
    }

    @Test("no time at all is a reminder with no due date, not a refusal")
    func noDueDateIsFine() async {
        // Ordinary and common — most people's lists are mostly undated.
        let spy = WriteSpy()
        let payload = await create(when: nil, spy: spy)
        #expect(spy.reminders.first?.due == nil)
        #expect(text(payload).contains("no due date"))
    }

    @Test("the confirmation states the time that was actually set")
    func confirmationEchoesTheResolvedTime() async {
        // The cheapest defence against a misparse. No phrase parser is right
        // every time, so the answer says what it set and the user catches it in
        // the same breath rather than the next morning.
        let spy = WriteSpy()
        let payload = await create(when: "in 30 minutes", spy: spy)
        let sentence = text(payload)
        #expect(sentence.contains("Take the bins out"))
        // 01:45 plus thirty minutes.
        #expect(sentence.contains("2:15") || sentence.contains("02:15"), "\(sentence)")
    }

    // MARK: - Titles

    @Test("a title the user would not recognise is refused")
    func rubbishTitles() async {
        // A model that calls the tool with "null" has not understood the
        // request, and a reminder called "null" is a worse outcome than asking.
        for title in [nil, "", "  ", ".", "null", "N/A", "undefined", "string"] {
            let spy = WriteSpy()
            let payload = await create(title: title, spy: spy)
            #expect(!spy.touched, "wrote for title: \(title ?? "nil")")
            #expect(text(payload).contains("what the reminder should say"))
        }
    }

    // MARK: - The same thing twice

    @Test("the same reminder asked for twice is filed once")
    func duplicatesAreNotFiled() async {
        // The failure this is for: a model calls the tool, does not recognise
        // the result, and calls it again — and the user finds the same thing
        // twice in their list.
        let due = calendar.date(byAdding: .minute, value: 30, to: now)!
        let existing = ReminderRow(title: "Take the bins out", due: due, dueHasTime: true, identifier: "x")
        let spy = WriteSpy()
        let payload = await create(open: [existing], spy: spy)
        #expect(!spy.touched)
        #expect(payload["already_existed"] as? Bool == true)
        // Reported as done, because from where the user is standing it is.
        #expect(text(payload).contains("already on the list"))
    }

    @Test("matching is loose about punctuation and case, strict about the minute")
    func duplicateMatching() async {
        let due = calendar.date(byAdding: .minute, value: 30, to: now)!
        let existing = ReminderRow(title: "take the BINS out!", due: due, dueHasTime: true, identifier: "x")

        // Same thing, typed differently.
        let same = WriteSpy()
        _ = await create(open: [existing], spy: same)
        #expect(!same.touched)

        // Same words, an hour later, is a different reminder and gets filed.
        let different = WriteSpy()
        _ = await create(when: "in 90 minutes", open: [existing], spy: different)
        #expect(different.reminders.count == 1)
    }

    @Test("an undated reminder does not collide with a dated one")
    func undatedIsItsOwnThing() async {
        let due = calendar.date(byAdding: .minute, value: 30, to: now)!
        let dated = ReminderRow(title: "Take the bins out", due: due, dueHasTime: true, identifier: "x")
        let spy = WriteSpy()
        _ = await create(when: nil, open: [dated], spy: spy)
        #expect(spy.reminders.count == 1, "no due date is not the same reminder as one at 2:15")
    }

    // MARK: - Ticking off

    private func complete(
        _ title: String?,
        open rows: [ReminderRow],
        origin: RequestOrigin = .onDeviceChat,
        spy: WriteSpy
    ) async -> [String: any Sendable] {
        await PersonalDataWrites.completeReminder(
            title: title,
            origin: origin,
            existing: { .rows(rows, truncated: false) },
            complete: { spy.complete($0) }
        )
    }

    @Test("ticking off addresses exactly one reminder")
    func completesOne() async {
        let rows = [
            ReminderRow(title: "Take the bins out", identifier: "a"),
            ReminderRow(title: "Book the dentist", identifier: "b")
        ]
        let spy = WriteSpy()
        let payload = await complete("book the dentist", open: rows, spy: spy)
        #expect(spy.completed.map(\.identifier) == ["b"])
        #expect(payload["completed"] as? Bool == true)
    }

    @Test("an ambiguous match asks rather than picking one")
    func ambiguityIsNotGuessed() async {
        // Picking one of two identical-looking reminders is the kind of wrong
        // that is only discovered later, when the user needed the other one.
        let rows = [
            ReminderRow(title: "Call mum", identifier: "a"),
            ReminderRow(title: "call Mum", identifier: "b")
        ]
        let spy = WriteSpy()
        let payload = await complete("call mum", open: rows, spy: spy)
        #expect(!spy.touched)
        #expect(text(payload).contains("Which one?"))
    }

    @Test("nothing matching is said plainly, not silently succeeded")
    func noMatch() async {
        let spy = WriteSpy()
        let payload = await complete("feed the cat", open: [ReminderRow(title: "Call mum", identifier: "a")], spy: spy)
        #expect(!spy.touched)
        #expect(text(payload).contains("could not find"))
    }

    @Test("a network caller cannot tick anything off either")
    func completeIsGatedToo() async {
        let spy = WriteSpy()
        let payload = await complete(
            "call mum",
            open: [ReminderRow(title: "Call mum", identifier: "a")],
            origin: .network(host: "h", port: 1),
            spy: spy
        )
        #expect(!spy.touched)
        #expect(text(payload).contains("not available to network clients"))
    }

    // MARK: - Events

    private func event(
        title: String? = "Lunch with Sam",
        start: String? = "tomorrow at 1pm",
        minutes: Int? = nil,
        origin: RequestOrigin = .onDeviceChat,
        spy: WriteSpy
    ) async -> [String: any Sendable] {
        await PersonalDataWrites.createEvent(
            title: title,
            start: start,
            durationMinutes: minutes,
            now: now,
            calendar: calendar,
            origin: origin,
            write: { spy.write($0) }
        )
    }

    @Test("an event needs a time, and says so rather than inventing one")
    func eventsNeedATime() async {
        let spy = WriteSpy()
        let payload = await event(start: nil, spy: spy)
        #expect(!spy.touched)
        #expect(text(payload).contains("when"))
    }

    @Test("an event with no duration lasts an hour, and one with a silly duration is clamped")
    func durations() async {
        #expect(PersonalDataWrites.resolvedMinutes(nil) == 60)
        #expect(PersonalDataWrites.resolvedMinutes(0) == 60)
        #expect(PersonalDataWrites.resolvedMinutes(-5) == 60)
        #expect(PersonalDataWrites.resolvedMinutes(90) == 90)
        // A model emitting a duration with an extra digit must not book out a
        // year of somebody's calendar.
        #expect(PersonalDataWrites.resolvedMinutes(9_999_999) == PersonalDataWrites.maximumEventMinutes)
    }

    @Test("a network caller cannot add an event")
    func eventsAreGated() async {
        let spy = WriteSpy()
        _ = await event(origin: .network(host: "h", port: 1), spy: spy)
        #expect(!spy.touched)
    }

    @Test("a repeating event becomes a series rather than being refused")
    func recurringEvents() async {
        // Reminders repeating while calendar events refused would be an odd
        // seam to leave in, and the parsing is already shared.
        let spy = WriteSpy()
        let payload = await event(start: "every Tuesday at 6pm", spy: spy)
        #expect(spy.events.first?.repeats == .weekly)
        #expect(text(payload).contains("repeating every week"), "\(text(payload))")
    }

    @Test("a repeating event with no readable time is refused")
    func unreadableRecurringEvent() async {
        let spy = WriteSpy()
        let payload = await event(start: "every so often", spy: spy)
        #expect(!spy.touched)
        #expect(text(payload).contains("how often and at what time"))
    }
}

/// A write produces a payload too, and the payload has to draw a card.
///
/// The failure this guards is the one `AnswerCardTests.everyToolRenders` was
/// written for, one level down: the card catalogue is keyed by TOOL name, so
/// merging the read and write halves into one tool means the existing entry
/// keeps matching and nothing fails — while every confirmation the assistant
/// gives is unrendered prose about a payload the card layer never saw.
@Suite("Write answers draw cards")
struct WriteAnswerCardTests {

    private func card(_ tool: String, _ arguments: String, _ data: [String: any Sendable]) -> AnswerCard? {
        AnswerCardCatalogue.standard.card(for: tool, arguments: arguments, data: data)
    }

    @Test("a reminder confirmation renders")
    func reminderCreated() throws {
        let drawn = try #require(card(
            PersonalDataToolNames.reminders,
            #"{"action":"create","title":"Take the bins out","when":"2am today"}"#,
            ["text": "Reminder set: \"Take the bins out\" for Sun 14 Sep, 02:00.", "created": true]
        ))
        // The time the tool actually set has to reach the screen, because
        // reading it back is how a misparse gets caught.
        #expect(drawn.transcript.contains("02:00"))
        #expect(drawn.source == PersonalDataToolNames.reminders)
    }

    @Test("a confirmation is not mistaken for an empty result")
    func createIsNotNothingFound() throws {
        // `isNothingFound` greys the card and reads as "there was nothing".
        // A reminder that was just filed is the opposite of nothing.
        let drawn = try #require(card(
            PersonalDataToolNames.reminders,
            #"{"action":"create"}"#,
            ["text": "Reminder added: \"Call mum\", with no due date.", "created": true]
        ))
        guard case let .empty(body)? = drawn.sections.first else { return }
        Issue.record("a successful write drew an empty-state card: \(body)")
    }

    @Test("a refusal renders rather than vanishing")
    func refusalRenders() throws {
        // The sentence a network caller gets. If this drew nothing, the user
        // would see the model paraphrasing a refusal with no card to anchor it.
        let drawn = try #require(card(
            PersonalDataToolNames.reminders,
            #"{"action":"create","title":"x"}"#,
            ["text": ToolContext.writeRefusal(for: .network(host: "h", port: 1))]
        ))
        #expect(drawn.transcript.contains("network clients"))
    }

    @Test("a calendar confirmation renders under the calendar tool")
    func eventCreated() throws {
        let drawn = try #require(card(
            PersonalDataToolNames.calendar,
            #"{"action":"create","title":"Lunch with Sam","start":"tomorrow at 1pm"}"#,
            ["text": "Added \"Lunch with Sam\" to your calendar for Mon 15 Sep, 13:00.", "created": true]
        ))
        #expect(drawn.source == PersonalDataToolNames.calendar)
        #expect(drawn.transcript.contains("Lunch with Sam"))
    }

    @Test("a list call still renders rows, so the merge did not cost the read")
    func listStillWorks() throws {
        let drawn = try #require(card(
            PersonalDataToolNames.reminders,
            #"{"action":"list","filter":"today"}"#,
            ["reminders": [["title": "Call mum", "due": "Sun 14 Sep, 09:00"] as [String: any Sendable]]]
        ))
        #expect(drawn.transcript.contains("Call mum"))
    }
}
