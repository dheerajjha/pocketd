#if DEBUG
import Foundation
import PocketdKit

/// A conversation that puts every card shape on screen, for `-pocketd.previewChat`.
///
/// It exists because of a hard limit rather than a preference: no model that can
/// call a tool fits in a simulator, so on the machine where every screenshot is
/// taken the one screen whose whole job is drawing tool results has nothing to
/// draw. A SwiftUI `#Preview` can fabricate the cards, but a preview is not the
/// app — it has no `AppModel`, no tab bar, no keyboard inset, and it is exactly
/// those three that a screenshot is meant to check.
///
/// So this seeds the real screen with real card values instead. Two rules keep
/// it honest:
///
/// - Every card is built by the same `AnswerCardBuilders` the tools use, from a
///   payload dictionary in the same shape `PersonalDataTools` produces. A card
///   drawn here cannot have a shape the tools cannot make.
/// - The reminder at the end is genuinely written to the simulator's Reminders
///   database, through the same `PersonalDataWrites.createReminder` a question
///   would have gone through. Its Undo is the real one, backed by the real
///   ledger, and pressing it really deletes the reminder — which is the only way
///   to demonstrate the feature on a machine that cannot run the model that
///   would ordinarily cause it.
///
/// Entirely inside `#if DEBUG`, imports included: a Release build has no path
/// through any of this, not even a dead branch.
enum AskPreviewChat {

