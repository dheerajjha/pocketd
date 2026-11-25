import Foundation

public extension SystemModelReads.Read {
    typealias Payload = [String: any Sendable]
    typealias Call = (name: String, arguments: Payload, body: @Sendable (RequestOrigin) async -> Payload)

    /// One descriptor for both engines: the range on the card is the same
    /// value that reached the store. None of these closures accepts a write.
    func call(
        calendar: @escaping @Sendable (CalendarRange, RequestOrigin) async -> Payload,
        reminders: @escaping @Sendable (ReminderFilter, RequestOrigin) async -> Payload,
        health: @escaping @Sendable (HealthFocus, RequestOrigin) async -> Payload
    ) -> Call? {
        switch self {
        case .calendar(let range):
            (PersonalDataToolNames.calendar, ["action": CalendarAction.list.rawValue, "range": range.rawValue], { await calendar(range, $0) })
        case .reminders(let filter):
            (PersonalDataToolNames.reminders, ["action": ReminderAction.list.rawValue, "filter": filter.rawValue], { await reminders(filter, $0) })
        case .health(let focus):
            (PersonalDataToolNames.health, ["focus": focus.rawValue], { await health(focus, $0) })
        case .switchedOff: nil
        }
    }
}

/// A whole list question can be answered by the phone even if a tool-capable
/// GGUF fails to spell the call. The Apple read planner also accepts vague
/// follow-ups; don't take those away from a model that can interpret them.
public enum DownloadedDayRead {
    private static let questions: Set<String> = {
        let calendarOpeners = ["whats on", "whats on my calendar", "whats on my schedule", "show my calendar", "show me my calendar", "what do i have on my calendar"]
        let reminderOpeners = ["whats due", "anything due", "what reminders are due", "what reminders do i have due"]
        let lists = CalendarRange.allCases.flatMap { range in
            calendarOpeners.map { "\($0) \(AnswerCardBuilders.name(for: range).lowercased())" }
        } + ["today", "tomorrow", "this week"].flatMap { day in reminderOpeners.map { "\($0) \(day)" } }
        return Set(lists + ["whats on my calendar", "what does my day look like", "what does my week look like",
                            "anything overdue", "whats overdue", "any overdue reminders", "show my reminders", "show me my reminders",
                            "how did i sleep", "how did i sleep last night", "how active have i been", "whats my resting heart rate",
                            "show my recent workouts"])
    }()

    /// A modifier, second instruction, image or implicit reference needs the
    /// ordinary generation path and its conversation history.
    private static func plan(_ request: GenerationRequest, gate: ToolGate.Decision) -> SystemModelReads.Read? {
        guard request.origin == .onDeviceChat, gate.registersTools,
              let last = request.messages.last, last.role == .user,
              !request.messages.contains(where: { !$0.images.isEmpty }) else { return nil }
        let text = SystemModelPlan.withoutReasoningSwitch(last.content)
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        let words = SystemModelPlan.words(in: text)
        let normalized = words.starts(with: ["what", "is"]) ? ["whats"] + words.dropFirst(2) : words
        // Identify the source independently of access. Admission is checked
        // before any lookup, so an unavailable source doesn't fall through to inference.
        guard questions.contains(normalized.joined(separator: " ")),
              let reads = SystemModelReads.plan(for: request, enabled: [.calendar, .reminders, .health]), reads.count == 1
        else { return nil }
        return reads.first
    }

