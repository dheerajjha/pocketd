#if canImport(FoundationModels)
import Foundation
import FoundationModels
import os
import PocketdKit

// The calendar, reminders and health tools, as Apple's framework wants them.
//
// Each is a thin `Tool` onto the same body llama.cpp's tools call —
// `ToolBodies` in `App/Sources/Tools/` — so the origin gate, the permission
// sentences, the duplicate check, the past-time roll-forward and the write
// ledger behind Undo are one implementation, not two. The `@Generable`
// arguments mirror the LocalLLMClient tools key for key, so the arguments JSON
// the answer card reads is the JSON llama.cpp would have produced, and the card
// is the same card. Allowed values come from the Kit's own enums' `allCases`,
// so the schema the model sees and the values the body accepts are one list by
// construction, exactly as the LocalLLMClient macro arranges it.

/// One answer's tool calls: the events they emit, the rule about which may
/// run, and the session whose transcript says which round they are in.
///
/// One object per generation, shared by every tool the session holds, because
/// the round rule needs to see all of them: `SystemToolPolicy` decides from
/// the calls already made, and Apple's framework runs a round's calls
/// concurrently (measured on the Mac: a calendar and a reminders lookup in one
/// round started in the same millisecond). A lock rather than an actor so the
/// tools can read it without a hop in the middle of a call.
@available(iOS 26.0, *)
final class SystemToolRun: @unchecked Sendable {
    let origin: RequestOrigin
    /// The person's latest message, `ToolContext.userText(of:)` of the request.
    /// The calendar body believes the model's `duration_minutes` only when
    /// these words say how long (`EventLength`) — Apple's model fills it in
    /// for "dinner with Priya at 8pm" nine times in ten.
    let userText: String?
    private let emit: @Sendable (GenerationEvent) -> Void
    private let lock = NSLock()
    private weak var session: LanguageModelSession?
    private var calls = 0
    private var readsReturned = false
    private var wroteSomething = false
    private var stopped = false

    init(origin: RequestOrigin, userText: String? = nil, emit: @escaping @Sendable (GenerationEvent) -> Void) {
        self.origin = origin
        self.userText = userText
        self.emit = emit
    }

    /// Before the first token is asked for, so the first call can already
    /// count its round.
    func attach(_ session: LanguageModelSession) {
        lock.withLock { self.session = session }
    }

    /// Stop was pressed, or the answer failed: nothing may be written from
    /// here on, even by a call the framework has already started.
    func stop() {
        lock.withLock { stopped = true }
    }

    /// Whether any tool ran. An answer that did nothing can be retried with
    /// less history; one that read or wrote cannot be repeated quietly.
    var anyCallMade: Bool { lock.withLock { calls > 0 } }

    /// Whether this answer changed anything. Repeating a question that already
    /// filed a reminder is how the user ends up with two.
    var anyWriteMade: Bool { lock.withLock { wroteSomething } }

    /// Which round of tool calls is running, from the session's transcript.
    ///
    /// Measured, not assumed: inside a tool's `call`, the transcript already
    /// holds the `.toolCalls` entry for the round that call belongs to — one
    /// for the first round, two for the second — so the round is the number of
    /// `.toolCalls` entries since the last prompt. `nil` when the transcript
    /// does not say, which `SystemToolPolicy` treats more strictly.
    func currentRound() -> Int? {
        guard let session = lock.withLock({ self.session }) else { return nil }
        var rounds = 0
        for entry in session.transcript.reversed() {
            if case .prompt = entry { break }
            if case .toolCalls = entry { rounds += 1 }
        }
        return rounds > 0 ? rounds : nil
    }

