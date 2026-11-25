import Foundation

/// Authority and receipts for exactly one interactive Ask submission. Never
/// encoded, synthesized from chat history, or shared between generations.
public final class ModelWriteTurn: @unchecked Sendable, Equatable {
    public static func == (lhs: ModelWriteTurn, rhs: ModelWriteTurn) -> Bool { lhs === rhs }
    @TaskLocal public static var current: ModelWriteTurn?
    let question: String?
    let intent: ModelWriteIntent?
    private let lock = NSLock()
    private var spent = false
    private var receipts: [String] = []

    init(question: String?) { self.question = question; intent = question.flatMap(ModelWriteIntent.init) }

    public typealias Payload = [String: any Sendable]
    public typealias Change = SystemToolPolicy.Change

    /// The common EventKit adapter calls this *before* any lookup, duplicate
    /// check or save. Model arguments describe a proposal; only the separately
    /// supplied user's words can grant it. At most one change per submission,
    /// including simultaneous calls from the system model.
    static func perform(_ change: Change, title: String?, when: String? = nil, minutes: Int? = nil,
                               origin: RequestOrigin, _ body: () async -> Payload) async -> Payload {
        guard origin.mayWritePersonalData else {
            let text = ToolContext.writeRefusal(for: origin)
            current?.record(text)
            return ["text": text]
        }
        guard let turn = current else { return ["text": refusal(for: change)] }
        enum Decision { case admitted, spent, refused }
        let decision: Decision = turn.lock.withLock {
            if turn.spent { return .spent }
            guard !Task.isCancelled, let intent = turn.intent, intent.change == change,
                  intent.covers(title: title, when: when, minutes: minutes) else { return .refused }
            turn.spent = true
            return .admitted
        }
        switch decision {
        case .spent: return ["text": "No additional change was made."] // keep the original operation's receipt
        case .refused:
            let text = refusal(for: change)
            turn.record(text)
            return ["text": text]
        case .admitted: break
        }
        let result = await body()
        let actual = result["text"] as? String ?? refusal(for: change)
        turn.lock.withLock { turn.receipts = [actual] }
        return result
    }

    static func refusal(for change: Change) -> String {
        switch change {
        case .addEvent: "I didn't add an event. To add one, ask ‘Add [title] to my calendar at [time]’."
        case .addReminder: "I didn't add a reminder. To add one, ask ‘Remind me to [task]’ and include a time if you want one."
        case .tickOff: "I didn't tick off a reminder. To complete one, ask ‘Tick off [exact reminder title]’."
        }
    }

    private func record(_ text: String) { lock.withLock { if !spent, !receipts.contains(text) { receipts.append(text) } } }
    /// Only trusted body results or local refusals. Once a write was attempted,
    /// Ask uses this as its transcript, even if the model had streamed an
    /// unrecognized preamble before the backend delivered the call.
    public var receipt: String? { lock.withLock { receipts.isEmpty ? nil : receipts.joined(separator: "\n") } }

    /// A framework policy refused the call before it could enter the adapter.
    /// Preserve that fact without turning an attempt into write authority.
    public func noteRefused(_ change: Change) { record(Self.refusal(for: change)) }

    /// A model can name a write and fail macro argument decoding before the
    /// body is called. This can record *only a failure*, never authorize it.
    public static func noteUndecodable(tool: String, arguments: String) {
        guard let turn = current,
              let obj = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let action = obj["action"] as? String else { return }
        let change: Change
        switch (tool, action) {
        case (PersonalDataToolNames.calendar, "create"): change = .addEvent
        case (PersonalDataToolNames.reminders, "create"): change = .addReminder
        case (PersonalDataToolNames.reminders, "complete"): change = .tickOff
        default: return
        }
        turn.noteRefused(change)
    }

    public static func didWrite(_ result: Payload) -> Bool {
        result["created"] as? Bool == true || result["completed"] as? Bool == true
    }
}
