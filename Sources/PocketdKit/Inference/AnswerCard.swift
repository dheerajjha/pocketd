import Foundation

/// A renderable answer, built from what a tool actually returned rather than
/// from anything the model wrote about it.
///
/// A tool result is already structured and already authoritative. Today it is
/// serialised for the prompt by `ToolResult.encode` and then thrown away, and
/// the only thing the user ever sees is the model's prose about it — which is
/// where, on a 1–4B model, a 14:30 becomes "around two", four events become
/// three, and a fifth appears with a plausible name. Drawing the result and
/// leaving the model a sentence of narration over it removes all of that by
/// construction: it cannot get wrong what it was never asked to produce. This
/// is the cheapest reliability there is on a model this size, and the reason
/// the whole type exists.
///
/// The vocabulary is sections, not card types. One card type per tool would
/// mean a new value type, a new Codable shape and a new view for each of
/// health, alarms and timers; a small set of sections that any tool composes
/// means each of those arrives as a builder and nothing else.
///
/// Codable because conversations persist to JSON and reopen with their cards.
public struct AnswerCard: Sendable, Codable, Equatable {
    /// The tool that produced it. Never drawn. It is what makes a card in a
    /// reopened transcript attributable to something other than the model,
    /// which is the entire claim these cards exist to make.
    public var source: String?
    /// SF Symbol name for the card's header.
    public var symbol: String?
    public var title: String?
    /// One short sentence — the only part of a card a model is trusted with.
    ///
    /// Left nil by every builder that has data to draw, because on this app
    /// the model's sentence is already the assistant turn sitting directly
    /// above the card and printing it twice helps nobody. It is filled where
    /// the sentence *is* the answer and there is nothing under it: a permission
    /// that is switched off has no rows, only a thing to say.
    public var lede: String?
    public var sections: [Section]

    public init(
        source: String? = nil,
        symbol: String? = nil,
        title: String? = nil,
        lede: String? = nil,
        sections: [Section] = []
    ) {
        self.source = source
        self.symbol = symbol
        self.title = title
        self.lede = lede
        self.sections = sections
    }

    /// Nothing found, as a card.
    ///
    /// An empty result is the cheapest hallucination suppressant available: a
    /// model handed an empty list invents a day's meetings, and a model handed
    /// somewhere honest to land says there is nothing. Drawing that emptiness
    /// rather than drawing nothing is the same argument one layer up — a
    /// missing card reads as a tool that failed, which invites the reader to
    /// believe the prose instead.
    public static func nothing(
        _ text: String,
        title: String? = nil,
        symbol: String? = nil,
        source: String? = nil
    ) -> AnswerCard {
        AnswerCard(
            source: source,
            symbol: symbol,
            title: title,
            // Not `symbol` a second time. The header chip directly above has
            // already drawn it, and a free day that shows a calendar glyph and
            // then another calendar glyph one line down reads as a rendering
            // fault rather than as an answer. The view's own mark for an empty
            // state is deliberately a different one.
            sections: [.empty(Empty(text: text))]
        )
    }

    public var isEmpty: Bool {
        lede == nil && sections.isEmpty
    }
}

// MARK: - The vocabulary

public extension AnswerCard {
    /// One block inside a card. Any tool composes these; none of them knows
    /// what a calendar is.
    enum Section: Sendable, Equatable {
        /// Rows of label, value and an optional short accent — the shape for
        /// heterogeneous facts about one thing.
        case facts(Facts)
        /// Homogeneous items — the shape for several of the same thing.
        case list(Items)
        /// Two to four tiles, for numbers that deserve size.
        case metrics(Metrics)
        /// Ordered steps.
        case steps(Steps)
        /// A tinted advisory attached to the data above it.
        case note(Note)
        /// Nothing found. First class, never an absence.
        case empty(Empty)
    }

    struct Facts: Sendable, Codable, Equatable {
        /// The small monospaced caps label above the block.
        public var eyebrow: String?
        public var rows: [Fact]

        public init(eyebrow: String? = nil, rows: [Fact]) {
            self.eyebrow = eyebrow
            self.rows = rows
        }
    }

