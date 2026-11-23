import Foundation
import Testing
@testable import PocketdKit

@MainActor
@Suite("Brief source revisions")
struct BriefRefreshGateTests {
    enum Change: CaseIterable { case disconnect, revokedInSettings, disconnectAndReconnect }

    @Test("a suspended read cannot publish or supply the model after its source changes", arguments: Change.allCases)
    func suspendedRead(change: Change) async throws {
        typealias Access = TodaySnapshot.Availability
        let gate = BriefRefreshGate<Access>()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (resume, release) = AsyncStream<Void>.makeStream()
        var access = Access.connected
        var reads: [Access] = []
        var published: [TodaySnapshot] = []
        var prompts: [String] = []
        var changes = 0
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let refresh = Task { @MainActor in
            await gate.refresh(force: false, current: { gate.observe(access) { changes += 1 } }, read: { captured in
                reads.append(captured)
                let first = reads.count == 1
                let event = BriefEvent(title: first ? "Stale appointment" : "Fresh appointment",
                                       start: now.addingTimeInterval(600), end: now.addingTimeInterval(1_200))
                let snapshot = TodaySnapshot(generatedAt: now, calendar: captured, reminders: .connected,
                                             events: captured.isReadable ? [event] : [],
                                             dueToday: [BriefReminder(title: "Return library book", due: now)])
                if first {
                    signal.yield(())
                    var wait = resume.makeAsyncIterator()
                    _ = await wait.next()  // a source read that returns even after the switch changed
                }
                return snapshot
            }, publish: { snapshot, _, _ in
                published.append(snapshot)
                let messages = BriefPrompt.messages(snapshot: snapshot, name: nil, now: now,
                                                    calendar: .current, timeOfDay: .morning)
                prompts.append(messages.map(\.content).joined(separator: "\n"))
            })
        }

        var begun = started.makeAsyncIterator()
        _ = await begun.next()
        switch change {
        case .disconnect, .disconnectAndReconnect:
            access = .off
            gate.observe(access, newRevision: true) { changes += 1 }
            if change == .disconnectAndReconnect {
                access = .connected
                gate.observe(access, newRevision: true) { changes += 1 }
            }
        case .revokedInSettings:
            // No notification yet: the live check after the await must catch this.
            access = .refused
        }
        release.yield(())
        await refresh.value

        #expect(reads == [.connected, access], "one fresh read, then the queue drains")
        #expect(changes == (change == .disconnectAndReconnect ? 2 : 1))
        #expect(published.map(\.calendar) == [access])
        let expectedEvents = access.isReadable ? ["Fresh appointment"] : []
        #expect(published.flatMap(\.events).map(\.title) == expectedEvents)
        let prompt = try #require(prompts.first)
        #expect(prompts.count == 1 && !prompt.contains("Stale appointment"))
        #expect(prompt.contains("Return library book"), "the still-connected source does reach the model")
        #expect(!gate.isRefreshing && !gate.isStale)
    }

    @Test("withdrawal cancels the active brief and invalidates a queued delivery even after reconnect")
    func queuedAndActive() async {
        let gate = BriefRefreshGate<Bool>()
        let ticket = gate.observe(true) {}
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (resume, release) = AsyncStream<Void>.makeStream()
        let active = Task { @MainActor in
            signal.yield(())
            var wait = resume.makeAsyncIterator()
            _ = await wait.next()
            return ticket.permitsDelivery(current: { gate.observe(true) {} })
        }
        var begun = started.makeAsyncIterator()
        _ = await begun.next()
        let initiallyPermitted = ticket.permitsDelivery(current: { gate.observe(true) {} })
        #expect(initiallyPermitted)
        gate.observe(false, newRevision: true) { active.cancel() }
        #expect(active.isCancelled)
        let replacement = gate.observe(true, newRevision: true) {}
        release.finish()
        #expect(await active.value == false)
        let oldMayDeliver = ticket.permitsDelivery(current: { replacement })
        let newMayDeliver = replacement.permitsDelivery(current: { replacement })
        #expect(!oldMayDeliver, "uncancelled work carrying the old rows is stale too")
        #expect(newMayDeliver)
    }

    @Test("an opaque Health grant is read again after Settings, never retried in the background")
    func backgroundHealthRead() async {
        let gate = BriefRefreshGate<Bool>()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (resume, release) = AsyncStream<Void>.makeStream()
        var foreground = true
        var samples = [4200]
        var readCount = 0
        var delivered: [[Int]] = []
        func refresh() async {
            await gate.refresh(force: true, current: { foreground ? gate.observe(true) {} : nil }, read: { _ in
                readCount += 1
                let result = samples
                if readCount == 1 {
                    signal.yield(())
                    var wait = resume.makeAsyncIterator()
                    _ = await wait.next()
                }
                return result
            }, publish: { value, _, _ in delivered.append(value) })
        }
        let running = Task { await refresh() }
        var begun = started.makeAsyncIterator()
        _ = await begun.next()
        await refresh()  // a simultaneous manual refresh is also owed, only once
        foreground = false
        gate.observe(true, newRevision: true) {}  // HealthKit's reported access looks identical.
        samples = []
        release.yield(())
        await running.value
        #expect(delivered.isEmpty && readCount == 1 && gate.isStale)
        foreground = true
        await refresh()
        #expect(delivered == [[]] && readCount == 2 && !gate.isStale)
    }
}
