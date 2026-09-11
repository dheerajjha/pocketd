import Foundation
import Testing
@testable import PocketdKit

/// Fixed so that nothing here depends on the day the suite is run.
private let noon = Date(timeIntervalSince1970: 1_788_955_200)

private func encoded(_ card: AnswerCard) throws -> Data {
    try JSONEncoder().encode(card)
}

private func decoded(_ data: Data) throws -> AnswerCard {
    try JSONDecoder().decode(AnswerCard.self, from: data)
}

@Suite("Answer cards: the value")
struct AnswerCardValueTests {

    /// Every section kind in one card, because the failure this guards against
    /// is a section that encodes and cannot be read back — and a conversation
    /// that cannot be read back is one `ConversationStore.all()` silently drops
    /// from the history list.
    @Test("a card carrying every section kind survives JSON")
    func roundTrip() throws {
        let card = AnswerCard(
            source: "get_calendar_events",
            symbol: "calendar",
            title: "Today",
            lede: "Three things, and the first one is soon.",
            sections: [
                .facts(AnswerCard.Facts(eyebrow: "Where to find it", rows: [
                    AnswerCard.Fact(label: "Address", value: "Sector 3, Vashi", accent: "Vashi"),
                    AnswerCard.Fact(label: "Closed", value: "Monday")
                ])),
                .list(AnswerCard.Items(eyebrow: "3 events", items: [
                    AnswerCard.Item(text: "Standup", detail: "09:30 – 09:45", accent: "Soon", symbol: "circle.fill"),
                    AnswerCard.Item(text: "Lunch")
                ])),
                .metrics(AnswerCard.Metrics(eyebrow: "This week", tiles: [
                    AnswerCard.Tile(value: "12", caption: "Meetings"),
                    AnswerCard.Tile(value: "4h", caption: "Conversational")
                ])),
                .steps(AnswerCard.Steps(eyebrow: "How", steps: [
                    AnswerCard.Step(title: "Open Settings", detail: "Privacy & Security"),
                    AnswerCard.Step(title: "Turn it on")
                ])),
                .note(AnswerCard.Note(text: "There are more.", symbol: "ellipsis", tone: .caution)),
                .empty(AnswerCard.Empty(text: "No events today.", symbol: "calendar"))
            ]
        )

        #expect(try decoded(encoded(card)) == card)
    }

    @Test("an empty state is a card, not an absence")
    func emptyState() throws {
        let card = AnswerCard.nothing(
            CalendarRange.today.emptyText,
            title: "Today",
            symbol: "calendar",
            source: "get_calendar_events"
        )

        // The point of the type: there is something to draw, and what it says
        // is the tool's own sentence rather than anything a model produced.
        #expect(!card.isEmpty)
        // The symbol goes to the header and stops there. See
        // `emptyStateDoesNotRepeatTheHeaderGlyph`.
        #expect(card.symbol == "calendar")
        #expect(card.sections == [.empty(AnswerCard.Empty(text: "No events today."))])
        #expect(card.transcript.contains("No events today."))
        #expect(try decoded(encoded(card)) == card)
    }

    @Test("a card with nothing in it is not a card")
    func vacantIsRejected() {
        // The catalogue drops these rather than putting an empty rounded
        // rectangle under an answer. An empty *state* is a sentence; an empty
        // *card* is a bug in a builder.
        #expect(AnswerCard().isEmpty)
        #expect(AnswerCard(title: "Today").isEmpty)
        #expect(!AnswerCard(lede: "Nothing to report.").isEmpty)
    }

    /// A rollback is the ordinary way this happens: a card written by a build
    /// that has health sections, opened by one that does not.
    @Test("a section this build has never heard of costs the section, not the conversation")
    func unknownSectionIsDropped() throws {
        let json = Data("""
        {"title":"Today","sections":[\
        {"kind":"heartRate","body":{"bpm":62}},\
        {"kind":"note","body":{"text":"Still here.","tone":"info"}}\
        ]}
        """.utf8)

        let card = try decoded(json)
        #expect(card.title == "Today")
        #expect(card.sections == [.note(AnswerCard.Note(text: "Still here.", tone: .info))])
    }

