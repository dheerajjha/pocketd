import Foundation
import PocketdKit

/// Reads the day for a brief routine's notification, wherever the routine is
/// collected.
///
/// One function for both places that happens — a background refresh with no
/// app around it, and a foreground sweep — so the sentence on the banner and
/// the line on the routine's card are one sentence, read one way. And both
/// halves are Today's own: `DayReader.snapshot` is the read Today makes, and
/// `BriefPrompt.notificationSentence` is the brief's own clauses with the
/// titles left out (a banner is read by whoever picks the phone up). A third
/// reader of "today", with its own idea of overdue, is how v2 came to show a
/// routine card and a Today tile that disagreed.
///
/// What may be read is decided from the user's switches as persisted, and
/// iOS's answer, folded by the same `AbilityState` rules Today uses: a brief
/// is the Today brief arriving early, and Today does not read a calendar the
/// person switched off in Pocketd. Read from defaults rather than from
/// `AppModel` because a background refresh has no `AppModel`; the app writes
/// those keys every time a switch moves. Nothing here asks iOS for anything.
enum BriefNotice {

    /// The banner's second line, or `nil` when nothing could be read.
    static func sentence(now: Date, calendar: Calendar) async -> String? {
        let snapshot = await DayReader.snapshot(now: now, calendar: calendar, access: access())
        return BriefPrompt.notificationSentence(snapshot: snapshot, now: now, calendar: calendar)
    }

    /// What Today would be allowed to read right now, without `AppModel`.
    ///
    /// Health is read when its switch is on. On a locked phone its store is
    /// encrypted and the read comes back empty, so a background brief simply
    /// has no sleep clause; in the foreground it has one, as Today does.
    static func access() -> DayReader.Access {
        let defaults = UserDefaults.standard
        func personal(_ ability: Ability, _ entity: PersonalDataEntity, key: String) -> TodaySnapshot.Availability {
            .of(AbilityState.of(
                ability,
                enabled: defaults.bool(forKey: key),
                grant: AbilityGrant(EventAccess.authorization(for: entity))
            ))
        }
        let health: TodaySnapshot.Availability = HealthAccess.isAvailable
            ? .of(AbilityState.of(.health, enabled: defaults.bool(forKey: AppModel.Keys.healthTools), grant: .neverReported))
            : .unavailable
        return DayReader.Access(
            calendar: personal(.calendar, .calendar, key: AppModel.Keys.calendarTools),
            reminders: personal(.reminders, .reminders, key: AppModel.Keys.reminderTools),
            health: health
        )
    }

    /// The run a brief files: what its banner said, or that it had nothing to
    /// add to "your brief is ready".
    ///
    /// `.nothingToReport` rather than a failure when nothing could be read.
    /// The brief still arrived — Today writes it, and says what to connect —
    /// so the routine did its job; there was only no sentence for the lock
    /// screen.
    static func run(sentence: String?, firing: Date, ranAt: Date, context: ExecutionContext) -> TaskRun {
        guard let sentence else {
            return .nothingToReport(firing: firing, ranAt: ranAt, context: context)
        }
        // `Untrusted` though it carries no titles: it is built from rows other
        // people wrote, and a stored run record is read back into later
        // prompts. The factory takes nothing else, which is the point of it.
        return .reported(firing: firing, ranAt: ranAt, context: context, output: Untrusted(sentence))
    }
}