    /// False means no read or stream event. A recognized turn never falls
    /// back to guessing, even if permission was refused or the read failed.
    public static func answer(
        _ request: GenerationRequest, gate: ToolGate.Decision,
        callFor: @Sendable (SystemModelReads.Read) -> SystemModelReads.Read.Call?,
        isAdmitted: @Sendable (String) async -> Bool,
        emit: @Sendable (GenerationEvent) -> Void
    ) async throws -> Bool {
        guard let read = plan(request, gate: gate) else { return false }
        let subject: String = switch read {
        case .calendar: "calendar"
        case .reminders: "reminders"
        case .health: "health data"
        case .switchedOff(let group): group.displayName.lowercased()
        }
        func finish(_ text: String, card: AnswerCard? = nil) throws -> Bool {
            try Task.checkCancellation()
            if let card { emit(.answerCard(card)) }
            emit(.token(text))
            emit(.finished(reason: .stop, usage: TokenUsage())) // no inference tokens
            return true
        }

        try Task.checkCancellation()
        let unavailable = "Pocketd can't check your \(subject) in this chat right now."
        guard let call = callFor(read), await isAdmitted(call.name) else { return try finish(unavailable) }
        try Task.checkCancellation()
        emit(.toolCallStarted(name: call.name))
        let started = Date()
        let output = await ToolReadDeadline.value(within: ToolReadDeadline.standard) {
            await ToolResult.withCard(from: call.name, arguments: ToolResult.encode(call.arguments)) { await call.body(request.origin) }
        }
        try Task.checkCancellation()
        // A source may have been switched off while the OS read was in flight.
        guard await isAdmitted(call.name) else { return try finish(unavailable) }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard let output, let card = output.card, let text = sentence(for: read, data: output.data) else {
            DiagnosticLog.record(.toolCall(name: call.name, outcome: .failed, milliseconds: ms))
            return try finish("Pocketd couldn't check your \(subject) this time.")
        }
        DiagnosticLog.record(.toolCall(name: call.name, outcome: ToolResult.outcome(of: output.data), milliseconds: ms))
        return try finish(text, card: card)
    }

    private static func sentence(for read: SystemModelReads.Read, data: [String: any Sendable]) -> String? {
        // Includes the store's exact empty, denied and not-connected outcomes.
        if let text = data["text"] as? String, !text.isEmpty { return text }
        func counted(_ count: Int, _ noun: String, _ when: String = "") -> String {
            let head = data["note"] == nil ? "You have" : "Showing the first"
            return "\(head) \(AnswerCardBuilders.count(count, of: noun))\(when)."
        }
        switch read {
        case .calendar(let range):
            guard let rows = data["events"] as? [[String: any Sendable]] else { return nil }
            return counted(rows.count, "event", " " + AnswerCardBuilders.name(for: range).lowercased())
        case .reminders(let filter):
            guard let rows = data["reminders"] as? [[String: any Sendable]] else { return nil }
            switch filter {
            case .all_open: return counted(rows.count, "open reminder")
            case .overdue: return counted(rows.count, "overdue reminder")
            default: return counted(rows.count, "reminder", " " + AnswerCardBuilders.name(for: filter).lowercased())
            }
        case .health(.workouts):
            guard let rows = data["workouts"] as? [String] else { return nil }
            return counted(rows.count, "recent workout")
        case .health:
            // Health dates each reading. Don't call an older sample "last
            // night", or substitute a secondary metric for a missing one.
            if let note = data["note"] as? String { return note }
            return (data["readings"] as? [String])?.first.map { "Latest available: \($0)" }
        case .switchedOff: return nil
        }
    }
}

/// An OS read can outlive a cancelled task. Release the engine gate on timeout
/// or Stop; a late result has no consumer. Shared with the Apple tools.
public enum ToolReadDeadline {
    public static let standard: Duration = .seconds(12)

    public static func value<T: Sendable>(within deadline: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        guard !Task.isCancelled else { return nil }
        let (result, reply) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let work = Task {
            guard !Task.isCancelled else { return }
            reply.yield(await operation())
            reply.finish()
        }
        let timer = Task {
            try await Task.sleep(for: deadline)
            reply.finish()
        }
        defer { reply.finish(); work.cancel(); timer.cancel() }
        var iterator = result.makeAsyncIterator()
        return await iterator.next()
    }
}