    /// The other half of that rescue, and the half that has to stay narrow.
    ///
    /// A body this build cannot read under a kind it *does* know is not a newer
    /// build's section. It is a corrupted file, or a body type that grew a
    /// field decoded as required — and dropping it would hand back a card with
    /// silently fewer sections than the file it came from, which reads exactly
    /// like a builder that never made them. Only one of these two failures is
    /// something we shipped on purpose, and only that one is forgiven.
    @Test("a known section with a body this build cannot read is not swallowed")
    func malformedKnownSectionIsNotSwallowed() throws {
        // `Note.text` is required, and this note has none.
        #expect(throws: DecodingError.self) {
            try decoded(Data(#"{"sections":[{"kind":"note","body":{}}]}"#.utf8))
        }
        // Nor is a section with no kind at all: nothing this app writes omits it.
        #expect(throws: DecodingError.self) {
            try decoded(Data(#"{"sections":[{"body":{"text":"Still here."}}]}"#.utf8))
        }
        // And the rescue that *is* intended still stands beside them, so this
        // is a narrowing rather than a removal.
        let unknownKind = Data(#"{"sections":[{"kind":"heartRate","body":{"bpm":62}}]}"#.utf8)
        #expect(try decoded(unknownKind).sections.isEmpty)
    }

    @Test("a tone this build has never heard of keeps its note")
    func unknownToneFallsBack() throws {
        let json = Data(#"{"sections":[{"kind":"note","body":{"text":"Careful.","tone":"nuclear"}}]}"#.utf8)
        #expect(try decoded(json).sections == [.note(AnswerCard.Note(text: "Careful.", tone: .info))])
    }

    @Test("the transcript carries the numbers, which is the part the prose does not")
    func transcript() {
        let card = AnswerCard(title: "Today", sections: [
            .list(AnswerCard.Items(eyebrow: "2 events", items: [
                AnswerCard.Item(text: "Standup", detail: "09:30", accent: "Soon"),
                AnswerCard.Item(text: "Retro", detail: "16:00")
            ])),
            .metrics(AnswerCard.Metrics(tiles: [AnswerCard.Tile(value: "2", caption: "Meetings")]))
        ])

        let text = card.transcript
        #expect(text.contains("2 events"))
        #expect(text.contains("Standup — 09:30 — Soon"))
        #expect(text.contains("Retro — 16:00"))
        #expect(text.contains("2 Meetings"))
    }
}

@Suite("Answer cards: the seam")
struct AnswerCardSeamTests {

    /// The regression that matters most in this whole change. Every tool that
    /// existed before cards did must produce the byte-identical prompt it
    /// produced before, because that string is what the model reads and the
    /// reason `ToolResult.encode` sorts its keys at all is that an answer
    /// nobody can reproduce is an answer nobody can bisect.
    @Test("a tool that does not opt in produces exactly the prompt text it did before")
    func nonParticipatingToolIsUntouched() {
        let output: [String: any Sendable] = [
            "zulu": 1, "alpha": "a", "mike": true, "kilo": 2.5, "bravo": ["x", "y"]
        ]

        let rendered = ToolResult.render(output, from: "pocketd_selftest", arguments: "{}")

        #expect(rendered.prompt == ToolResult.encode(output))
        #expect(rendered.prompt == #"{"alpha":"a","bravo":["x","y"],"kilo":2.5,"mike":true,"zulu":1}"#)
        #expect(rendered.card == nil)
    }

    @Test("opting in does not move a single byte of the prompt either")
    func participatingToolPromptIsUntouched() async {
        let payload = await PersonalDataTools.calendarPayload(
            range: .today,
            now: noon,
            origin: .onDeviceChat,
            read: { _ in .rows([CalendarEventRow(title: "Standup", start: noon, end: noon)], truncated: false) }
        )

        let rendered = ToolResult.render(
            payload,
            from: PersonalDataToolNames.calendar,
            arguments: #"{"range":"today"}"#
        )

        // A card was built, and the string the model reads is the same one it
        // would have read with no card in the world.
        #expect(rendered.card != nil)
        #expect(rendered.prompt == ToolResult.encode(payload))
    }

    @Test("an unknown tool name renders nothing rather than guessing")
    func unknownToolHasNoCard() {
        #expect(AnswerCardCatalogue.standard.card(for: "get_weather", arguments: "{}", data: ["temp": 21]) == nil)
    }

    @Test("a catalogue is composable, so a new tool is a builder and nothing else")
    func registering() {
        let catalogue = AnswerCardCatalogue.standard.registering("get_timer") { _, data in
            AnswerCard(title: "Timer", lede: data["remaining"] as? String)
        }

        #expect(catalogue.toolNames == ["get_calendar_events", "get_health_summary", "get_reminders", "get_timer"])
        #expect(catalogue.card(for: "get_timer", arguments: "{}", data: ["remaining": "4 minutes"])?.lede == "4 minutes")
        // The two that were there are still there.
        #expect(catalogue.card(
            for: PersonalDataToolNames.reminders,
            arguments: #"{"filter":"all_open"}"#,
            data: ["text": "No open reminders."]
        ) != nil)
    }

    @Test("a builder that finds nothing to draw yields no card at all")
    func vacantBuilderYieldsNil() {
        let catalogue = AnswerCardCatalogue(["quiet": { _, _ in AnswerCard(title: "Nothing here") }])
        #expect(catalogue.card(for: "quiet", arguments: "{}", data: [:]) == nil)
    }
}

@Suite("Answer cards: from the two real tools")
struct AnswerCardBuilderTests {

    private func calendarCard(
        range: CalendarRange = .today,
        rows: [CalendarEventRow],
        truncated: Bool = false
    ) async -> AnswerCard? {
        let payload = await PersonalDataTools.calendarPayload(
            range: range,
            now: noon,
            origin: .onDeviceChat,
            read: { _ in .rows(rows, truncated: truncated) }
        )
        return AnswerCardCatalogue.standard.card(
            for: PersonalDataToolNames.calendar,
            arguments: #"{"range":"\#(range.rawValue)"}"#,
            data: payload
        )
    }

    @Test("a real calendar payload becomes a list of what is actually there")
    func calendarEvents() async throws {
        let card = try #require(await calendarCard(rows: [
            CalendarEventRow(
                title: "Design review",
                start: noon,
                end: noon.addingTimeInterval(3_600),
                location: "Room 4"
            ),
            CalendarEventRow(title: "Offsite", start: noon, end: noon, isAllDay: true)
        ]))

        #expect(card.source == PersonalDataToolNames.calendar)
        #expect(card.title == "Today")
        // The model writes the sentence and it lives in the assistant turn
        // above; a card that also carried one would print it twice.
        #expect(card.lede == nil)