    /// Runs one tool body, or explains why not, and returns what the model
    /// reads next.
    ///
    /// Never throws, for the reason `LlamaEngine.execute` gives: a thrown tool
    /// error ends the whole answer, and a model that asked for the wrong thing
    /// can usually still answer if it is told so in a sentence. The bodies
    /// themselves never throw either — every failure is a `text` sentence.
    ///
    /// - Parameters:
    ///   - arguments: What the model asked for, as the JSON keys the
    ///     LocalLLMClient tool decodes. Only the card reads it — it is how the
    ///     card knows the question was about tomorrow rather than today.
    ///   - body: The shared tool body (`ToolBodies`), handed the origin.
    func execute(
        _ name: String,
        change: SystemToolPolicy.Change?,
        arguments: [String: any Sendable],
        body: @escaping @Sendable (RequestOrigin) async -> [String: any Sendable]
    ) async -> String {
        let isWrite = change != nil
        let round = currentRound()
        let verdict: SystemToolPolicy.Verdict = lock.withLock {
            calls += 1
            return SystemToolPolicy.decide(
                change: change,
                round: round,
                callNumber: calls,
                readsReturned: readsReturned,
                stopped: stopped || Task.isCancelled
            )
        }
        if case let .refuse(sentence) = verdict {
            DiagnosticLog.record(.failure(area: .tools, code: "fm.toolRefused.\(name)"))
            return sentence
        }

        // Announced before the work, as LlamaEngine does: the conversation
        // shows "checking…" until the next token arrives.
        emit(.toolCallStarted(name: name))
        let json = Self.json(arguments)
        #if DEBUG
        // The model's words, exactly as it sent them. A reminder at the wrong
        // time is either what the model wrote or how the body read it, and
        // only this line tells the two apart — "6pm" at 2:33 PM filed for
        // tomorrow was the model writing "tomorrow at 6pm". Debug builds
        // only: the arguments carry what the user said.
        Self.debugLog.debug("\(name, privacy: .public) \(json, privacy: .public)")
        #endif
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        // The origin is passed, and bound as well. Task locals did reach a tool
        // body through Apple's framework on the Mac probe, but the framework
        // owns the task that calls this, and the origin is the one value that
        // decides whether personal data may be read at all — so it is never
        // left to arrive on its own. The person's words are bound beside it,
        // and the calendar tool passes them too.
        let origin = self.origin
        let userText = self.userText
        let data: [String: any Sendable]
        if isWrite {
            // A change is never abandoned part-way: EventKit may still save it
            // after a timeout said it had not happened, and an answer that
            // denies a reminder the list then shows is worse than a slow one.
            data = await ToolContext.$origin.withValue(origin) {
                await ToolContext.$userText.withValue(userText) { await body(origin) }
            }
            lock.withLock { wroteSomething = true }
        } else if let read = await Self.withDeadline(Self.readDeadline, {
            await ToolContext.$origin.withValue(origin) {
                await ToolContext.$userText.withValue(userText) { await body(origin) }
            }
        }) {
            data = read
        } else {
            DiagnosticLog.record(.toolCall(name: name, outcome: .failed, milliseconds: elapsed()))
            return "\(name) took too long to answer just now. Tell the user you couldn't check it this time."
        }

        // The card from the payload, never from the model's account of it —
        // the same rendering LlamaEngine emits for the same payload.
        let rendered = ToolResult.render(data, from: name, arguments: json)
        if let card = rendered.card { emit(.answerCard(card)) }
        if !isWrite { lock.withLock { readsReturned = true } }
        DiagnosticLog.record(.toolCall(name: name, outcome: Self.outcome(of: data), milliseconds: elapsed()))
        return SystemToolOutput.render(data)
    }

    /// Same classification LlamaEngine records, read off the payload.
    static func outcome(of data: [String: any Sendable]) -> DiagnosticEvent.ToolOutcome {
        guard let text = data["text"] as? String else { return .ok }
        if text == ToolContext.refusal { return .refusedByOrigin }
        if PersonalDataAuthorization.isRefusalSentence(text) { return .unauthorised }
        return .empty
    }

    /// Sorted keys, so the card builder and the body read the same bytes on
    /// every launch — the reason `ToolResult.encode` sorts too.
    static func json(_ arguments: [String: any Sendable]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    #if DEBUG
    /// `log stream --level debug --predicate 'category == "fm.tools"'`.
    static let debugLog = Logger(subsystem: "dev.pocketd.app", category: "fm.tools")
    #endif

    /// How long a lookup may hold an answer. EventKit answers in milliseconds
    /// and a Health read in about one second; on the simulator, a Health read
    /// that tried to ask for permission it could never get held "how did I
    /// sleep?" for 86 seconds before saying so. Twelve is long past any
    /// healthy read and short enough that nobody reaches for Stop first.
    static let readDeadline: Duration = .seconds(12)

    /// The operation's result, or `nil` if the deadline came first.
    ///
    /// The operation is not waited for after the deadline — a structured task
    /// group would wait for its children, which is exactly the 86 seconds this
    /// exists to avoid. It runs to completion on its own and its result is
    /// dropped.
    static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let work = Task {
                let value = await operation()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if once.claim() {
                    continuation.resume(returning: nil)
                    work.cancel()
                }
            }
        }
    }

    /// The trimmed text, or nothing, so an empty field never reaches a body
    /// that would read "" as a title.
    static func present(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The tools for one plan, in the plan's order.
    static func tools(for groups: [CapabilityGroup], run: SystemToolRun) -> [any Tool] {
        groups.compactMap { group -> (any Tool)? in
            switch group {
            case .calendar: SystemCalendarTool(run: run)
            case .reminders: SystemRemindersTool(run: run)
            case .health: SystemHealthTool(run: run)
            case .alarms, .timers: nil
            }
        }
    }
}

/// True for exactly one caller, for resuming a continuation exactly once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

// MARK: - Calendar

@available(iOS 26.0, *)
struct SystemCalendarTool: Tool {
    let name = PersonalDataToolNames.calendar
    let description = "List events from the user's calendar, or add a new one."
    let run: SystemToolRun

    @Generable
    struct Arguments {
        @Guide(description: "What to do.", .anyOf(CalendarAction.allCases.map(\.rawValue)))
        var action: String

        // "For list only", because a create sometimes put the day here —
        // `range: tomorrow`, `start: 10am` — where the body never reads it.
        @Guide(description: "For list only: which days to list.", .anyOf(CalendarRange.allCases.map(\.rawValue)))
        var range: String?

        @Guide(description: "For create: what the event is called, without its time.")
        var title: String?

