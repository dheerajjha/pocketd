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

        #expect(catalogue.toolNames == ["get_calendar_events", "get_reminders", "get_timer"])
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

        #expect(card.sections.isEmpty)
        #expect(card.symbol == "lock")
        #expect(card.lede == PersonalDataAuthorization.denied.explanation(for: .calendar))
        for section in card.sections {
            if case .empty = section { Issue.record("a denied permission must never render as an empty state") }
        }
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