        guard case .list(let list) = card.sections.first else {
            Issue.record("expected a list section, got \(card.sections)")
            return
        }
        // The count is derived from the rows, not read out of anything the
        // model produced. It is the number a 1–4B model gets wrong first.
        #expect(list.eyebrow == "2 events")
        #expect(list.items.count == 2)
        #expect(list.items[0].text == "Design review")
        #expect(list.items[0].detail?.contains("Room 4") == true)
        #expect(list.items[0].accent == nil)
        #expect(list.items[1].accent == "All day")
    }

    @Test("the truncation the tool reports is the truncation the card admits to")
    func calendarTruncation() async throws {
        let rows = (0..<PersonalDataTools.rowLimit).map {
            CalendarEventRow(title: "Event \($0)", start: noon, end: noon)
        }
        let card = try #require(await calendarCard(rows: rows, truncated: true))

        let notes = card.sections.compactMap { section -> AnswerCard.Note? in
            if case .note(let note) = section { return note }
            return nil
        }
        #expect(notes.count == 1)
        #expect(notes[0].text.contains("there are more"))
        #expect(card.transcript.contains("there are more"))
    }

    @Test("a free day is an empty state, not a missing card")
    func calendarEmpty() async throws {
        let card = try #require(await calendarCard(range: .next_week, rows: []))

        #expect(card.title == "Next week")
        #expect(card.sections == [.empty(AnswerCard.Empty(text: "No events next week."))])
    }

    /// The one thing about a card that only goes wrong on screen, pinned at the
    /// value so that it can be pinned at all. `AnswerCardView` draws
    /// `card.symbol` as the header chip and `Empty.symbol` as the glyph beside
    /// the sentence, so a builder that puts one symbol in both places draws a
    /// calendar, and then another calendar an inch below it. A SwiftUI preview
    /// does not fail when that happens; this does.
    @Test("an empty state never repeats the glyph the header already drew")
    func emptyStateDoesNotRepeatTheHeaderGlyph() async throws {
        let card = try #require(await calendarCard(range: .next_week, rows: []))
        guard case .empty(let state) = card.sections.first else {
            Issue.record("expected an empty section, got \(card.sections)")
            return
        }

        #expect(card.symbol == "calendar")
        #expect(state.symbol != card.symbol)
        // nil rather than some other glyph: the view owns the mark for
        // nothing-found, and a builder guessing at one is how the two drift.
        #expect(state.symbol == nil)
    }

    /// Why `render` and `card(for:)` have no default for `arguments`.
    ///
    /// The rows carry no trace of what was asked: the same standup answers
    /// "what is on today" and "what is on next week". The arguments are the
    /// only thing that can say, so a caller that drops them heads every card in
    /// the app with the generic noun — silently, and with nothing failing.
    @Test("the heading comes from what was asked, not from what came back")
    func headingFollowsTheArguments() async throws {
        let payload = await PersonalDataTools.calendarPayload(
            range: .today,
            now: noon,
            origin: .onDeviceChat,
            read: { _ in .rows([CalendarEventRow(title: "Standup", start: noon, end: noon)], truncated: false) }
        )
        func title(_ arguments: String) -> String? {
            AnswerCardCatalogue.standard.card(
                for: PersonalDataToolNames.calendar,
                arguments: arguments,
                data: payload
            )?.title
        }

        #expect(title(#"{"range":"today"}"#) == "Today")
        #expect(title(#"{"range":"next_week"}"#) == "Next week")
        // One payload, three headings — and the third is the one a missing
        // argument buys, which is why passing it is not optional.
        #expect(title("") == "Calendar")
    }

    /// The distinction the whole `sentence` split exists for. Both arrive on
    /// the same `text` key, and drawing "permission is off" as an empty state
    /// would tell the user their week is free when nobody has looked at it.
    @Test("a permission that is switched off does not read as a free day")
    func calendarPermissionIsNotEmptiness() async throws {
        let payload = await PersonalDataTools.calendarPayload(
            range: .today,
            now: noon,
            origin: .onDeviceChat,
            read: { _ in .unauthorized(.denied) }
        )
        let card = try #require(AnswerCardCatalogue.standard.card(
            for: PersonalDataToolNames.calendar,
            arguments: #"{"range":"today"}"#,
            data: payload
        ))

        #expect(card.symbol == "lock")
        #expect(card.lede == PersonalDataAuthorization.denied.explanation(for: .calendar))
        // Not `sections.isEmpty`. That is a stronger claim than this test is
        // making and it subsumes the one it is: a later builder that draws the
        // steps to turn the switch back on would fail it while the thing worth
        // guarding still held. The invariant is narrower and survives that
        // card — whatever a denied permission grows, none of it may be the
        // empty state, because the empty state is the one section that reads as
        // "we looked, and your week is free".
        #expect(!card.sections.contains { if case .empty = $0 { return true }; return false })
    }

    @Test("a network caller's refusal never becomes a card the phone would draw")
    func networkRefusalIsNotAFreeDay() async throws {
        let payload = await PersonalDataTools.calendarPayload(
            range: .today,
            now: noon,
            origin: .network(host: "192.168.1.42", port: 55_000),
            read: { _ in .rows([], truncated: false) }
        )
        let card = try #require(AnswerCardCatalogue.standard.card(
            for: PersonalDataToolNames.calendar,
            arguments: #"{"range":"today"}"#,
            data: payload
        ))

        #expect(card.lede == ToolContext.refusal)
        #expect(card.sections.isEmpty)
    }

    @Test("reminders carry their priorities and the sentence that explains the scale")
    func reminders() async throws {
        let payload = await PersonalDataTools.reminderPayload(
            filter: .overdue,
            now: noon,
            origin: .onDeviceChat,
            read: { _ in
                .rows([
                    ReminderRow(title: "Renew passport", due: noon, dueHasTime: false, priority: 1),
                    ReminderRow(title: "Water the plants")
                ], truncated: false)
            }
        )
        let card = try #require(AnswerCardCatalogue.standard.card(
            for: PersonalDataToolNames.reminders,
            arguments: #"{"filter":"overdue"}"#,
            data: payload
        ))

        #expect(card.title == "Overdue")
        guard case .list(let list) = card.sections.first else {
            Issue.record("expected a list section, got \(card.sections)")
            return
        }
        #expect(list.eyebrow == "2 reminders")
        #expect(list.items[0].accent == "P1")
        // No priority set is not a priority of zero, and the card must not
        // invent one where EventKit reported none.
        #expect(list.items[1].accent == nil)
        #expect(list.items[1].detail == "no due date")

        let notes = card.sections.compactMap { section -> AnswerCard.Note? in
            if case .note(let note) = section { return note }
            return nil
        }
        #expect(notes.contains { $0.text.contains("1 is highest") })
    }

    @Test("one of a thing is not one things")
    func singular() {
        #expect(AnswerCardBuilders.count(1, of: "event") == "1 event")
        #expect(AnswerCardBuilders.count(0, of: "event") == "0 events")
        #expect(AnswerCardBuilders.count(2, of: "reminder") == "2 reminders")
    }

    /// Both ends are already display strings by the time a builder sees them,
    /// so the shared head is trimmed by scanning rather than by knowing what a
    /// date looks like — which is the only version that survives a locale where
    /// the day comes last.
    @Test("a time span drops the half the reader has already read")
    func span() {
        #expect(AnswerCardBuilders.span(start: "Thu 11 Sep, 14:30", end: "Thu 11 Sep, 15:30") == "Thu 11 Sep, 14:30 – 15:30")
        #expect(AnswerCardBuilders.span(start: "Thu 11 Sep", end: "Fri 12 Sep") == "Thu 11 Sep – Fri 12 Sep")
        #expect(AnswerCardBuilders.span(start: "Thu 11 Sep", end: "Thu 11 Sep") == "Thu 11 Sep")
        #expect(AnswerCardBuilders.span(start: "2025年9月11日 14:30", end: "2025年9月11日 15:30") == "2025年9月11日 14:30 – 15:30")
        #expect(AnswerCardBuilders.span(start: nil, end: "Fri 12 Sep") == "Fri 12 Sep")
        #expect(AnswerCardBuilders.span(start: "Thu 11 Sep", end: nil) == "Thu 11 Sep")
    }

    @Test("arguments the model mangled cost the heading and nothing else")
    func unreadableArgumentsStillRender() async throws {
        let payload = await PersonalDataTools.calendarPayload(
            range: .today,
            now: noon,
            origin: .onDeviceChat,
            read: { _ in .rows([CalendarEventRow(title: "Standup", start: noon, end: noon)], truncated: false) }
        )
        let card = try #require(AnswerCardCatalogue.standard.card(
            for: PersonalDataToolNames.calendar,
            arguments: "not json at all",
            data: payload
        ))

        #expect(card.title == "Calendar")
        #expect(!card.sections.isEmpty)
    }
}

