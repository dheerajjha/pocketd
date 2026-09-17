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

    /// Marks an open reminder done, from the circle on a reminder card.
    ///
    /// By title rather than by identifier, which is not a shortcut: a card's
    /// rows carry no identifiers on purpose — `PersonalDataTools.describe` never
    /// puts one in the payload, because an opaque handle costs prompt tokens and
    /// tells the model nothing — so the title is genuinely all the card has.
    /// Going through `PersonalDataWrites.completeReminder` rather than
    /// re-implementing the search is what keeps the two halves honest: it
    /// refuses an ambiguous title instead of guessing, it refuses a caller that
    /// may not write, and it completes rather than deletes.
    ///
    /// - Returns: one sentence for the person who tapped, and whether the tick
    ///   actually landed.
    func completeReminder(named title: String) async -> (sentence: String, completed: Bool) {
        let payload = await PersonalDataWrites.completeReminder(
            title: title,
            // The button is on this phone's screen, which is what this origin
            // means. Nothing else can reach this method.
            origin: .onDeviceChat,
            existing: { await EventAccess.shared.reminders(in: DateWindow(start: nil, end: nil)) },
            complete: { row in
                guard let identifier = row.identifier else { return .failed }
                return await EventAccess.shared.completeReminder(identifier: identifier)
            }
        )
        let sentence = payload["text"] as? String ?? "That could not be ticked off."
        return (sentence, payload["completed"] as? Bool == true)
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

    // MARK: - Turning an ability on from a card

    /// Switches on what a suggestion or an offer needs, from where it was asked.
    ///
    /// The same two lines `acceptToolOffer()` runs, reachable without an offer
    /// in hand: a suggestion row on the empty state knows which ability it
    /// wants, and there is no `ToolOffer` to accept because nobody has asked
    /// anything yet. Flipping the switch is all it does — `applyPersonalDataTools`
    /// is what then asks iOS, so the permission sheet appears from the same
    /// place it always did.
    func enableAbility(_ ability: Ability, source: AbilitySource = .chatOffer) {
        switch ability {
        case .calendar: calendarToolsEnabled = true
        case .reminders: reminderToolsEnabled = true
        case .health: healthToolsEnabled = true
        // Never offered here. No sentence anybody types at an assistant is a
        // request for a listening socket — see `ToolOffer.ability`.
        case .localServer: return
        }
        record(.abilityEnabled(ability: ability.rawValue, source: source))
    }

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
