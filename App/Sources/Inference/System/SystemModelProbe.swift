#if DEBUG
import Foundation
import os
import PocketdKit
import UIKit

/// `-pocketd.fmProbe`: drives the built-in brain end to end on a simulator or a
/// phone, with no UI and without going through `AppModel`, and writes what
/// happened to `Library/Caches/fm-probe.txt` in the app's data container.
///
/// It exists because the app target has no test bundle, and the parts of the
/// built-in brain that matter most — that Apple's model is reachable at all,
/// that it calls the real calendar tool against a real EventKit store, that a
/// write lands in the Undo ledger, that a change after a lookup is refused,
/// that Stop frees the engine — can only be seen in a running app. Pair it with
/// `-pocketd.seedDemo` and granted Calendar and Reminders:
///
///     xcrun simctl privacy <udid> grant calendar dev.pocketd.app
///     xcrun simctl privacy <udid> grant reminders dev.pocketd.app
///     xcrun simctl launch <udid> dev.pocketd.app -pocketd.seedDemo -pocketd.skipIntro -pocketd.fmProbe
///     cat "$(xcrun simctl get_app_container <udid> dev.pocketd.app data)/Library/Caches/fm-probe.txt"
///
/// A write the probe makes is taken back through the same ledger Undo uses, so
/// a run leaves the seeded store as it found it.
enum SystemModelProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.fmProbe")
    }

    /// One answer that behaves as if Apple's filter declined it, before the
    /// model is asked. Set only by the probe, consumed by the next answer.
    private static let forcedDecline = OSAllocatedUnfairLock(initialState: false)

    static func forceDeclineOnce() { forcedDecline.withLock { $0 = true } }

    static func takeForcedDecline() -> Bool {
        forcedDecline.withLock { pending in
            defer { pending = false }
            return pending
        }
    }

    @MainActor
    static func runIfRequested() {
        guard isRequested else { return }
        let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        Task.detached(priority: .userInitiated) { await run(system: system) }
    }

    static func run(system: String) async {
        let log = ProbeLog()
        await log.line("fm-probe start · \(system) · instructions v\(SystemModelPlan.instructionsVersion)")
        await log.line("availability=\(SystemModelEngine.availability.rawValue) context=\(SystemModelEngine.contextTokens) variant=\(SystemModelEngine.variantName ?? "n/a (iOS < 27)")")
        await log.line("calendar=\(EventAccess.authorization(for: .calendar)) reminders=\(EventAccess.authorization(for: .reminders))")

        // The demo seed runs inside `AppModel.bootstrap`, alongside this.
        let today = Calendar.current.dateInterval(of: .day, for: Date()) ?? DateInterval(start: Date(), duration: 86_400)
        var seeded = 0
        for _ in 0..<40 {
            if case let .rows(rows, _) = await EventAccess.shared.events(in: today), !rows.isEmpty {
                seeded = rows.count
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await log.line("events today in EventKit: \(seeded)")

        let engine = SystemModelEngine()
        await engine.updateAbilities(calendar: true, reminders: true, health: true)
        do {
            try await engine.load(model: .builtIn)
            await log.line("load ok · loadedModel=\(await engine.loadedModel()?.id ?? "nil") · toolGate=\(await engine.toolGate)")
        } catch {
            await log.line("load FAILED: \(error)")
        }
        guard SystemModelEngine.availability == .available else {
            await log.line("Apple's model is not available here; stopping. PROBE DONE")
            return
        }

        _ = await ask(engine, "What's on today?", log: log)
        _ = await ask(engine, "Anything overdue?", log: log)
        _ = await ask(engine, "How did I sleep last night?", log: log)

        // A write, then the same Undo the conversation offers.
        let before = await EventAccess.shared.recentWrites().count
        let cards = await ask(engine, "Remind me to water the ferns tomorrow at 8am", log: log)
        let writes = await EventAccess.shared.recentWrites()
        await log.line("writes in ledger: \(before) → \(writes.count)")
        for card in cards {
            if let write = WriteUndo.offer(for: card, from: writes) {
                let undone = await EventAccess.shared.undo(write)
                await log.line("Undo offered on \"\(card.lede ?? "")\" → undo \(undone)")
            }
        }

        // A change asked for after a lookup must be refused.
        let beforeChained = await EventAccess.shared.recentWrites().count
        _ = await ask(engine, "Look at my calendar for today, then add a reminder to prepare for the first event.", log: log)
        let afterChained = await EventAccess.shared.recentWrites()
        await log.line("chained request wrote \(afterChained.count - beforeChained) item(s) (expected 0 unless it was the first step)")
        for write in afterChained.prefix(afterChained.count - beforeChained) {
            _ = await EventAccess.shared.undo(write)
        }

        await stopTest(engine, log: log)
        await historyTest(engine, log: log)
        await declineTests(engine, log: log)
        await phoneBrainTest(log: log)

        await log.line("diagnostics:")
        for note in DiagnosticLog.snapshot().suffix(40) {
            await log.line("  \(note.event)")
        }
        await log.line("PROBE DONE")
    }

    /// One question, as the conversation sends it, with every event logged.
    @discardableResult
    static func ask(_ engine: SystemModelEngine, _ question: String, history: [ChatMessage] = [], log: ProbeLog) async -> [AnswerCard] {
        // Built as `AppModel.send()` builds it, `/no_think` included, so the
        // probe also checks that the reasoning switch never reaches the model.
        var messages: [ChatMessage] = [.system("You are a helpful assistant.")] + history + [.user(question + "\n/no_think")]
        messages = DateContext.inject(into: messages)
        let request = GenerationRequest(
            modelID: ModelRecord.builtInID,
            messages: messages,
            options: GenerationOptions(maxTokens: 4096),
            origin: .onDeviceChat
        )
        await log.line("Q: \(question)")
        let started = Date()
        var firstToken: TimeInterval?
        var text = ""
        var cards: [AnswerCard] = []
        do {
            for try await event in try await engine.generate(request) {
                let at = String(format: "%.2fs", Date().timeIntervalSince(started))
                switch event {
                case let .token(chunk):
                    if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                    text += chunk
                case let .toolCallStarted(name):
                    await log.line("  [\(at)] toolCallStarted \(name)")
                case let .answerCard(card):
                    cards.append(card)
                    await log.line("  [\(at)] answerCard \(card.source ?? "?") · \"\(card.title ?? "-")\" · \(card.lede ?? "-") · sections=\(card.sections.count)")
                case let .finished(reason, usage):
                    await log.line("  [\(at)] finished \(reason) · first token \(firstToken.map { String(format: "%.2fs", $0) } ?? "none") · ~\(usage.completionTokens) tokens")
                }
            }
            await log.line("A: \(text)")
        } catch {
            await log.line("  THREW after \(String(format: "%.2fs", Date().timeIntervalSince(started))): \(error) · text before it: \"\(text)\"")
        }
        return cards
    }

    /// Stop must stop: cancel mid-answer, then time the next question.
    static func stopTest(_ engine: SystemModelEngine, log: ProbeLog) async {
        let request = GenerationRequest(
            modelID: ModelRecord.builtInID,
            messages: [.user("Write a 600-word story about a lighthouse keeper.")],
            options: GenerationOptions(maxTokens: 4096),
            origin: .onDeviceChat
        )
        await log.line("Q: (stop test) long story, cancelled after 1.5 s")
        let reader = Task {
            var characters = 0
            do {
                for try await event in try await engine.generate(request) {
                    if case let .token(chunk) = event { characters += chunk.count }
                }
            } catch {}
            return characters
        }
        try? await Task.sleep(for: .milliseconds(1500))
        let cancelled = Date()
        reader.cancel()
        let characters = await reader.value
        await log.line("  reader ended \(String(format: "%.3fs", Date().timeIntervalSince(cancelled))) after cancel, \(characters) characters in")
        let next = Date()
        _ = await ask(engine, "Say hello in three words.", log: log)
        await log.line("  next answer complete \(String(format: "%.2fs", Date().timeIntervalSince(next))) after it was asked")
    }

    /// A conversation far past 4,096 tokens still answers, from its newest turns.
    static func historyTest(_ engine: SystemModelEngine, log: ProbeLog) async {
        var history: [ChatMessage] = []
        for index in 0..<60 {
            history.append(.user("Tell me fact number \(index) about the ocean, in two sentences."))
            history.append(.assistant("Fact \(index): the ocean covers most of the planet and holds most of its water. It is deep, cold and mostly unexplored."))
        }
        history.append(.user("My name is Ravi."))
        history.append(.assistant("Nice to meet you, Ravi."))
        let plan = try? SystemModelPlan.make(
            for: GenerationRequest(modelID: "", messages: history + [.user("What is my name?")], origin: .onDeviceChat),
            enabled: [.calendar, .reminders, .health]
        )
        await log.line("history test: \(history.count) turns, plan keeps \(plan?.history.count ?? -1), drops \(plan?.droppedTurns ?? -1)")
        _ = await ask(engine, "What is my name? One word.", history: history, log: log)
    }
}

extension SystemModelProbe {
    /// Apple's filter declining ordinary diary words, three ways: after a card
    /// (the card stands), before anything with a downloaded brain loaded (the
    /// question goes to it — `EchoEngine` stands in and repeats the question),
    /// and before anything with no fallback (one plain sentence).
    static func declineTests(_ engine: SystemModelEngine, log: ProbeLog) async {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
        let before = await EventAccess.shared.recentWrites().count
        let made = await EventAccess.shared.createEvent(NewEvent(
            title: "Shoot the product photos", start: start, end: start.addingTimeInterval(1800)
        ))
        await log.line("decline test: added \"Shoot the product photos\" tonight → \(made)")
        _ = await ask(engine, "What's on my calendar today?", log: log)
        let added = await EventAccess.shared.recentWrites()
        for write in added.prefix(added.count - before) { _ = await EventAccess.shared.undo(write) }

        let question = "My calendar says 'Colonoscopy prep - start laxative 6pm'. What do I need to do tonight?"
        let toolless = SystemModelEngine(fallback: EchoEngine())
        try? await toolless.load(model: .builtIn)
        // Apple's filter is not deterministic: the same question passed on one
        // run and tripped on the next. Asked until it trips, or four times.
        for attempt in 1...4 {
            await log.line("decline test: no tools, EchoEngine as the loaded downloaded brain (attempt \(attempt))")
            let cards = await ask(toolless, question, log: log)
            _ = cards
            if DiagnosticLog.snapshot().contains(where: { $0.event == .failure(area: .model, code: "fm.fallbackToDownloaded") }) {
                await log.line("  ↳ relayed to the downloaded brain (EchoEngine repeats the question)")
                break
            }
        }

        let alone = SystemModelEngine()
        try? await alone.load(model: .builtIn)
        await log.line("decline test: no tools, no fallback")
        _ = await ask(alone, question, log: log)

        // The same two paths with the decline forced, so they are seen every
        // run: relayed to the loaded downloaded brain (EchoEngine repeats the
        // question back), and with no fallback, one plain sentence.
        forceDeclineOnce()
        await log.line("forced decline, EchoEngine loaded as the downloaded brain:")
        _ = await ask(toolless, "Is the relay working?", log: log)
        forceDeclineOnce()
        await log.line("forced decline, no downloaded brain:")
        _ = await ask(alone, "Is the relay working?", log: log)
    }

    /// The facade the phone's generations will go through, choosing Apple's model.
    static func phoneBrainTest(log: ProbeLog) async {
        let downloaded = LlamaEngine(fileURL: { _ in URL(fileURLWithPath: "/dev/null") })
        let phone = PhoneBrain(downloaded: downloaded)
        await phone.use(.builtIn)
        await phone.updateAbilities(calendar: true, reminders: true, health: false, registrations: [])
        do {
            try await phone.load(model: .builtIn)
        } catch {
            await log.line("PhoneBrain load FAILED: \(error)")
        }
        await log.line("PhoneBrain: current=\(String(describing: await phone.current)) loaded=\(await phone.loadedModel()?.id ?? "nil") toolGate=\(await phone.toolGate)")
        let request = GenerationRequest(
            modelID: ModelRecord.builtInID,
            messages: DateContext.inject(into: [.user("Anything due today?")]),
            origin: .onDeviceChat
        )
        var text = ""
        var cards = 0
        do {
            for try await event in try await phone.generate(request) {
                if case let .token(chunk) = event { text += chunk }
                if case .answerCard = event { cards += 1 }
            }
            await log.line("PhoneBrain answer (\(cards) card): \(text)")
        } catch {
            await log.line("PhoneBrain THREW: \(error)")
        }
        await phone.use(.downloaded(id: "smollm2-360m"))
        await log.line("PhoneBrain after switching away: loaded=\(await phone.loadedModel()?.id ?? "nil") built-in loaded=\(await phone.builtIn.loadedModel()?.id ?? "nil")")
    }
}

/// Appends to `Library/Caches/fm-probe.txt` and mirrors each line to the
/// console.
actor ProbeLog {
    private let url: URL?
    private let started = Date()

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        url = caches?.appendingPathComponent("fm-probe.txt")
        if let url { try? Data().write(to: url) }
    }

    func line(_ text: String) {
        let stamped = String(format: "[%7.2fs] ", Date().timeIntervalSince(started)) + text
        print("FMPROBE " + stamped)
        guard let url, let data = (stamped + "\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
#endif