@Suite("Answer cards: on a message")
struct AnswerCardMessageTests {

    @Test("a conversation written before cards existed still opens")
    func oldMessagesStillDecode() throws {
        // The synthesised decoder throws on a key that is not there, and
        // `ConversationStore.all()` skips a file it cannot decode — so getting
        // this wrong would have emptied every history list in the field.
        let json = Data(#"{"role":"assistant","content":"hi","images":[]}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: json)

        #expect(message.content == "hi")
        #expect(message.cards.isEmpty)
    }

    @Test("a message with no cards writes no cards key")
    func emptyCardsAreNotWritten() throws {
        let data = try JSONEncoder().encode(ChatMessage.assistant("hi"))
        #expect(!String(decoding: data, as: UTF8.self).contains("cards"))
    }

    @Test("cards survive the round trip through the store")
    func persisted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory)

        let card = AnswerCard(
            source: PersonalDataToolNames.calendar,
            symbol: "calendar",
            title: "Today",
            sections: [.list(AnswerCard.Items(eyebrow: "1 event", items: [
                AnswerCard.Item(text: "Standup", detail: "09:30")
            ]))]
        )
        var reply = ChatMessage.assistant("You have one thing on.")
        reply.cards = [card]

        try await store.save(Conversation(messages: [.user("what's on today"), reply]))

        let loaded = try #require(await store.all().first)
        #expect(loaded.messages.last?.cards == [card])
    }

    /// Cards are drawn from a payload the prompt was already charged for once.
    /// Counting them again would shrink a 4032-token window for a rendering the
    /// model cannot see.
    @Test("a card costs the prompt budget nothing")
    func cardsAreNotChargedToTheContext() {
        let plain = ChatMessage.assistant("Three things today.")
        var carrying = plain
        carrying.cards = [AnswerCard(title: "Today", sections: [
            .list(AnswerCard.Items(items: (0..<20).map { AnswerCard.Item(text: "Event \($0)") }))
        ])]

        #expect(ContextGuard.estimateTokens([carrying]) == ContextGuard.estimateTokens([plain]))
    }
}

