import Testing
@testable import PocketdKit

@Suite("Today reminder ticks") @MainActor
struct ReminderAgendaTicksTests {
    @Test("No check, success receipt or hidden row on failed persistence; the same row can retry, while double taps do not save twice")
    func failureThenRetry() async throws {
        let ticks = ReminderAgendaTicks()
        let row = DayReminder(id: "second", title: "Return key")
        let firstRead = try #require(ticks.beginRead())
        var saves = 0
        var successSignals = 0
        let feedback: @MainActor () -> Void = { successSignals += 1 }
        let failed = await ticks.complete(row, onConfirmed: feedback) { target in
            #expect(successSignals == 0)
            #expect(ticks.phase(for: target.id) == .saving)
            #expect(ticks.phase(for: "first") == .open && ticks.beginRead() == nil)
            let duplicate = await ticks.complete(row, onConfirmed: feedback) { _ in saves += 1; return nil }
            #expect(duplicate == .ignored)
            let write = ReminderCompletion.set(true, id: target.id, matching: target,
                read: { (target, false) }, save: { saves += 1 }) // saved flag did not persist
            return write == .written ? ReminderCompletion(reminderID: target.id, title: target.title) : nil
        }
        #expect(failed == .failed && saves == 1 && successSignals == 0 && ticks.phase(for: row.id) == .open)
        ticks.hideChecked(row.id)
        #expect(ticks.phase(for: row.id) == .open && !ticks.acceptRead(firstRead))

        var storedDone = false
        let retry = await ticks.complete(row, onConfirmed: feedback) { target in
            #expect(successSignals == 0)
            let write = ReminderCompletion.set(true, id: target.id, matching: target,
                read: { (target, storedDone) }, save: { saves += 1; storedDone = true })
            return write == .written ? ReminderCompletion(reminderID: target.id, title: target.title) : nil
        }
        guard case .completed(let receipt) = retry else { Issue.record("Verified save produced no Undo receipt"); return }
        #expect(receipt.reminderID == row.id && saves == 2 && successSignals == 1)
        #expect(ticks.phase(for: row.id) == .checked && ticks.phase(for: "first") == .open)
        #expect(ticks.beginRead() == nil)
        let again = await ticks.complete(row) { _ in Issue.record("Saved a checked row twice"); return nil }
        #expect(again == .ignored)
        ticks.hideChecked(row.id)
        #expect(ticks.phase(for: row.id) == .hidden)
        let earlier = try #require(ticks.beginRead())
        let fresh = try #require(ticks.beginRead())
        #expect(!ticks.acceptRead(earlier) && ticks.acceptRead(fresh) && ticks.phase(for: row.id) == .open)
    }
}