    /// Whether this launch asked for it.
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.previewChat")
    }

    /// Whether to also draw the two states that only exist mid-generation.
    ///
    /// The thinking orb and the tool offer both live on `AppModel` state that
    /// only `send()` can produce, and `send()` needs a resident model — so on a
    /// simulator they are unreachable, not merely unlikely. This draws them from
    /// fabricated values instead, in the real screen, and they appear together
    /// because that is how they really appear: `send()` decides the offer and
    /// starts the generation in the same breath.
    static var showsPendingStates: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.previewStates")
    }

    /// Once per launch. The app restores the last conversation on bootstrap, and
    /// a second seed would append a duplicate of everything below it.
    @MainActor private static var hasSeeded = false

    @MainActor
    static func seedIfRequested(into model: AppModel) async {
        guard isRequested, !hasSeeded else { return }
        hasSeeded = true

        var messages: [ChatMessage] = []
        messages.append(.user("What's on tomorrow?"))
        messages.append(ChatMessage(
            role: .assistant,
            // Digits, as the brief and the tiles write them: a time spelled
            // out on screen ("at half past six") is one the reader re-reads.
            content: calendarSentence,
            cards: [calendarCard()].compactMap { $0 }
        ))
        messages.append(.user("Anything overdue?"))
        // Deliberately empty. The engine withholds a narration that only
        // repeated the payload — see `NarrationEcho` — and the card has to stand
        // on its own with no empty bubble above it.
        messages.append(ChatMessage(role: .assistant, content: "", cards: [remindersCard()].compactMap { $0 }))
        messages.append(.user("How did I sleep last night?"))
        messages.append(ChatMessage(
            role: .assistant,
            content: "6h 36m — a little under your usual, and still in your normal range.",
            cards: [healthCard()].compactMap { $0 }
        ))

        model.conversation = messages

        // Last, and after the transcript is on screen, because it touches
        // EventKit and may take a moment.
        if let written = await writeARealReminder(clearingWith: model) {
            model.conversation.append(.user("Remind me to call the dentist at 4"))
            model.conversation.append(ChatMessage(role: .assistant, content: "", cards: [written]))
        }
    }

    // MARK: - The three read shapes

    /// The narration above the calendar card. Also `TourStage`'s.
    static var calendarSentence: String {
        "Two things tomorrow: the design review at \(Format.time(tomorrowAt(10, 0))), then yoga at \(Format.time(tomorrowAt(18, 30)))."
    }

    private static func tomorrowAt(_ hour: Int, _ minute: Int) -> Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: DemoClock.now) ?? DemoClock.now
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow) ?? tomorrow
    }

    static func calendarCard() -> AnswerCard? {
        func at(_ hour: Int, _ minute: Int) -> Date { tomorrowAt(hour, minute) }
        // The same two events `DemoSeed` puts in tomorrow, so that a capture of
        // this card and a capture of the Today tiles describe one calendar.
        let events: [[String: any Sendable]] = [
            [
                "title": "Design review",
                "all_day": false,
                "start": PersonalDataFormat.moment(at(10, 0)),
                "end": PersonalDataFormat.moment(at(11, 0)),
            ],
            [
                "title": "Yoga",
                "all_day": false,
                "start": PersonalDataFormat.moment(at(18, 30)),
                "end": PersonalDataFormat.moment(at(20, 0)),
            ],
        ]
        let payload: [String: any Sendable] = ["events": events]
        return AnswerCardBuilders.calendar(#"{"action":"list","range":"tomorrow"}"#, payload)
    }

    /// The titles are `DemoSeed`'s own, deliberately.
    ///
    /// The circles on a reminder card tick a *real* reminder off by title, so a
    /// card built from invented names would draw three controls that can only
    /// ever report "I could not find that" — a demonstration of the failure path
    /// dressed up as the feature. With the seeded names they work.
    ///
    /// Overdue means overdue: only the reminder that slipped yesterday, the
    /// one the Due tile counts. The card used to list today's and tomorrow's
    /// under an OVERDUE heading as well.
    static func remindersCard() -> AnswerCard? {
        let rows: [[String: any Sendable]] = [
            ["title": "Submit expenses", "due": due(dayOffset: -1, hour: 18)],
        ]
        let payload: [String: any Sendable] = ["reminders": rows]
        return AnswerCardBuilders.reminders(#"{"action":"list","filter":"overdue"}"#, payload)
    }

    /// The due date exactly as the reminders tool writes it — this phone's own
    /// locale, so "6:00 PM" where the phone says 6 PM. The fixture used to pin
    /// British English and print "18:00" on every screenshot.
    private static func due(dayOffset: Int, hour: Int, minute: Int = 0) -> String {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: DemoClock.now) ?? DemoClock.now
        let moment = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        return PersonalDataFormat.moment(moment)
    }

    /// The demo health figures (`DemoDay`: 6h 36m last night against a usual
    /// 7h 5m), in the clause shape `HealthSummary.reading` writes.
    static func healthCard() -> AnswerCard? {
        let night = Calendar.current.date(byAdding: .day, value: -1, to: DemoClock.now) ?? DemoClock.now
        let when = PersonalDataFormat.day(night)
        let readings: [String] = [
            "Sleep: 6h 36m on \(when) — 7% below your 28-day average of 7h 5m, in your usual range.",
            "Resting heart rate: 58 bpm on \(when), against a 28-day average of 57 bpm — in your usual range.",
        ]
        let notable: [String] = ["Three nights over seven hours this week, the most in a month."]
        let payload: [String: any Sendable] = ["readings": readings, "notable": notable]
        return AnswerCardBuilders.health(#"{"focus":"sleep"}"#, payload)
    }

    // MARK: - One real write

    /// Files a reminder the way a question would, so the card that reports it
    /// carries a real Undo.
    ///
    /// Through `PersonalDataWrites` rather than straight to `EventAccess`: the
    /// duplicate check, the past-time roll-forward and the confirmation sentence
    /// are all part of what the card shows, and a seed that skipped them would
    /// be drawing a shape the app never produces. The write is recorded in
    /// `EventAccess`'s ledger by the save itself, which is what makes the pill
    /// appear and work.
    ///
    /// The tick-off first is what makes a second run behave like a first one.
    /// `createReminder` refuses to file the same thing twice — correctly, it is
    /// the model calling itself in a loop that the check exists for — and on a
    /// relaunch that refusal would produce a card saying "already on the list"
    /// with nothing to undo, which is not the state this seed is for.
    @MainActor
    static func writeARealReminder(
        _ title: String = "Call the dentist",
        when: String = "4pm today",
        clearingWith model: AppModel
    ) async -> AnswerCard? {
        _ = await model.completeReminder(named: title)
        let payload = await PersonalDataWrites.createReminder(
            title: title,
            when: when,
            origin: .onDeviceChat,
            existing: { await EventAccess.shared.reminders(in: DateWindow(start: nil, end: nil)) },
            write: { await EventAccess.shared.createReminder($0) }
        )
        return AnswerCardBuilders.reminders(#"{"action":"create"}"#, payload)
    }
}
#endif