/// Wraps `EchoEngine` and floods the stream with cards.
///
/// One before anything, and another after every single token — far more than a
/// real tool round could produce. If a card can reach an HTTP response at all,
/// this is the engine that puts it there.
private struct CardFloodEngine: InferenceEngine {
    let inner = EchoEngine()
    let card = AnswerCard(title: "Today", sections: [
        .list(AnswerCard.Items(eyebrow: "1 event", items: [AnswerCard.Item(text: "Standup")]))
    ])

    var backendName: String { inner.backendName }

    func loadedModel() async -> ModelRecord? { await inner.loadedModel() }
    func load(model: ModelRecord) async throws { try await inner.load(model: model) }
    func unload() async { await inner.unload() }

    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        let upstream = try await inner.generate(request)
        let card = self.card
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.answerCard(card))
                    for try await event in upstream {
                        continuation.yield(event)
                        if case .token = event { continuation.yield(.answerCard(card)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Rewrites each response line into a canonical form, so that two runs of the
/// same request compare exactly.
///
/// Two things vary between runs and neither is a difference a client could
/// observe. The completion id and the clocks are new every time, and are
/// blanked. Key *order* is new every time too, which was a surprise: these
/// bodies are `Encodable` structs, but Foundation's `JSONEncoder` builds them
/// through a dictionary and emits whatever order the hash seed produced, so
/// even two chunks of one response disagree. Re-serialising with sorted keys
/// is what makes "not a single byte" a claim a test can actually make — and
/// the only difference this leaves is a difference in content.
private func canonical(_ lines: [String]) -> [String] {
    let volatile = ["id", "created", "created_at",
                    "total_duration", "load_duration", "prompt_eval_duration", "eval_duration"]
    return lines.map { line in
        let prefix = line.hasPrefix("data: ") ? "data: " : ""
        guard let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return line }
        for key in volatile where object[key] != nil { object[key] = "*" }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return line
        }
        return prefix + String(decoding: encoded, as: UTF8.self)
    }
}

@Suite("Answer cards: never on the wire", .serialized)
struct AnswerCardWireTests {

    @Test("an OpenAI stream is byte-identical whether or not cards were emitted")
    func openAIStreamIsUnchanged() async throws {
        func body(engine: any InferenceEngine) async throws -> [String] {
            let harness = try await TestServer.start(engine: engine)
            defer { Task { await harness.stop() } }
            let request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "what is on today")],
                stream: true
            ))
            return canonical(try await harness.lines(request))
        }

        let plain = try await body(engine: EchoEngine())
        let flooded = try await body(engine: CardFloodEngine())

        #expect(!plain.isEmpty)
        #expect(flooded == plain)
        #expect(flooded.allSatisfy { !$0.contains("Standup") })
    }

    @Test("an Ollama stream is byte-identical too")
    func ollamaStreamIsUnchanged() async throws {
        func body(engine: any InferenceEngine) async throws -> [String] {
            let harness = try await TestServer.start(engine: engine)
            defer { Task { await harness.stop() } }
            let request = try harness.request("POST", "/api/chat", json: Ollama.ChatRequest(
                model: "echo",
                messages: [Ollama.Message(role: "user", content: "what is on today")],
                stream: true
            ))
            return canonical(try await harness.lines(request).filter { !$0.isEmpty })
        }

        let plain = try await body(engine: EchoEngine())
        let flooded = try await body(engine: CardFloodEngine())

        #expect(!plain.isEmpty)
        #expect(flooded == plain)
        #expect(flooded.allSatisfy { !$0.contains("Standup") })
    }

    @Test("a buffered completion drops cards as well as tool announcements")
    func bufferedCompletionIgnoresCards() async throws {
        let engine = CardFloodEngine()
        let answer = try await engine.complete(GenerationRequest(
            modelID: "echo",
            messages: [.user("what is on today")]
        ))

        #expect(answer.text == "what is on today")
        #expect(answer.reason == .stop)
    }
}

// MARK: - The health tool

/// A Health store that returns whatever the test put in it.
///
/// Every payload below comes out of the real `HealthSummary.payload` rather than
/// a hand-written dictionary, and that is the point of the suite. The card reads
/// the figure back out of a clause `HealthSummary.reading` wrote; a fixture of
/// that clause would keep passing after the wording it depends on had moved.
private enum HealthFixture {
    static let utc = TimeZone(identifier: "UTC")!
    /// A real locale rather than `en_US_POSIX`, whose deliberate lack of a
    /// grouping separator would hide the thing a step-count tile is for.
    static let english = Locale(identifier: "en_US")

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.firstWeekday = 2
        return calendar
    }

    /// Thursday 11 September 2025, 10:00 UTC.
    static let now = calendar.date(from: DateComponents(year: 2025, month: 9, day: 11, hour: 10))!

    static func payload(
        _ focus: HealthFocus,
        origin: RequestOrigin = .onDeviceChat,
        readout: HealthReadout
    ) async -> [String: any Sendable] {
        await HealthSummary.payload(
            focus: focus, now: now, calendar: calendar, locale: english, timeZone: utc, origin: origin,
            read: { _, _ in readout }
        )
    }

    static func card(
        _ focus: HealthFocus,
        origin: RequestOrigin = .onDeviceChat,
        readout: HealthReadout
    ) async -> AnswerCard? {
        AnswerCardCatalogue.standard.card(
            for: PersonalDataToolNames.health,
            arguments: #"{"focus":"\#(focus.rawValue)"}"#,
            data: await payload(focus, origin: origin, readout: readout)
        )
    }

    /// `count` completed days, the last of them yesterday.
    static func days(_ count: Int, _ unit: HealthUnit, value: @escaping (Int) -> Double) -> [HealthSample] {
        let today = calendar.startOfDay(for: now)
        return (1...count).reversed().map { back in
            HealthSample(
                value: value(back),
                unit: unit,
                date: calendar.date(byAdding: .day, value: -back, to: today)!
            )
        }
    }
}

