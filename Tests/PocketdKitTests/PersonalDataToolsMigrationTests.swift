import Foundation
import Testing
@testable import PocketdKit

/// One switch became two, and the interesting part is not the upgrade — it is
/// the launch after the user has used the new switches.
///
/// A migration written as "if the old key was on and the new ones are off, turn
/// them on" passes the upgrade case and is still wrong: nothing in it stops
/// running, so the first relaunch after somebody turns both capabilities off
/// re-registers both tools and puts the iOS permission prompt back on screen
/// for a calendar they have just revoked.
@Suite("Splitting the personal data switch in two")
struct PersonalDataToolsMigrationTests {

    @Test("someone who had the old switch on gets both capabilities")
    func oldSwitchOn() {
        let outcome = PersonalDataToolsMigration.resolve(
            .init(legacy: true, calendar: nil, reminders: nil)
        )
        #expect(outcome.calendar)
        #expect(outcome.reminders)
        // The old key has to go, or every case below has to keep arguing with
        // it.
        #expect(outcome.shouldPersist)
    }

    @Test("someone who had the old switch off gets neither")
    func oldSwitchOff() {
        let outcome = PersonalDataToolsMigration.resolve(
            .init(legacy: false, calendar: nil, reminders: nil)
        )
        #expect(outcome.calendar == false)
        #expect(outcome.reminders == false)
        // Still a write: the old key exists, and leaving it there leaves the
        // migration able to run again.
        #expect(outcome.shouldPersist)
    }

    @Test("a fresh install has nothing to migrate and writes nothing")
    func freshInstall() {
        let outcome = PersonalDataToolsMigration.resolve(
            .init(legacy: nil, calendar: nil, reminders: nil)
        )
        #expect(outcome.calendar == false)
        #expect(outcome.reminders == false)
        #expect(outcome.shouldPersist == false)
    }

    @Test("the second launch after an upgrade leaves the migrated values alone")
    func alreadyMigrated() {
        let outcome = PersonalDataToolsMigration.resolve(
            .init(legacy: nil, calendar: true, reminders: true)
        )
        #expect(outcome.calendar)
        #expect(outcome.reminders)
        #expect(outcome.shouldPersist == false)
    }

    /// The case a naive migration gets wrong, and the reason this type exists.
    ///
    /// The user upgrades with the old switch on, decides they want neither, and
    /// turns both off. Both new keys now read `false` — and `false` is also what
    /// an absent key reads as, so a migration that asks "are both off?" cannot
    /// tell this apart from the upgrade it has already performed, and the next
    /// cold start helpfully turns the calendar and reminders back on, asking
    /// iOS for permission again on the way.
    ///
    /// Both shapes the relaunch can have, because only one of them is under
    /// this type's control. The old key is normally gone by now; it is still
    /// there if the process died between writing the new keys and removing it,
    /// and the answer has to be the same either way rather than resting on a
    /// removal that may not have happened.
    @Test("turning both off and relaunching does not put them back")
    func bothOffSurvivesRelaunch() {
        let removed = PersonalDataToolsMigration.resolve(
            .init(legacy: nil, calendar: false, reminders: false)
        )
        #expect(removed.calendar == false)
        #expect(removed.reminders == false)
        #expect(removed.shouldPersist == false)

        let leftBehind = PersonalDataToolsMigration.resolve(
            .init(legacy: true, calendar: false, reminders: false)
        )
        #expect(leftBehind.calendar == false)
        #expect(leftBehind.reminders == false)
        // A write, but only to finish clearing the key the crash left.
        #expect(leftBehind.shouldPersist)
    }

    @Test("one capability on and one off is preserved exactly")
    func mixedStateIsPreserved() {
        let calendarOnly = PersonalDataToolsMigration.resolve(
            .init(legacy: nil, calendar: true, reminders: false)
        )
        #expect(calendarOnly.calendar)
        #expect(calendarOnly.reminders == false)

        let remindersOnly = PersonalDataToolsMigration.resolve(
            .init(legacy: nil, calendar: false, reminders: true)
        )
        #expect(remindersOnly.calendar == false)
        #expect(remindersOnly.reminders)
    }

    /// A half-written store: one new key present, the other never written.
    /// Reached by an upgrade that wrote one key and was killed, and by a build
    /// that adds the second switch after the first. The present key is an
    /// answer and the absent one is not, so the absent one must not inherit a
    /// value from a switch that no longer exists.
    @Test("a partially written store does not fall back to the old switch")
    func partiallyWrittenStore() {
        let outcome = PersonalDataToolsMigration.resolve(
            .init(legacy: true, calendar: false, reminders: nil)
        )
        #expect(outcome.calendar == false)
        #expect(outcome.reminders == false)
        #expect(outcome.shouldPersist)
    }

    /// Running `resolve` on its own output has to be a no-op, because that is
    /// exactly what the next launch does. Written as a loop rather than as one
    /// more assertion so that it covers every starting state above.
    @Test("resolving the result of a migration changes nothing")
    func idempotent() {
        for legacy in [true, false, nil] as [Bool?] {
            for calendar in [true, false, nil] as [Bool?] {
                for reminders in [true, false, nil] as [Bool?] {
                    let start = PersonalDataToolsMigration.Stored(
                        legacy: legacy,
                        calendar: calendar,
                        reminders: reminders
                    )
                    let first = PersonalDataToolsMigration.resolve(start)

                    // What the app writes when it is told to, and what it
                    // leaves alone when it is not.
                    let stored = first.shouldPersist
                        ? PersonalDataToolsMigration.Stored(
                            legacy: nil,
                            calendar: first.calendar,
                            reminders: first.reminders
                        )
                        : start

                    let second = PersonalDataToolsMigration.resolve(stored)
                    #expect(second.calendar == first.calendar, "\(start) changed the calendar on relaunch")
                    #expect(second.reminders == first.reminders, "\(start) changed reminders on relaunch")
                    #expect(second.shouldPersist == false, "\(start) never stops migrating")

                    // And the same relaunch with the removal lost: the two
                    // writes and the removal are three separate calls into the
                    // store, and a process killed after the first two leaves
                    // the old key sitting beside its replacements. The answer
                    // has to be the same one, or a crash restores a capability
                    // the user turned off. `shouldPersist` may well still be
                    // true here — the leftover key does need clearing.
                    let killed = PersonalDataToolsMigration.Stored(
                        legacy: start.legacy,
                        calendar: first.calendar,
                        reminders: first.reminders
                    )
                    let afterCrash = PersonalDataToolsMigration.resolve(killed)
                    #expect(afterCrash.calendar == first.calendar, "\(start) changed the calendar after a lost removal")
                    #expect(afterCrash.reminders == first.reminders, "\(start) changed reminders after a lost removal")
                }
            }
        }
    }
}
