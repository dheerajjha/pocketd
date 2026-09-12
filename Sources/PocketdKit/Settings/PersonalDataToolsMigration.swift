import Foundation

/// Turns the one "read calendar and reminders" switch into two independent
/// ones, once per install, without ever putting back a capability the user has
/// since switched off.
///
/// It lives here rather than beside `AppModel` because the app target has no
/// test bundle, and the case that actually breaks a migration like this is not
/// reachable by hand: it needs an install carrying the old key, an upgrade, two
/// taps and a relaunch. As a pure function of what is on disk, that case is
/// three optional booleans.
///
/// The caller owns the I/O. Nothing here reads or writes `UserDefaults`, which
/// is what keeps every case below expressible as a value rather than as a
/// simulator with a particular history.
public enum PersonalDataToolsMigration {

    /// What is stored right now, with "never written" kept distinct from
    /// `false`.
    ///
    /// That distinction is the entire mechanism. `UserDefaults.bool(forKey:)`
    /// reads an absent key as `false`, so a migration built on it cannot tell
    /// somebody who has never seen the new switches from somebody who has just
    /// turned both of them off — and it re-enables the calendar for the second
    /// person on their next launch. Read these with `object(forKey:) as? Bool`.
    public struct Stored: Sendable, Equatable {
        /// `pocketd.personalDataTools`, the switch that governed both tools.
        public var legacy: Bool?
        public var calendar: Bool?
        public var reminders: Bool?

        public init(legacy: Bool?, calendar: Bool?, reminders: Bool?) {
            self.legacy = legacy
            self.calendar = calendar
            self.reminders = reminders
        }
    }

    /// The values to launch with, and whether the store still has work to do.
    public struct Outcome: Sendable, Equatable {
        public var calendar: Bool
        public var reminders: Bool

        /// Whether the caller must write both new keys and then remove the old
        /// one.
        ///
        /// True exactly while the old key is still on disk, so the write
        /// happens on the upgrade launch and on no launch after it. Reporting
        /// it on every launch would be harmless — the values would be the same
        /// — but it would mean a fresh install writes two settings nobody has
        /// touched, and it would leave the code with no way to say that this is
        /// a one-off.
        public var shouldPersist: Bool

        public init(calendar: Bool, reminders: Bool, shouldPersist: Bool) {
            self.calendar = calendar
            self.reminders = reminders
            self.shouldPersist = shouldPersist
        }
    }

    /// What the two switches should be, given everything the store knows.
    ///
    /// Either new key existing means the split has already happened, and from
    /// then on the new keys are the only answer — including when a legacy key
    /// is sitting beside them, which is the state left behind by a process
    /// killed between the write and the removal. Deferring to the legacy value
    /// there is precisely the bug: turn both switches off, relaunch, and the
    /// calendar the user just revoked comes back on, having asked iOS for
    /// permission again on the way.
    public static func resolve(_ stored: Stored) -> Outcome {
        // The old key is what makes this runnable a second time, so its
        // presence is exactly the condition for there being work left to do.
        let shouldPersist = stored.legacy != nil

        if stored.calendar != nil || stored.reminders != nil {
            return Outcome(
                calendar: stored.calendar ?? false,
                reminders: stored.reminders ?? false,
                shouldPersist: shouldPersist
            )
        }

        // Both tools, because the old switch registered both: a user who had it
        // on had a calendar and a reminder tool, and an upgrade that silently
        // took one of them away is a regression dressed as a feature. Somebody
        // who wants only one now has a switch to say so.
        let inherited = stored.legacy ?? false
        return Outcome(
            calendar: inherited,
            reminders: inherited,
            shouldPersist: shouldPersist
        )
    }
}