@Suite("Answer cards: the health tool")
struct AnswerCardHealthTests {

    /// The headline claim of the whole mechanism, applied to the largest thing
    /// the app reads.
    ///
    /// Before this the health tool drew nothing: `get_health_summary` was in no
    /// catalogue, so a payload of already-computed means and deltas reached the
    /// user only as a 1.7B model's paraphrase of it. The figures are what a
    /// reader looks for and what prose about a body buries, so they go in the
    /// strip; the clause that says what each one means against the user's own
    /// baseline goes under it.
    @Test("a health series draws its figures once, above the clauses that explain them")
    func healthSeriesDrawsAStripAndItsBaseline() async throws {
        let card = try #require(await HealthFixture.card(.activity, readout: HealthReadout(samples: [
            .steps: HealthFixture.days(30, .count) { $0 == 1 ? 11_200 : 7_100 },
            .active_energy: HealthFixture.days(30, .kilocalorie) { _ in 520 },
            .exercise_minutes: HealthFixture.days(30, .minute) { _ in 42 }
        ])))

        #expect(card.source == PersonalDataToolNames.health)
        #expect(card.title == "Activity")
        #expect(card.symbol == "figure.walk")
        // The model's sentence is the assistant turn directly above.
        #expect(card.lede == nil)

        guard case .metrics(let strip) = card.sections.first else {
            Issue.record("expected a metric strip, got \(card.sections)")
            return
        }
        #expect(strip.tiles == [
            AnswerCard.Tile(value: "11200", caption: "Steps"),
            AnswerCard.Tile(value: "520 kcal", caption: "Active energy"),
            AnswerCard.Tile(value: "42 min", caption: "Exercise")
        ])

        guard case .facts(let facts) = card.sections.dropFirst().first else {
            Issue.record("expected a facts section under the strip, got \(card.sections)")
            return
        }
        #expect(facts.rows.map(\.label) == ["Steps", "Active energy", "Exercise"])
        // The comparison, and not the figure a second time: 11200 is in the
        // tile above, and a card that prints its own headline number twice reads
        // as a rendering fault rather than as an answer.
        #expect(facts.rows[0].value?.hasPrefix("on Wed, Sep 10 — 58% above your 28-day average of 7100") == true)
        #expect(facts.rows[0].value?.contains("11200") == false)

        // Arithmetic the card never does: 58% is `HealthSummary`'s, computed
        // once, and drawn here exactly as the model was handed it.
        #expect(card.transcript.contains("58% above your 28-day average of 7100"))
    }

    /// Registering a card must not move a byte of what the model reads, and the
    /// health schema is the largest in the app — 232 guard tokens on a
    /// tool-native template — so it is the one worth saying it about.
    @Test("the health prompt is the same string it was before it had a card")
    func healthPromptIsUntouched() async {
        let payload = await HealthFixture.payload(.sleep, readout: HealthReadout(
            samples: [.respiratory_rate: HealthFixture.days(30, .breathsPerMinute) { _ in 14.2 }]
        ))
        let rendered = ToolResult.render(
            payload, from: PersonalDataToolNames.health, arguments: #"{"focus":"sleep"}"#
        )

        #expect(rendered.card != nil)
        #expect(rendered.prompt == ToolResult.encode(payload))
    }

    /// A strip of one tile is not a glance, and a strip of some of the metrics
    /// would put the rest of the figures nowhere — the fact rows only drop the
    /// figure because the tile above is holding it.
    @Test("a single reading keeps its figure instead of losing it to a strip of one")
    func healthSingleReadingHasNoStrip() async throws {
        let card = try #require(await HealthFixture.card(.activity, readout: HealthReadout(samples: [
            .steps: HealthFixture.days(30, .count) { _ in 7_100 }
        ])))

        #expect(!card.sections.contains { if case .metrics = $0 { return true }; return false })
        guard case .facts(let facts) = card.sections.first else {
            Issue.record("expected a facts section, got \(card.sections)")
            return
        }
        #expect(facts.rows.count == 1)
        #expect(facts.rows[0].label == "Steps")
        #expect(facts.rows[0].value?.hasPrefix("7100 on Wed, Sep 10") == true)
    }

    /// Constraint three, drawn.
    ///
    /// iOS reports a read the user refused and a read with nothing behind it
    /// identically, so `HealthSummary.ambiguity` names both possibilities in one
    /// sentence. A padlock over that sentence would pick one of them while the
    /// words underneath said it could not be picked — and the reason the card
    /// exists at all is that the model's compression of it is routinely "you
    /// haven't given me access to Health".
    @Test("nothing coming back is never drawn as a permission that was refused")
    func healthNothingCameBackIsNotALock() async throws {
        let card = try #require(await HealthFixture.card(.sleep, readout: HealthReadout()))

        #expect(card.symbol == "bed.double")
        #expect(card.symbol != "lock")
        #expect(card.lede == nil)
        #expect(card.sections == [.empty(AnswerCard.Empty(text: HealthSummary.ambiguity(for: .sleep)))])

        // Verbatim, and both halves of it: this is the sentence the model was
        // paraphrasing away.
        #expect(card.transcript.contains("nothing has been recorded"))
        #expect(card.transcript.contains("was not allowed to read it"))
        #expect(card.transcript.contains("iOS deliberately does not tell an app which"))
    }

    /// The one `text` payload that really is a refusal, and the only one that
    /// may be drawn as one — Pocketd refusing a network client is a decision
    /// this app made and can account for.
    @Test("a network caller's refusal is the one health sentence that locks")
    func healthNetworkRefusalIsALock() async throws {
        let card = try #require(await HealthFixture.card(
            .heart,
            origin: .network(host: "192.168.1.42", port: 55_000),
            readout: HealthReadout(samples: [.resting_heart_rate: HealthFixture.days(30, .beatsPerMinute) { _ in 58 }])
        ))

        #expect(card.lede == ToolContext.refusal)
        #expect(card.symbol == "lock")
        #expect(card.sections.isEmpty)
    }

    /// Health being absent from the device is a thing iOS does answer, and it is
    /// not a refusal. A padlock here sends someone whose iPad has no Health
    /// store to a settings screen where nothing is wrong.
    @Test("Health missing from the device is not drawn as a permission either")
    func healthUnavailableIsNotALock() async throws {
        let card = try #require(await HealthFixture.card(
            .activity, readout: HealthReadout(availability: .noHealthData)
        ))

        #expect(card.symbol == "figure.walk")
        #expect(card.lede?.contains("not available on this device") == true)
        #expect(card.sections.isEmpty)
    }

    /// A metric that produced nothing is the same ambiguity one level down, so
    /// the note that names both possibilities has to travel with it.
    @Test("a metric that came back empty carries both possibilities, in one box")
    func healthMissingMetricsKeepTheAmbiguity() async throws {
        let card = try #require(await HealthFixture.card(.activity, readout: HealthReadout(samples: [
            .steps: HealthFixture.days(30, .count) { _ in 7_100 }
        ])))

        let notes = card.sections.compactMap { section -> AnswerCard.Note? in
            if case .note(let note) = section { return note }
            return nil
        }
        #expect(notes.count == 1)
        #expect(notes[0].text.contains("Active energy, Exercise"))
        #expect(notes[0].text.contains(HealthSummary.ambiguityNote))
        #expect(notes[0].tone == .info)
    }

    @Test("the long-memory lines are listed as the claims they are")
    func healthNotableIsAList() async throws {
        let card = try #require(await HealthFixture.card(.activity, readout: HealthReadout(samples: [
            .steps: HealthFixture.days(30, .count) { _ in 11_200 },
            .active_energy: HealthFixture.days(30, .kilocalorie) { _ in 520 },
            .exercise_minutes: HealthFixture.days(30, .minute) { _ in 42 }
        ])))

        let lists = card.sections.compactMap { section -> AnswerCard.Items? in
            if case .list(let items) = section { return items }
            return nil
        }
        let notable = try #require(lists.first { $0.eyebrow == "Worth noting" })
        #expect(notable.items.contains { $0.text.contains("in a row over 10000 steps") })
    }

    @Test("workouts are a list, counted from the rows rather than from the model")
    func healthWorkouts() async throws {
        let readout = HealthReadout(workouts: [
            WorkoutRow(
                activity: "Running",
                start: HealthFixture.now.addingTimeInterval(-86_400),
                duration: 32 * 60,
                energyKilocalories: 340
            ),
            WorkoutRow(activity: "Yoga", start: HealthFixture.now.addingTimeInterval(-3 * 86_400), duration: 50 * 60)
        ])
        let payload = await HealthFixture.payload(.workouts, readout: readout)
        let lines = try #require(payload["workouts"] as? [String])
        let card = try #require(AnswerCardCatalogue.standard.card(
            for: PersonalDataToolNames.health, arguments: #"{"focus":"workouts"}"#, data: payload
        ))

        #expect(card.title == "Workouts")
        guard case .list(let list) = card.sections.first else {
            Issue.record("expected a list section, got \(card.sections)")
            return
        }
        // The count is derived from the rows, which is the number a 1–4B model
        // gets wrong first.
        #expect(list.eyebrow == "2 workouts")
        // Each row is the tool's own line, cut at the separator the tool wrote
        // and with nothing dropped on either side of it.
        #expect(list.items.count == lines.count)
        for (item, line) in zip(list.items, lines) {
            #expect(item.text + " \u{2014} " + (item.detail ?? "") == line)
        }
        #expect(list.items[0].text.hasPrefix("Running, Wed, Sep 10"))
        #expect(list.items[0].detail == "32 m, 340 kcal.")
        // No energy logged is not an energy of zero, and the tool already
        // dropped the clause rather than printing one.
        #expect(list.items[1].detail == "50 m.")
    }

    /// The heading follows what was asked, exactly as it does for the calendar:
    /// four focuses share one tool, and a card headed "Health" over a night's
    /// sleep is the vagueness these cards exist to remove.
    @Test("the heading and the glyph follow the focus that was asked for")
    func healthHeadingFollowsTheArguments() async throws {
        let readout = HealthReadout(samples: [
            .resting_heart_rate: HealthFixture.days(30, .beatsPerMinute) { _ in 58 },
            .heart_rate_variability: HealthFixture.days(30, .millisecond) { _ in 44 }
        ])
        let payload = await HealthFixture.payload(.heart, readout: readout)

        func card(_ arguments: String) -> AnswerCard? {
            AnswerCardCatalogue.standard.card(
                for: PersonalDataToolNames.health, arguments: arguments, data: payload
            )
        }

        #expect(card(#"{"focus":"heart"}"#)?.title == "Heart")
        #expect(card(#"{"focus":"heart"}"#)?.symbol == "heart")
        // What a dropped argument buys, which is why `render` has no default
        // for it — and the rows still draw.
        #expect(card("not json at all")?.title == "Health")
        #expect(card("not json at all")?.sections.isEmpty == false)
    }

    /// A reading whose wording has moved keeps its whole clause rather than
    /// guessing at half of it. The split is a lookup against the eight labels
    /// `HealthMetric` declares plus one ASCII literal, and it fails closed.
    @Test("a reading the builder cannot split keeps every word of it")
    func healthUnsplittableReadingIsKept() {
        let card = AnswerCardCatalogue.standard.card(
            for: PersonalDataToolNames.health,
            arguments: #"{"focus":"heart"}"#,
            data: ["readings": ["Blood glucose is not a metric this build knows about."]]
        )

        guard case .facts(let facts) = card?.sections.first else {
            Issue.record("expected a facts section, got \(String(describing: card?.sections))")
            return
        }
        #expect(facts.rows == [AnswerCard.Fact(label: "Blood glucose is not a metric this build knows about.")])
    }
}

