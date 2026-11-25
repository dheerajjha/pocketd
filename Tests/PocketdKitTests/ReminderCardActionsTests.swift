import Foundation
import Testing
@testable import PocketdKit

private let listArguments = #"{"action":"list","filter":"all_open"}"#

private func readCard(_ rows: [ReminderRow], origin: RequestOrigin = .onDeviceChat) async -> ToolResult.CardOutput {
    await ToolResult.withCard(from: PersonalDataToolNames.reminders, arguments: listArguments) {
        await PersonalDataTools.reminderPayload(filter: .all_open, origin: origin) { _ in .rows(rows, truncated: false) }
    }
}

private func items(_ card: AnswerCard?) throws -> [AnswerCard.Item] {
    let lists = card?.sections.compactMap { section -> AnswerCard.Items? in
        if case .list(let list) = section { return list }
        return nil
    }
    return try #require(lists?.first).items
}

@Suite("Native reminder card actions")
struct ReminderCardActionsTests {
    private let rows = [ReminderRow(title: "Send invoice", identifier: "native-fixture-A"),
                        ReminderRow(title: "Send invoice", identifier: "native-fixture-B")]

    @Test("Only the live native card has action handles; models, copies and saved conversations get none")
    func nativeOnly() async throws {
        let output = await readCard(rows)
        let card = try #require(output.card)
        #expect(try items(card).map { $0.reminder?.id } == rows.map(\.identifier))
        let observations = try items(card).compactMap { $0.liveReminder?.observation.uuidString }
        #expect(Set(observations).count == 2)
        let noHandles = await readCard([ReminderRow(title: "Send invoice"), ReminderRow(title: "Send invoice")])
        #expect(ToolResult.encode(output.data) == ToolResult.encode(noHandles.data))
        let appleText = SystemToolOutput.render(output.data)
        let downloadedText = ToolResult.encode(output.data)
        let message = ChatMessage(role: .assistant, content: "Two open reminders.", cards: [card])
        let nextCloudTurn = try SystemModelPlan.make(for: GenerationRequest(modelID: ModelRecord.privateCloudComputeID,
            messages: [.user("My reminders?"), message, .user("Thanks")], origin: .onDeviceChat), enabled: [.reminders])
        #expect(nextCloudTurn.history.map(\.text) == ["My reminders?", "Two open reminders."])
        #expect(!(nextCloudTurn.instructions + nextCloudTurn.prompt).contains("native-fixture"))
        let saved = try JSONEncoder().encode(message)
        for text in [downloadedText, appleText, card.transcript, String(decoding: saved, as: UTF8.self)] {
            #expect(text.contains("Send invoice"))
            #expect(!text.contains("native-fixture"))
            #expect(!observations.contains { text.localizedCaseInsensitiveContains($0) })
        }
        let reopened = try JSONDecoder().decode(ChatMessage.self, from: saved)
        #expect(try items(reopened.cards.first).map(\.text) == ["Send invoice", "Send invoice"])
        #expect(try items(reopened.cards.first).allSatisfy { $0.reminder == nil })
        let scheduled = await readCard(rows, origin: .scheduledTask(id: UUID()))
        #expect(try items(scheduled.card).count == 2)
        #expect(try items(scheduled.card).allSatisfy { $0.reminder == nil })
        let remote = await readCard(rows, origin: .network(host: "localhost", port: 1))
        #expect(remote.data["text"] as? String == ToolContext.refusal)
        #expect(remote.card?.symbol == "lock")
    }

    @Test("Interleaved reads with identical display data keep their own rows in their original order")
    func perInvocation() async throws {
        let rows = self.rows
        // Force the other read to finish between this one's EventKit read and return.
        let outer = await ToolResult.withCard(from: PersonalDataToolNames.reminders, arguments: listArguments) {
            let data = await PersonalDataTools.reminderPayload(filter: .all_open, origin: .onDeviceChat) { _ in
                .rows(rows, truncated: false)
            }
            let inner = await readCard(Array(rows.reversed()))
            #expect((try? items(inner.card).map { $0.reminder?.id }) == rows.reversed().map(\.identifier))
            return data
        }
        #expect(try items(outer.card).map { $0.reminder?.id } == rows.map(\.identifier))
    }

