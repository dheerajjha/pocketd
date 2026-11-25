import Observation

/// The Today page briefly shows a confirmed tick before refreshing the list.
/// Claiming a tap only starts a save; it does not check or remove the row.
@MainActor @Observable
public final class ReminderAgendaTicks {
    public enum Phase: Equatable { case open, saving, checked, hidden }
    public enum Outcome: Equatable { case ignored, failed, completed(ReminderCompletion) }
    private var phases: [String: Phase] = [:]
    private var revision = 0

    public init() {}
    public func phase(for id: String) -> Phase { phases[id] ?? .open }

    public func complete(_ row: DayReminder, onConfirmed: @MainActor () -> Void = {},
                         save: @MainActor (DayReminder) async -> ReminderCompletion?) async -> Outcome {
        guard phase(for: row.id) == .open else { return .ignored }
        revision += 1
        phases[row.id] = .saving
        guard let receipt = await save(row), receipt.reminderID == row.id else {
            phases.removeValue(forKey: row.id)
            return .failed
        }
        phases[row.id] = .checked
        onConfirmed()
        return .completed(receipt)
    }

    public func hideChecked(_ id: String) {
        if phase(for: id) == .checked { phases[id] = .hidden }
    }

    // A refresh begun before a tap mustn't reinstate a stale row; one during
    // the checked animation mustn't remove it before the person sees the tick.
    public func beginRead() -> Int? {
        guard !phases.values.contains(where: { $0 == .saving || $0 == .checked }) else { return nil }
        revision += 1 // the post-Undo read supersedes any earlier fetch still in flight
        return revision
    }

    public func acceptRead(_ started: Int) -> Bool {
        guard revision == started else { return false }
        phases.removeAll()
        return true
    }
}