// MARK: - Against the app, not against a fixture of it

/// The repository root, from this file.
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PocketdKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
}

/// Every name a `@Tool("…")` macro in the app target is registered under.
private func toolNames(in source: String) -> [String] {
    source.components(separatedBy: "@Tool(\"").dropFirst().compactMap { rest in
        rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}

/// The body of the first declaration whose signature begins with `signature`,
/// braces included, found by matching them.
private func declarationBody(startingWith signature: String, in source: String) -> String? {
    guard let start = source.range(of: signature) else { return nil }
    var depth = 0
    var body = ""
    for character in source[start.lowerBound...] {
        if character == "{" { depth += 1 }
        if depth > 0 { body.append(character) }
        if character == "}" {
            depth -= 1
            if depth == 0 { return body }
        }
    }
    return nil
}

/// Two claims about the app target that this package cannot make by importing
/// it: which tools exist, and whether a gesture is attached to a view. Both are
/// read out of the source that actually ships, the same way
/// `realBundleHasNoDuplicateRows` reads the shipping `Info.plist` rather than a
/// fixture of it — a fixture of either would have gone on passing through the
/// exact failure each of these exists to catch.
@Suite("Answer cards: what the app actually ships")
struct AnswerCardAppSurfaceTests {

    /// The failure that produced this test: health was declared as a tool and
    /// wired to the engine in one commit, reached `AnswerCardCatalogue.standard`
    /// in none of it, and nothing anywhere failed. Every health answer was the
    /// 1.7B model's prose about a payload that had already done the arithmetic.
    @Test("every tool the app registers draws a card")
    func everyToolRenders() throws {
        let tools = repositoryRoot().appendingPathComponent("App/Sources")
        let files = try #require(
            FileManager.default.enumerator(at: tools, includingPropertiesForKeys: nil),
            "App/Sources must be readable; the tools the app registers are declared there"
        )

        var declared: Set<String> = []
        for case let url as URL in files where url.pathExtension == "swift" {
            declared.formUnion(toolNames(in: try String(contentsOf: url, encoding: .utf8)))
        }

        #expect(declared == [
            PersonalDataToolNames.calendar,
            PersonalDataToolNames.reminders,
            PersonalDataToolNames.health
        ])
        #expect(
            Set(AnswerCardCatalogue.standard.toolNames) == declared,
            "a new @Tool in the app needs a name in PersonalDataToolNames and a builder in .standard"
        )
    }

    /// The card is drawn outside the bubble, at the full width of the page,
    /// because a table needs the 40 points a bubble gives up. Being outside it
    /// also took it out of reach of the bubble's long press — so the only part
    /// of an answer worth copying was the only part that could not be, while
    /// `copy(_:at:)` had been putting it on the pasteboard all along.
    @Test("the cards under a message carry the same copy affordance the bubble does")
    func cardsAreCopyable() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("App/Sources/Views/ChatView.swift"),
            encoding: .utf8
        )
        let cards = try #require(
            declarationBody(startingWith: "private func cards(for message: ChatMessage, at index: Int)", in: source),
            "ChatView must draw its cards in one place, so the affordance can be attached in one place"
        )

        #expect(cards.contains("AnswerCardView(card: card)"))
        #expect(cards.contains(".contextMenu"))
        #expect(cards.contains(#"Button("Copy", systemImage: "doc.on.doc") { copy(message, at: index) }"#))
        // A context menu is a long press, which VoiceOver spends on its own
        // gestures, so the rotor needs the same action.
        #expect(cards.contains(#".accessibilityAction(named: "Copy message") { copy(message, at: index) }"#))
        // And nowhere else: a second construction site is a second card with
        // nothing attached to it.
        #expect(source.components(separatedBy: "AnswerCardView(").count - 1 == 1)
    }
}