    @Test("Two identical-looking rows: a second tap while saving can't write; the tick and Undo belong to exactly the second ID")
    @MainActor func duplicateAndUndo() async throws {
        let list = try items(await readCard(rows).card)
        #expect(list.count == 2)
        let second = try #require(list.last?.reminder)
        let actions = ReminderCardActions()
        let otherRead = try items(await readCard(rows).card)
        var done = Set<String>()
        var saves: [String] = []
        func change(_ row: DayReminder, to completed: Bool) -> WriteResult {
            ReminderCompletion.set(completed, id: row.id, matching: row) {
                (row, done.contains(row.id))
            } save: {
                saves.append(row.id)
                if completed { done.insert(row.id) } else { done.remove(row.id) }
            }
        }
        let outcome = await actions.complete(list[1], enabled: true, origin: .onDeviceChat) { target in
            #expect(target == second)
            #expect(actions.phase(for: list[1]).isPending && !actions.phase(for: list[1]).isDone)
            #expect(actions.phase(for: list[0]) == .open)
            let double = await actions.complete(list[1], enabled: true, origin: .onDeviceChat) { change($0, to: true) }
            #expect(double == .ignored)
            let sameRecord = await actions.complete(otherRead[1], enabled: true, origin: .onDeviceChat) { change($0, to: true) }
            #expect(sameRecord == .ignored)
            return change(target, to: true)
        }
        guard case .completed(let receipt) = outcome else { Issue.record("Expected verified receipt"); return }
        #expect(done == [second.id] && saves == [second.id])
        #expect(actions.phase(for: list[1]) == .done(receipt) && actions.phase(for: list[0]) == .open)
        #expect(actions.phase(for: otherRead[1]) == .open) // another snapshot doesn't inherit this tick
        #expect(receipt.reminderID == second.id)

        let failedUndo = await actions.undo(receipt, for: list[1]) { _ in false }
        #expect(failedUndo == false && actions.phase(for: list[1]) == .done(receipt))
        let restored = await actions.undo(receipt, for: list[1]) { receipt in
            let duplicate = await actions.undo(receipt, for: list[1]) { _ in Issue.record("Double Undo wrote"); return true }
            #expect(duplicate == nil)
            return change(second, to: false) == .written
        }
        #expect(restored == true && done.isEmpty && saves == [second.id, second.id])
        #expect(actions.phase(for: list[1]) == .open && actions.phase(for: list[0]) == .open)
        let replay = await actions.undo(receipt, for: list[1]) { _ in Issue.record("Used Undo replayed"); return true }
        #expect(replay == nil)
    }

    @Test("A stale row, a failed save, or a save which reads back open never produces a tick or an Undo; a retry can succeed")
    @MainActor func staleAndRetry() async throws {
        let item = try #require(try items(await readCard(rows).card).first)
        let wanted = try #require(item.reminder)
        let actions = ReminderCardActions()
        var moved = wanted; moved.due = Date(timeIntervalSinceReferenceDate: 100)
        var replacement = wanted; replacement.id = "different-record-with-identical-title"
        let stale: [(DayReminder, Bool)?] = [nil, (moved, false), (replacement, false), (wanted, true)]
        var writes = 0
        for current in stale {
            let outcome = await actions.complete(item, enabled: true, origin: .onDeviceChat) { target in
                ReminderCompletion.set(true, id: target.id, matching: target, read: { current }, save: { writes += 1 })
            }
            guard case .failed = outcome else { Issue.record("A stale row was reported as saved"); return }
            #expect(actions.phase(for: item) == .open)
        }
        #expect(writes == 0)
        let unconfirmed = await actions.complete(item, enabled: true, origin: .onDeviceChat) { target in
            ReminderCompletion.set(true, id: target.id, matching: target, read: { (wanted, false) }, save: { writes += 1 })
        }
        guard case .failed = unconfirmed else { Issue.record("The store still says open"); return }
        #expect(writes == 1 && actions.phase(for: item) == .open)
        var advanced = false
        let nextOccurrence = await actions.complete(item, enabled: true, origin: .onDeviceChat) { target in
            ReminderCompletion.set(true, id: target.id, matching: target, read: { advanced ? (moved, true) : (wanted, false) },
                                   save: { advanced = true })
        }
        guard case .failed = nextOccurrence else { Issue.record("Read-back was a different occurrence"); return }
        #expect(actions.phase(for: item) == .open)
        let denied = await actions.complete(item, enabled: true, origin: .onDeviceChat) { _ in .unauthorised(.denied) }
        #expect(denied == .failed(PersonalDataAuthorization.denied.explanation(for: .reminders)))
        #expect(actions.phase(for: item) == .open)
        let failed = await actions.complete(item, enabled: true, origin: .onDeviceChat) { _ in .failed }
        guard case .failed = failed else { Issue.record("Failed save reported success"); return }
        #expect(actions.phase(for: item) == .open)
        var done = false
        let retry = await actions.complete(item, enabled: true, origin: .onDeviceChat) { target in
            ReminderCompletion.set(true, id: target.id, matching: target, read: { (wanted, done) }, save: { done = true; writes += 1 })
        }
        guard case .completed = retry else { Issue.record("The retry didn't tick the row"); return }
        #expect(done && writes == 2 && actions.phase(for: item).isDone)
    }

    @Test("Old cards and invented JSON handles cannot select a reminder by title; the switch and origin still gate live taps")
    @MainActor func refusesBeforeWriting() async throws {
        let old = try JSONDecoder().decode(AnswerCard.self, from: Data(#"{"source":"reminders","sections":[{"kind":"list","body":{"items":[{"text":"Send invoice"},{"text":"Send invoice","reminder":{"id":"fake"}}]}}]}"#.utf8))
        let actions = ReminderCardActions()
        for item in try items(old) {
            let result = await actions.complete(item, enabled: true, origin: .onDeviceChat) { _ in Issue.record("Searched by title"); return .written }
            #expect(result == .failed(ReminderCardActions.needsFreshList))
        }
        let live = try #require(try items(await readCard(rows).card).first)
        let blocked: [(Bool, RequestOrigin)] = [(false, .onDeviceChat), (true, .network(host: "localhost", port: 1)), (true, .scheduledTask(id: UUID()))]
        for (enabled, origin) in blocked {
            let result = await actions.complete(live, enabled: enabled, origin: origin) { _ in Issue.record("Blocked write ran"); return .written }
            guard case .failed = result else { Issue.record("Blocked write reported success"); return }
            #expect(actions.phase(for: live) == .open)
        }
    }
}