    struct Fact: Sendable, Codable, Equatable {
        public var label: String
        public var value: String?
        /// A short right-hand value — a time, a count, a status word. Short is
        /// a contract, not a hope: it shares one line's width with the label,
        /// and the view wraps and shrinks it rather than truncating, so a long
        /// one costs the row its shape.
        public var accent: String?

        public init(label: String, value: String? = nil, accent: String? = nil) {
            self.label = label
            self.value = value
            self.accent = accent
        }
    }

    struct Items: Sendable, Codable, Equatable {
        public var eyebrow: String?
        public var items: [Item]

        public init(eyebrow: String? = nil, items: [Item]) {
            self.eyebrow = eyebrow
            self.items = items
        }
    }

    struct Item: Sendable, Codable, Equatable {
        public var text: String
        public var detail: String?
        /// Same contract as `Fact.accent`.
        public var accent: String?
        public var symbol: String?

        public init(text: String, detail: String? = nil, accent: String? = nil, symbol: String? = nil) {
            self.text = text
            self.detail = detail
            self.accent = accent
            self.symbol = symbol
        }
    }

    struct Metrics: Sendable, Codable, Equatable {
        public var eyebrow: String?
        /// Two to four. More than four is a list wearing the wrong clothes, and
        /// on a phone it is four columns of broken words.
        public var tiles: [Tile]

        public init(eyebrow: String? = nil, tiles: [Tile]) {
            self.eyebrow = eyebrow
            self.tiles = tiles
        }
    }

    struct Tile: Sendable, Codable, Equatable {
        public var value: String
        public var caption: String

        public init(value: String, caption: String) {
            self.value = value
            self.caption = caption
        }
    }

    struct Steps: Sendable, Codable, Equatable {
        public var eyebrow: String?
        public var steps: [Step]

        public init(eyebrow: String? = nil, steps: [Step]) {
            self.eyebrow = eyebrow
            self.steps = steps
        }
    }

    struct Step: Sendable, Codable, Equatable {
        public var title: String
        public var detail: String?

        public init(title: String, detail: String? = nil) {
            self.title = title
            self.detail = detail
        }
    }

    struct Note: Sendable, Codable, Equatable {
        public var text: String
        public var symbol: String?
        public var tone: Tone

        public init(text: String, symbol: String? = nil, tone: Tone = .info) {
            self.text = text
            self.symbol = symbol
            self.tone = tone
        }
    }

    enum Tone: String, Sendable, Codable, Equatable {
        case info
        case caution

        /// A tone nobody here has heard of is still a note worth reading, so an
        /// unknown one lands on the quieter of the two rather than taking its
        /// section — and with it the rest of the conversation — down. See the
        /// note on `Section`'s decoder.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Tone(rawValue: raw) ?? .info
        }
    }

    struct Empty: Sendable, Codable, Equatable {
        public var text: String
        public var symbol: String?

        public init(text: String, symbol: String? = nil) {
            self.text = text
            self.symbol = symbol
        }
    }
}

// MARK: - Codable

extension AnswerCard.Section: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, body
    }

    private enum Kind: String, Codable {
        case facts, list, metrics, steps, note, empty
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .facts(let body):
            try container.encode(Kind.facts, forKey: .kind)
            try container.encode(body, forKey: .body)
        case .list(let body):
            try container.encode(Kind.list, forKey: .kind)
            try container.encode(body, forKey: .body)
        case .metrics(let body):
            try container.encode(Kind.metrics, forKey: .kind)
            try container.encode(body, forKey: .body)
        case .steps(let body):
            try container.encode(Kind.steps, forKey: .kind)
            try container.encode(body, forKey: .body)
        case .note(let body):
            try container.encode(Kind.note, forKey: .kind)
            try container.encode(body, forKey: .body)
        case .empty(let body):
            try container.encode(Kind.empty, forKey: .kind)
            try container.encode(body, forKey: .body)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard let section = try Self.decoded(kind: kind, from: container) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown section kind \"\(kind)\""
            )
        }
        self = section
    }

    /// Decodes a section, separating the one decode failure that is not a bug
    /// from every decode failure that is.
    ///
    /// nil means one thing only: a `kind` string this build has never heard of.
    /// A body that is malformed for a kind it *does* know throws, exactly as it
    /// would through `init(from:)`. See the note on `AnswerCard.LossySection`
    /// for why those two must not arrive at a caller looking alike.
    fileprivate static func decodedIfKnown(from decoder: any Decoder) throws -> Self? {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        return try decoded(kind: try container.decode(String.self, forKey: .kind), from: container)
    }

    private static func decoded(
        kind: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self? {
        switch Kind(rawValue: kind) {
        case .facts: return .facts(try container.decode(AnswerCard.Facts.self, forKey: .body))
        case .list: return .list(try container.decode(AnswerCard.Items.self, forKey: .body))
        case .metrics: return .metrics(try container.decode(AnswerCard.Metrics.self, forKey: .body))
        case .steps: return .steps(try container.decode(AnswerCard.Steps.self, forKey: .body))
        case .note: return .note(try container.decode(AnswerCard.Note.self, forKey: .body))
        case .empty: return .empty(try container.decode(AnswerCard.Empty.self, forKey: .body))
        case nil: return nil
        }
    }
}

