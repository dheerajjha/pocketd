import Foundation
import PocketdKit

/// What the last screen of the intro knows about today.
///
/// A deliberately small cousin of the Today tab's own snapshot builder: today's
/// events, what is due, what has slipped, and which of the three sources is
/// actually speaking. No health values, because nothing here has read the store
/// and a snapshot that claims a sleep figure it does not have would put an
/// invented sentence on the one screen whose whole job is proving the app can
/// read the reader's real day.
///
/// Reads nothing it has not been granted. `EventAccess.events(in:)` requests
/// access on its way in, so calling it without checking first would put an iOS
/// sheet on the final screen for somebody who declined two screens ago.
enum OnboardingSnapshot {

    static func build(healthEnabled: Bool, now: Date = Date()) async -> TodaySnapshot {
        let calendar = EventAccess.authorization(for: .calendar)
        let reminders = EventAccess.authorization(for: .reminders)

        var events: [BriefEvent] = []
        var dueToday: [BriefReminder] = []
        var overdue: [BriefReminder] = []

        if calendar.canRead {
            let window = PersonalDataRange.eventWindow(for: .today, now: now)
            if case let .rows(rows, _) = await EventAccess.shared.events(in: window) {
                events = rows.map(BriefEvent.init)
            }
        }

        if reminders.canRead {
            let overdueWindow = PersonalDataRange.reminderWindow(for: .overdue, now: now)
            if case let .rows(rows, _) = await EventAccess.shared.reminders(in: overdueWindow) {
                overdue = rows.map(BriefReminder.init)
            }
            let todayWindow = PersonalDataRange.reminderWindow(for: .today, now: now)
            if case let .rows(rows, _) = await EventAccess.shared.reminders(in: todayWindow) {
                // Anything due earlier today is already in `overdue`, and a
                // brief that counts it twice reads as two separate problems.
                dueToday = rows
                    .filter { $0.due.map { $0 >= now } ?? true }
                    .map(BriefReminder.init)
            }
        }

        return TodaySnapshot(
            generatedAt: now,
            calendar: availability(calendar),
            reminders: availability(reminders),
            // The switch is on and the store exists, which is the strongest
            // claim HealthKit permits — it never confirms a read grant.
            health: healthEnabled && HealthAccess.isAvailable ? .connected : .off,
            events: events,
            dueToday: dueToday,
            overdue: overdue
        )
    }

    /// Add-only calendar access is a grant to *write* and no grant at all to
    /// read, so from a brief's point of view it is indistinguishable from a
    /// refusal — and calling it "off" would invite somebody to flip a switch
    /// that is already on.
    private static func availability(
        _ authorization: PersonalDataAuthorization
    ) -> TodaySnapshot.Availability {
        switch authorization {
        case .granted: .connected
        case .denied, .restricted, .writeOnly: .refused
        case .notDetermined: .off
        }
    }
}