        // The reminders tool's `when` has the measurements. Here the old
        // example turned "add dinner with Priya at 8pm" into "tomorrow at
        // 8pm" five times in five.
        @Guide(description: "For create: when it starts, in the user's exact words, like '3pm', 'Friday at 1pm' or 'tomorrow at 9'. Never add a day they did not say.")
        var start: String?

        // Filled nine times in ten when nobody said how long, whatever this
        // says, so the body decides whether to believe it: `EventLength`.
        @Guide(description: "For create: how many minutes it lasts. Leave out for an hour.")
        var duration_minutes: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let action = CalendarAction(rawValue: arguments.action) ?? .list
        let range = arguments.range.flatMap(CalendarRange.init(rawValue:)) ?? .today
        let title = SystemToolRun.present(arguments.title)
        let start = SystemToolRun.present(arguments.start)
        let minutes = arguments.duration_minutes
        let userText = run.userText

        var json: [String: any Sendable] = ["action": action.rawValue]
        switch action {
        case .list:
            // Always written out, never left to a default: the card's heading
            // is read from this, and "Today" is the heading a missing range
            // would lose.
            json["range"] = range.rawValue
        case .create:
            if let title { json["title"] = title }
            if let start { json["start"] = start }
            if let minutes { json["duration_minutes"] = minutes }
        }
        return await run.execute(name, change: action == .create ? .addEvent : nil, arguments: json) { origin in
            await ToolBodies.calendar(
                action: action, range: range, title: title, start: start,
                durationMinutes: minutes, userText: userText, origin: origin
            )
        }
    }
}

// MARK: - Reminders

@available(iOS 26.0, *)
struct SystemRemindersTool: Tool {
    let name = PersonalDataToolNames.reminders
    let description = "List the user's reminders, add a new one, or tick one off."
    let run: SystemToolRun

    @Generable
    struct Arguments {
        @Guide(description: "What to do.", .anyOf(ReminderAction.allCases.map(\.rawValue)))
        var action: String

        @Guide(description: "For list: which reminders to list.", .anyOf(ReminderFilter.allCases.map(\.rawValue)))
        var filter: String?

        @Guide(description: "For create and complete: what the reminder says, without its time.")
        var title: String?

        // Measured on the Mac against the iOS 27 model ("AFM 3 Core"), asked
        // at 14:33. With the old example, 'tomorrow at 3pm', "remind me to
        // call mom at 6pm" came back with a day added seven times in ten
        // ("tomorrow at 18:00"), and was filed for tomorrow. Examples with no
        // day in them fixed that and lost the days people did say ("Friday
        // at 5pm" became "5pm"); with no relative one, "in 20 minutes"
        // became a clock time it worked out itself, often wrongly. One example
        // of each shape, and the rule in words here and in
        // `SystemModelPlan.toolPreamble`: "6pm" thirty times in thirty, and
        // "tomorrow at 9", "Friday at 5pm", "in 20 minutes" and "2am" passed
        // word for word every time.
        @Guide(description: "For create: when it is due, in the user's exact words, like '6pm', 'tomorrow at 9', 'in 20 minutes' or 'every day at 7am'. Never add a day they did not say. Leave out for no due date.")
        var when: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let action = ReminderAction(rawValue: arguments.action) ?? .list
        let filter = arguments.filter.flatMap(ReminderFilter.init(rawValue:)) ?? .all_open
        let title = SystemToolRun.present(arguments.title)
        let when = SystemToolRun.present(arguments.when)

        var json: [String: any Sendable] = ["action": action.rawValue]
        switch action {
        case .list:
            json["filter"] = filter.rawValue
        case .create:
            if let title { json["title"] = title }
            if let when { json["when"] = when }
        case .complete:
            if let title { json["title"] = title }
        }
        let change: SystemToolPolicy.Change? = switch action {
        case .list: nil
        case .create: .addReminder
        case .complete: .tickOff
        }
        return await run.execute(name, change: change, arguments: json) { origin in
            await ToolBodies.reminders(action: action, filter: filter, title: title, when: when, origin: origin)
        }
    }
}

// MARK: - Health

@available(iOS 26.0, *)
struct SystemHealthTool: Tool {
    let name = PersonalDataToolNames.health
    let description = "Read the user's health data from this iPhone, already compared against their own long-term baseline."
    let run: SystemToolRun

    @Generable
    struct Arguments {
        @Guide(description: "Which part of the user's health to look at.", .anyOf(HealthFocus.allCases.map(\.rawValue)))
        var focus: String
    }

    func call(arguments: Arguments) async throws -> String {
        // A focus outside the list cannot be generated under `.anyOf`. If one
        // arrives anyway it is named back to the model rather than swapped
        // for a different focus, which would answer a question nobody asked.
        guard let focus = HealthFocus(rawValue: arguments.focus) else {
            let choices = HealthFocus.allCases.map(\.rawValue).joined(separator: ", ")
            return "No health focus called \"\(arguments.focus)\". Use one of: \(choices)."
        }
        return await run.execute(name, change: nil, arguments: ["focus": focus.rawValue]) { origin in
            await SystemReads.health(focus: focus, origin: origin)
        }
    }
}
#endif
