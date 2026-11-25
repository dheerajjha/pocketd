import Foundation
import PocketdKit

/// The three things the Ask screen does to the user's own data directly, rather
/// than through the model.
///
/// All three are the same act from the user's side — a tap on a card that is
/// already on screen, about an item they are already looking at — and all three
/// go through the code the tools go through rather than around it. A check
/// circle that called `EKEventStore` itself would be a second write path with
/// its own idea of what is allowed, and the whole argument of `RequestOrigin`
/// is that there is exactly one.
@MainActor
extension AppModel {

    // MARK: - Ticking one off

    /// A phone tap addresses the row EventKit returned, never a fresh title search.
    func completeReminder(_ item: AnswerCard.Item, using actions: ReminderCardActions) async -> ReminderCardActions.Outcome {
        let result = await actions.complete(item, enabled: reminderToolsEnabled, origin: .onDeviceChat) { reminder in
            await EventAccess.shared.completeReminder(reminder)
        }
        if case .completed = result { dayMayHaveChanged() }
        return result
    }

    // MARK: - Taking a write back

    /// Everything this app has added to the calendar or the reminders list
    /// inside the undo window, newest first.
    func recentWrites() async -> [PersonalDataWrite] {
        await EventAccess.shared.recentWrites()
    }

    /// Removes something the assistant added minutes ago.
    ///
    /// The one destructive path in the app, and it is bounded on every side:
    /// only items this app created, only by an identifier it recorded itself,
    /// only within `WriteUndo.window`, and only from a card on screen. See
    /// `EventAccess.undo(_:)` for the origin gate.
    func undoWrite(_ write: PersonalDataWrite) async -> Bool {
        await EventAccess.shared.undo(write) == .written
    }

    // MARK: - Whether a source is on

    /// Whether the ability a suggestion needs is switched on.
    ///
    /// Named apart from `isEnabled(_ entity:)`, which answers the same question
    /// about the narrower `PersonalDataEntity`. Two overloads of one name over
    /// two enums that both have a `calendar` case is how a call site ends up
    /// meaning the other one.
    func isOn(_ ability: Ability) -> Bool {
        switch ability {
        case .calendar: calendarToolsEnabled
        case .reminders: reminderToolsEnabled
        case .health: healthToolsEnabled
        case .localServer: serverShouldRun
        }
    }
}