extension AnswerCard {
    private enum CodingKeys: String, CodingKey {
        case source, symbol, title, lede, sections
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(lede, forKey: .lede)
        try container.encode(sections, forKey: .sections)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        lede = try container.decodeIfPresent(String.self, forKey: .lede)
        // A section this build has never heard of is dropped, not thrown.
        // `ConversationStore.all()` skips a file it cannot decode, so a card
        // written by a later build and opened by an earlier one — a TestFlight
        // rollback, nothing exotic — would otherwise cost the reader the whole
        // transcript to save them one block of it.
        sections = (try container.decodeIfPresent([LossySection].self, forKey: .sections) ?? [])
            .compactMap(\.section)
    }

    /// Carries the forward-compatibility rescue, and carries nothing else.
    ///
    /// The rescue is exactly one case wide: a `kind` string this build does not
    /// recognise. That case is a build we shipped writing a file a build we
    /// also shipped has to read, so tolerating it is the difference between
    /// losing a block and losing a transcript.
    ///
    /// A body that is malformed for a kind this build *does* know is not that
    /// case and is not swallowed. Encoding and decoding a section are the same
    /// six lines over the same six types, so no card this app writes can
    /// produce one — reaching it means the file was corrupted, or that a later
    /// build gave an existing body type a field it decodes as required. Every
    /// field added to an existing body must therefore be optional; a build that
    /// forgets loses old cards, and the only way anyone finds that out is a
    /// decode that fails loudly instead of a `try?` that quietly returns fewer
    /// sections than it read.
    private struct LossySection: Decodable {
        let section: Section?

        init(from decoder: any Decoder) throws {
            section = try Section.decodedIfKnown(from: decoder)
        }
    }
}

// MARK: - As text

