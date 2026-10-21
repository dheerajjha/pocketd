import Foundation
import PocketdKit

/// Today's four tiles and the four pages behind them.
///
/// What a screen calls, and nothing a screen has to decide. The verdicts come
/// from the snapshot the brief was built on — so the tiles and the paragraph
/// above them describe one reading of the day — and the pages read EventKit and
/// HealthKit directly through `DayReader`, with the same availability the tile
/// that opened them had. All of it is reads and Kit rules; no model is involved
/// anywhere in this file, which is what lets Today be complete on a phone with
/// no brain and on screen before one has loaded.
///
/// No stored state: a page holds what it was handed in its own `@State` and
/// asks again on appear or pull to refresh. The reads are a few milliseconds,
/// and a cache here would be one more thing to invalidate when a reminder is
/// ticked off in the Reminders app.
@MainActor
extension AppModel {

    // MARK: - Tiles

    /// Up next, Due, Sleep and Activity, in grid order.
    ///
    /// A function of the clock as well as of the snapshot: "In 3h 19m" and
    /// "Call the plumber was due at 5:00 PM" move on without a re-read, so a
    /// view that redraws once a minute stays right.
    func tileVerdicts(now: Date = DemoClock.now) -> [TileVerdict] {
        TodayVerdicts.all(briefing.snapshot, now: now)
    }

    func tileVerdict(_ tile: TileVerdict.Tile, now: Date = DemoClock.now) -> TileVerdict {
        switch tile {
        case .upNext: TodayVerdicts.upNext(briefing.snapshot, now: now)
        case .due: TodayVerdicts.due(briefing.snapshot, now: now)
        case .sleep: TodayVerdicts.sleep(briefing.snapshot)
        case .activity: TodayVerdicts.activity(briefing.snapshot)
        }
    }

    /// The line a "Your morning brief is ready." notification can carry: the
    /// first sentence after the greeting, from the current snapshot.
    func briefFirstSentence(now: Date = DemoClock.now) -> String {
        BriefPrompt.firstSentence(snapshot: briefing.snapshot, now: now)
    }

    // MARK: - Pages

    /// Your day: NOW · LATER TODAY · TOMORROW, with the summary and the chip.
    func yourDay(now: Date = DemoClock.now) async -> DayAgenda {
        await DayReader.agenda(now: now, availability: briefing.snapshot.calendar)
    }

    /// Reminders: OVERDUE · TODAY · LATER.
    func reminderAgenda(now: Date = DemoClock.now) async -> ReminderAgenda {
        await DayReader.reminders(now: now, availability: briefing.snapshot.reminders)
    }

    /// Sleep: USUAL | LAST NIGHT, the delta sentence, the last seven nights.
    func sleepDetail(now: Date = DemoClock.now) async -> SleepDetail {
        await DayReader.sleep(now: now, availability: briefing.snapshot.health)
    }

    /// Activity: TODAY | USUAL BY NOW, the sentence, the last seven days.
    func activityDetail(now: Date = DemoClock.now) async -> ActivityDetail {
        await DayReader.activity(now: now, availability: briefing.snapshot.health)
    }

    // MARK: - Ticking one off

    /// Ticks a reminder off from its circle on the Reminders page.
    ///
    /// By identifier, so the reminder completed is the one the person tapped —
    /// the card in the conversation has only a title and has to search, this
    /// page does not. Gated on the on-device origin like every other write: the
    /// circle is on this phone's screen, which is what that origin means.
    ///
    /// - Returns: the completion, for the toast and its Undo, or nil when the
    ///   tick did not land (the reminder was deleted elsewhere, or access was
    ///   withdrawn); the page then re-reads and the row is simply gone or back.
    func completeReminder(id: String, title: String) async -> ReminderCompletion? {
        guard RequestOrigin.onDeviceChat.mayWritePersonalData else { return nil }
        guard await EventAccess.shared.completeReminder(identifier: id) == .written else { return nil }
        // The Due tile and the brief count this reminder until the day is read
        // again, and they are one swipe away.
        dayMayHaveChanged()
        return ReminderCompletion(reminderID: id, title: title)
    }

    /// Puts a ticked-off reminder back, from the toast's Undo.
    ///
    /// Un-ticks; never deletes. See `EventAccess.uncompleteReminder`. Refused
    /// once the five-minute window has closed, like every Undo in the app.
    func undoCompletion(_ completion: ReminderCompletion, now: Date = Date()) async -> Bool {
        guard RequestOrigin.onDeviceChat.mayWritePersonalData, completion.canUndo(now: now) else { return false }
        guard await EventAccess.shared.uncompleteReminder(identifier: completion.reminderID) == .written else { return false }
        dayMayHaveChanged()
        return true
    }
}
