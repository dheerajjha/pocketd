import Foundation
import Observation

/// Keep a tick on the observed row as it scrolls. A fresh read can legitimately
/// show the same reminder open if someone un-ticked it in Reminders.
@MainActor @Observable
public final class ReminderCardActions {
    public enum Phase: Equatable {
        case open, saving, done(ReminderCompletion), undoing

        public var isDone: Bool {
            switch self { case .done, .undoing: true; case .open, .saving: false }
        }
        public var isPending: Bool { self == .saving || self == .undoing }
    }

    public enum Outcome: Equatable {
        case ignored, failed(String), completed(ReminderCompletion)
    }

    public static let needsFreshList = "Ask for a fresh list to tick off reminders from this answer."
    private var phases: [UUID: Phase] = [:]
    private var pendingIDs: Set<String> = []

    public init() {}

    public func phase(for item: AnswerCard.Item) -> Phase {
        guard let live = item.liveReminder else { return .open }
        return phases[live.observation] ?? (pendingIDs.contains(live.row.id) ? .saving : .open)
    }

    public func complete(_ item: AnswerCard.Item, enabled: Bool, origin: RequestOrigin,
                         write: @MainActor (DayReminder) async -> WriteResult) async -> Outcome {
        guard origin.mayWritePersonalData else { return .failed(ToolContext.writeRefusal(for: origin)) }
        guard enabled else { return .failed("Reminders are switched off in Pocketd.") }
        guard let live = item.liveReminder else { return .failed(Self.needsFreshList) }
        let reminder = live.row
        guard phase(for: item) == .open, pendingIDs.insert(reminder.id).inserted else { return .ignored }
        defer { pendingIDs.remove(reminder.id) }
        switch await write(reminder) {
        case .written:
            let completion = ReminderCompletion(reminderID: reminder.id, title: reminder.title)
            phases[live.observation] = .done(completion)
            return .completed(completion)
        case .unauthorised(let auth):
            return .failed(auth.explanation(for: .reminders))
        case .failed:
            return .failed("Pocketd couldn’t confirm that tick. Check Reminders or try again.")
        }
    }

    /// nil means the toast was already used or replaced; it mustn't act on a later tick.
    public func undo(_ completion: ReminderCompletion, for item: AnswerCard.Item,
                     write: @MainActor (ReminderCompletion) async -> Bool) async -> Bool? {
        guard let live = item.liveReminder, phase(for: item) == .done(completion) else { return nil }
        guard completion.canUndo() else { return false }
        guard pendingIDs.insert(live.row.id).inserted else { return nil }
        defer { pendingIDs.remove(live.row.id) }
        phases[live.observation] = .undoing
        let restored = await write(completion)
        phases[live.observation] = restored ? nil : .done(completion)
        return restored
    }
}