public extension AnswerCard {
    /// The card as plain text, for the clipboard and for VoiceOver.
    ///
    /// Copying an answer whose substance is drawn rather than written must not
    /// hand back only the model's "here is your day" — the numbers are the part
    /// worth having, and they are the part that is not in the prose.
    var transcript: String {
        var lines: [String] = []
        if let title { lines.append(title) }
        if let lede { lines.append(lede) }
        for section in sections {
            switch section {
            case .facts(let body):
                if let eyebrow = body.eyebrow { lines.append(eyebrow) }
                for row in body.rows {
                    lines.append([row.label, row.value, row.accent].compactMap { $0 }.joined(separator: " — "))
                }
            case .list(let body):
                if let eyebrow = body.eyebrow { lines.append(eyebrow) }
                for item in body.items {
                    lines.append([item.text, item.detail, item.accent].compactMap { $0 }.joined(separator: " — "))
                }
            case .metrics(let body):
                if let eyebrow = body.eyebrow { lines.append(eyebrow) }
                for tile in body.tiles {
                    lines.append("\(tile.value) \(tile.caption)")
                }
            case .steps(let body):
                if let eyebrow = body.eyebrow { lines.append(eyebrow) }
                for (index, step) in body.steps.enumerated() {
                    lines.append("\(index + 1). " + [step.title, step.detail].compactMap { $0 }.joined(separator: " — "))
                }
            case .note(let body):
                lines.append(body.text)
            case .empty(let body):
                lines.append(body.text)
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The seam

/// How a tool declares that its result renders.
///
/// `arguments` is the same JSON the tool body already decoded successfully, and
/// it is here because the result alone does not say what was asked for: a list
/// of events carries no trace of whether the question was about today or next
/// week, and a card headed "Calendar" when the user asked about tomorrow is
/// the class of vagueness this whole feature exists to remove.
public typealias AnswerCardBuilder = @Sendable (
    _ arguments: String,
    _ data: [String: any Sendable]
) -> AnswerCard?

/// Which tools render, and how.
///
/// A lookup by tool name rather than a protocol requirement, and that is what
/// makes opting in optional: a tool that appears in no catalogue keeps exactly
/// the behaviour it has today — its output reaches the model through
/// `ToolResult.encode` and reaches nothing else. Nothing about registering a
/// card changes a byte of the prompt.
public struct AnswerCardCatalogue: Sendable {
    private let builders: [String: AnswerCardBuilder]

    public init(_ builders: [String: AnswerCardBuilder] = [:]) {
        self.builders = builders
    }

    /// `arguments` has no default, deliberately. See `ToolResult.render`.
    public func card(for tool: String, arguments: String, data: [String: any Sendable]) -> AnswerCard? {
        guard let build = builders[tool] else { return nil }
        guard let card = build(arguments, data), !card.isEmpty else { return nil }
        return card
    }

    public func registering(_ tool: String, _ build: @escaping AnswerCardBuilder) -> AnswerCardCatalogue {
        var merged = builders
        merged[tool] = build
        return AnswerCardCatalogue(merged)
    }

    public var toolNames: [String] { builders.keys.sorted() }

    public static let standard = AnswerCardCatalogue([
        PersonalDataToolNames.calendar: AnswerCardBuilders.calendar,
        PersonalDataToolNames.reminders: AnswerCardBuilders.reminders,
        PersonalDataToolNames.health: AnswerCardBuilders.health
    ])
}

/// The names the three real tools are registered under.
///
/// Repeated from `@Tool("get_calendar_events")` in `App/Sources/Tools/`, which
/// the kit cannot see and which needs a string literal because the macro reads
/// one. Two copies of a name is a thing that drifts, so the copy that matters —
/// the one the engine dispatches on — is the app's, and a card that stops
/// appearing is the symptom of this file falling behind it. `everyToolRenders`
/// reads the app's literals back out of the source to catch exactly that.
public enum PersonalDataToolNames {
    public static let calendar = "get_calendar_events"
    public static let reminders = "get_reminders"
    /// Health belongs in this enum by the codebase's own test of what personal
    /// data is: `HealthSummary.payload` opens with the same
    /// `origin.mayReachPersonalData` gate the other two do.
    public static let health = "get_health_summary"
}

// MARK: - The three real tools

/// Cards for the results `PersonalDataTools` and `HealthSummary` produce.
///
/// These read the payload dictionaries and nothing else. In particular they do
/// not reach into EventKit or HealthKit, do not re-read anything, and cannot
/// show a row the model was not also given — a card and the prose beside it are
/// two renderings of one payload, and a card that could disagree with the
/// prompt would be worse than no card at all.
public enum AnswerCardBuilders {

    public static let calendar: AnswerCardBuilder = { arguments, data in
        let range = argument(CalendarRange.self, named: "range", in: arguments)
        let title = range.map(name(for:)) ?? "Calendar"
        let symbol = "calendar"
        let source = PersonalDataToolNames.calendar

        if let text = data["text"] as? String {
            return sentence(
                text,
                title: title,
                symbol: symbol,
                source: source,
                isNothingFound: CalendarRange.allCases.contains { $0.emptyText == text }
            )
        }

        guard let events = data["events"] as? [[String: any Sendable]], !events.isEmpty else { return nil }

        let items = events.map { event -> AnswerCard.Item in
            let when = span(
                start: event["start"] as? String,
                end: event["end"] as? String
            )
            let location = event["location"] as? String
            return AnswerCard.Item(
                text: event["title"] as? String ?? "Untitled event",
                detail: [when, location].compactMap { $0 }.joined(separator: " · "),
                accent: event["all_day"] as? Bool == true ? "All day" : nil,
                symbol: "circle.fill"
            )
        }

        var sections: [AnswerCard.Section] = [
            .list(AnswerCard.Items(eyebrow: count(items.count, of: "event"), items: items))
        ]
        if let note = data["note"] as? String {
            sections.append(.note(AnswerCard.Note(text: note, symbol: "ellipsis", tone: .info)))
        }
        return AnswerCard(source: source, symbol: symbol, title: title, sections: sections)
    }

    public static let reminders: AnswerCardBuilder = { arguments, data in
        let filter = argument(ReminderFilter.self, named: "filter", in: arguments)
        let title = filter.map(name(for:)) ?? "Reminders"
        let symbol = "checklist"
        let source = PersonalDataToolNames.reminders

        if let text = data["text"] as? String {
            return sentence(
                text,
                title: title,
                symbol: symbol,
                source: source,
                isNothingFound: ReminderFilter.allCases.contains { $0.emptyText == text }
            )
        }

        guard let rows = data["reminders"] as? [[String: any Sendable]], !rows.isEmpty else { return nil }

        let items = rows.map { row -> AnswerCard.Item in
            // EventKit's scale runs 1 highest to 9 lowest, and the payload
            // carries a sentence saying so whenever any row has one. The accent
            // is the raw number rather than a word like "High" because the
            // sentence explains the number, and inventing a vocabulary the
            // model was not given is how a card and the prose beside it start
            // describing different things.
            let priority = row["priority"] as? Int
            return AnswerCard.Item(
                text: row["title"] as? String ?? "Untitled reminder",
                detail: row["due"] as? String,
                accent: priority.map { "P\($0)" },
                symbol: "circle"
            )
        }

        var sections: [AnswerCard.Section] = [
            .list(AnswerCard.Items(eyebrow: count(items.count, of: "reminder"), items: items))
        ]
        if let scale = data["priority_scale"] as? String {
            sections.append(.note(AnswerCard.Note(text: "Priority: \(scale).", symbol: "exclamationmark.circle", tone: .info)))
        }
        if let note = data["note"] as? String {
            sections.append(.note(AnswerCard.Note(text: note, symbol: "ellipsis", tone: .info)))
        }
        return AnswerCard(source: source, symbol: symbol, title: title, sections: sections)
    }

    /// The health tool's result, drawn.
    ///
    /// `HealthSummary` hands over finished clauses — every mean, delta, streak
    /// and record already computed, precisely so that a 1.7B model never does
    /// arithmetic about somebody's body. So this draws the clauses it was given
    /// and lifts exactly one thing out of them: the figure each reading opens
    /// with, which is what a reader looks for first and what a paragraph of
    /// prose buries in its middle.
    public static let health: AnswerCardBuilder = { arguments, data in
        let focus = argument(HealthFocus.self, named: "focus", in: arguments)
        let title = focus.map(name(for:)) ?? "Health"
        let symbol = focus.map(symbol(for:)) ?? "heart.text.square"
        let source = PersonalDataToolNames.health

        if let text = data["text"] as? String {
            return healthSentence(text, title: title, symbol: symbol, source: source)
        }

        if let workouts = data["workouts"] as? [String], !workouts.isEmpty {
            let items = workouts.map { line -> AnswerCard.Item in
                let parts = split(line, at: " — ")
                return AnswerCard.Item(text: parts.head, detail: parts.tail, symbol: "figure.run")
            }
            var sections: [AnswerCard.Section] = [
                .list(AnswerCard.Items(eyebrow: count(items.count, of: "workout"), items: items))
            ]
            if let note = data["note"] as? String {
                sections.append(.note(AnswerCard.Note(text: note, symbol: "ellipsis", tone: .info)))
            }
            return AnswerCard(source: source, symbol: symbol, title: title, sections: sections)
        }

        guard let readings = data["readings"] as? [String], !readings.isEmpty else { return nil }
        let lines = readings.map(healthReading(_:))

        var sections: [AnswerCard.Section] = []

        // A strip only where it is a strip: every reading carrying a figure, and
        // at least two of them. One tile is not a glance, and a strip built from
        // half the metrics puts the other half's numbers nowhere — the fact rows
        // below drop the figure only because the tile above is holding it.
        let tiles = lines.compactMap { line in
            line.figure.map { AnswerCard.Tile(value: $0, caption: line.label) }
        }
        let hasStrip = tiles.count == lines.count && tiles.count >= 2
        if hasStrip {
            sections.append(.metrics(AnswerCard.Metrics(eyebrow: "Latest whole day", tiles: tiles)))
        }

        sections.append(.facts(AnswerCard.Facts(
            eyebrow: "Against your own baseline",
            rows: lines.map { line in
                AnswerCard.Fact(label: line.label, value: hasStrip ? line.rest : line.clause)
            }
        )))

        if let notable = data["notable"] as? [String], !notable.isEmpty {
            sections.append(.list(AnswerCard.Items(
                eyebrow: "Worth noting",
                items: notable.map { AnswerCard.Item(text: $0, symbol: "sparkles") }
            )))
        }

        if let missing = data["no_data"] as? String {
            // One box, not two. `no_data` and `note` are written together and
            // say one thing — these metrics produced nothing, and iOS will not
            // say whether that is because nothing was recorded or because the
            // read was not allowed. Splitting them reads as two problems, and
            // the second half is the half that keeps the first one honest.
            let text = ["Nothing came back for \(missing).", data["note"] as? String]
                .compactMap { $0 }
                .joined(separator: " ")
            sections.append(.note(AnswerCard.Note(text: text, symbol: "questionmark.circle", tone: .info)))
        } else if let note = data["note"] as? String {
            sections.append(.note(AnswerCard.Note(text: note, symbol: "ellipsis", tone: .info)))
        }

        return AnswerCard(source: source, symbol: symbol, title: title, sections: sections)
    }

    // MARK: - Pieces

    /// A health payload that is one sentence and no data.
    ///
    /// Four things arrive on this key and only one of them is a lock.
    /// `ToolContext.refusal` is Pocketd refusing a network client, which is a
    /// decision this app made and can draw. The other three are not: Health
    /// missing from the device, the authorization request itself failing, and —
    /// the one this whole feature turns on — nothing coming back at all. iOS
    /// reports a read the user refused and a read with nothing behind it
    /// identically, so `HealthSummary.ambiguity` names both possibilities in one
    /// sentence, and a padlock drawn over that sentence would pick one of them
    /// while the words underneath said it could not be picked. It gets the empty
    /// state, whose mark means "nothing here" and claims nothing about why.
    static func healthSentence(
        _ text: String,
        title: String,
        symbol: String,
        source: String
    ) -> AnswerCard {
        if HealthFocus.allCases.contains(where: { HealthSummary.ambiguity(for: $0) == text }) {
            return .nothing(text, title: title, symbol: symbol, source: source)
        }
        if text == ToolContext.refusal {
            return AnswerCard(source: source, symbol: "lock", title: title, lede: text)
        }
        return AnswerCard(source: source, symbol: symbol, title: title, lede: text)
    }

    /// One reading line, taken apart only as far as it was put together.
    ///
    /// `HealthSummary.reading` writes the metric's label, then the formatted
    /// figure, then `" on "` and the date. Reading those back is a lookup
    /// against the labels `HealthMetric` declares and a search for one ASCII
    /// literal — not a parse of free text. A wording change there makes the
    /// split fail rather than succeed wrongly, and a failed split costs the card
    /// its metric strip and nothing else, which is why the fallbacks below keep
    /// the whole clause rather than a guess at part of it.
    static func healthReading(_ line: String) -> (label: String, clause: String?, figure: String?, rest: String?) {
        // Longest label first, and that is load-bearing rather than tidy:
        // "Heart rate" is a prefix of "Heart rate variability", so taking the
        // labels in declaration order would let the short one steal every HRV
        // row and file it under the wrong metric with the wrong unit.
        let labels = HealthMetric.allCases.map(\.label).sorted { $0.count > $1.count }
        guard let label = labels.first(where: { line.hasPrefix($0) }) else {
            return (line, nil, nil, nil)
        }
        let clause = String(line.dropFirst(label.count).drop(while: { $0 == ":" || $0 == " " }))
        guard !clause.isEmpty else { return (label, nil, nil, nil) }

        let parts = split(clause, at: " on ")
        guard let rest = parts.tail, !parts.head.isEmpty, parts.head.count <= longestFigure else {
            // No figure to lift: the day-still-in-progress line has no number in
            // it at all, and anything unexpectedly long is a wording change
            // rather than a measurement.
            return (label, clause, nil, nil)
        }
        return (label, clause, parts.head, "on " + rest)
    }

    /// Longer than `13.5 breaths/min`, and far shorter than a sentence.
    static let longestFigure = 24

    /// A line the tool wrote, cut at a separator the tool wrote.
    static func split(_ line: String, at separator: String) -> (head: String, tail: String?) {
        guard let range = line.range(of: separator) else { return (line, nil) }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }

    /// A payload that is one sentence and no data.
    ///
    /// Two different things arrive this way and they must not look alike. "No
    /// events today." is an answer, and gets the empty state. Anything else on
    /// that key is a permission that is off or a caller that may not ask, which
    /// is not an answer about the calendar at all — so it goes in the lede,
    /// where a card that says one thing and shows nothing is exactly what it
    /// looks like.
    static func sentence(
        _ text: String,
        title: String,
        symbol: String,
        source: String,
        isNothingFound: Bool
    ) -> AnswerCard {
        if isNothingFound {
            return .nothing(text, title: title, symbol: symbol, source: source)
        }
        return AnswerCard(source: source, symbol: "lock", title: title, lede: text)
    }

    /// `"Thu 11 Sep, 14:30"` and `"Thu 11 Sep, 15:30"` become
    /// `"Thu 11 Sep, 14:30 – 15:30"`.
    ///
    /// Done by trimming the shared head of the two strings back to the last
    /// separator inside it, which needs to know nothing about dates, formats or
    /// locales — and so cannot be wrong in Japanese the way splitting on a
    /// comma would be. `PersonalDataFormat` has already turned both ends into
    /// display strings by the time they reach here; re-deriving a `Date` from
    /// them to format the pair properly would be parsing our own output back,
    /// which is worse than a prefix scan.
    static func span(start: String?, end: String?) -> String? {
        guard let start, !start.isEmpty else { return end }
        guard let end, !end.isEmpty, end != start else { return start }

        var shared = start.startIndex
        var cursor = end.startIndex
        while shared < start.endIndex, cursor < end.endIndex, start[shared] == end[cursor] {
            shared = start.index(after: shared)
            cursor = end.index(after: cursor)
        }
        let head = start[start.startIndex..<shared]
        guard let separator = head.lastIndex(where: { $0 == "," || $0 == " " }) else {
            return "\(start) – \(end)"
        }
        let tail = end[end.index(end.startIndex, offsetBy: head.distance(from: head.startIndex, to: separator) + 1)...]
            .trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? start : "\(start) – \(tail)"
    }

    /// The count, said once, above the rows it counts.
    ///
    /// This is the number a small model gets wrong most often and the reader
    /// checks first, so it is derived here from the rows themselves rather than
    /// read out of anything the model produced.
    static func count(_ number: Int, of noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    /// One field out of the arguments the model sent.
    ///
    /// Tolerant everywhere: the tool body already decoded this string, so a
    /// failure here means only that the card loses its heading, and a card with
    /// a vaguer title is worth more than no card.
    static func argument<Value: RawRepresentable>(
        _ type: Value.Type,
        named field: String,
        in arguments: String
    ) -> Value? where Value.RawValue == String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object[field] as? String
        else { return nil }
        return Value(rawValue: raw)
    }

    static func name(for range: CalendarRange) -> String {
        switch range {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .this_week: "This week"
        case .next_week: "Next week"
        }
    }

    static func name(for filter: ReminderFilter) -> String {
        switch filter {
        case .overdue: "Overdue"
        case .today: "Due today"
        case .tomorrow: "Due tomorrow"
        case .this_week: "Due this week"
        case .all_open: "Open reminders"
        }
    }

    static func name(for focus: HealthFocus) -> String {
        switch focus {
        case .activity: "Activity"
        case .heart: "Heart"
        case .sleep: "Sleep"
        case .body: "Body"
        case .workouts: "Workouts"
        }
    }

    /// One glyph per focus rather than one for health. The header mark is the
    /// card's only claim about what it is, and a heart drawn over a night's
    /// sleep is the kind of near-miss that makes a reader wonder what else on a
    /// card about their body is approximate.
    static func symbol(for focus: HealthFocus) -> String {
        switch focus {
        case .activity: "figure.walk"
        case .heart: "heart"
        case .sleep: "bed.double"
        case .body: "figure.stand"
        case .workouts: "figure.run"
        }
    }
}
