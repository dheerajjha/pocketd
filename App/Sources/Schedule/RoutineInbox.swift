import Foundation
import Observation

/// When the person last looked at their routines' results.
///
/// The only state Routines keeps outside the task store, and it is about the
/// person rather than the schedule: Today's ⏰ carries a badge only while a
/// routine has said something nobody has read (spec §3.1), and "read" is a
/// fact about a screen having been open, which no run record can know.
///
/// Its own observable rather than a defaults read inside a computed property,
/// because a badge has to disappear the moment Routines is opened, and nothing
/// redraws for a `UserDefaults` write.
@MainActor
@Observable
final class RoutineInbox {

    static let shared = RoutineInbox()

    private static let key = "pocketd.routines.lastSeen"

    /// `nil` until Routines has been opened once. Nothing counts as unread
    /// before that: a person who has never opened the screen has not been
    /// promised anything by a badge yet, and an upgrade should not greet them
    /// with a count of everything their routines ever said.
    private(set) var lastSeen: Date?

    private init() {
        lastSeen = UserDefaults.standard.object(forKey: Self.key) as? Date
    }

    func markSeen(at moment: Date = Date()) {
        lastSeen = moment
        UserDefaults.standard.set(moment, forKey: Self.key)
    }
}
