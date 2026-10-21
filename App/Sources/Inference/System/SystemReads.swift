import Foundation
import PocketdKit

/// The reads the built-in brain makes itself, through the same bodies its
/// tools call.
///
/// Two callers: the engine's read-first path (`SystemModelReads`), which reads
/// before Apple's model is asked anything, and the health tool wrapper. Both
/// end in `ToolBodies` — the origin gate, the "not connected" sentences and the
/// row caps are the tools' own — so a card drawn from a read is the card the
/// same tool call would have drawn.
enum SystemReads {
    /// One read, as the tool it stands in for: its registered name, the
    /// arguments a tool call would have carried (the card reads its heading
    /// from them — "Tomorrow", "Overdue"), and the body. `nil` for a domain
    /// that is switched off, which has nothing to run.
    static func call(
        for read: SystemModelReads.Read
    ) -> (name: String, arguments: [String: any Sendable], body: @Sendable (RequestOrigin) async -> [String: any Sendable])? {
        switch read {
        case let .calendar(range):
            return (PersonalDataToolNames.calendar, ["action": CalendarAction.list.rawValue, "range": range.rawValue], { origin in
                await ToolBodies.calendar(action: .list, range: range, origin: origin)
            })
        case let .reminders(filter):
            return (PersonalDataToolNames.reminders, ["action": ReminderAction.list.rawValue, "filter": filter.rawValue], { origin in
                await ToolBodies.reminders(action: .list, filter: filter, origin: origin)
            })
        case let .health(focus):
            return (PersonalDataToolNames.health, ["focus": focus.rawValue], { origin in
                await health(focus: focus, origin: origin)
            })
        case .switchedOff:
            return nil
        }
    }

    /// The health body, or — in a Debug build under `-pocketd.demoHealth` —
    /// the same arithmetic over the demo day Today's tiles are drawn from, so
    /// a capture of the conversation agrees with a capture of Today (QA S3-10).
    /// A simulator has no Health, and this app never writes to Health to fill
    /// one.
    static func health(focus: HealthFocus, origin: RequestOrigin) async -> [String: any Sendable] {
        #if DEBUG
        if DemoDay.isRequested {
            return await HealthSummary.payload(focus: focus, origin: origin) { focus, _ in
                demoReadout(for: focus, now: Date(), calendar: .current)
            }
        }
        #endif
        return await ToolBodies.health(focus: focus, origin: origin)
    }

    #if DEBUG
    /// The demo day as a Health read would return it: last night's 6h 36m
    /// against the fortnight `DemoDay` keeps, today's 4,120 steps so far, a
    /// resting heart rate of 58 against a usual 61. Nothing else is invented;
    /// the rest of each focus comes back empty and is reported as such.
    static func demoReadout(for focus: HealthFocus, now: Date, calendar: Calendar) -> HealthReadout {
        switch focus {
        case .sleep:
            let intervals = DemoDay.nights(now: now, calendar: calendar).compactMap { night -> SleepInterval? in
                guard let end = calendar.date(bySettingHour: 6, minute: 30, second: 0, of: night.day) else { return nil }
                return SleepInterval(start: end.addingTimeInterval(-night.value), end: end, asleep: true)
            }
            return HealthReadout(sleep: intervals)
        case .activity:
            var totals: [Date: Double] = [:]
            for sample in DemoDay.hourlySteps(now: now, calendar: calendar) {
                totals[calendar.startOfDay(for: sample.date), default: 0] += sample.value
            }
            let days = totals.keys.sorted().map { HealthSample(value: totals[$0] ?? 0, unit: .count, date: $0) }
            return HealthReadout(samples: [.steps: days])
        case .heart:
            guard let latest = DemoDay.restingHeartRate, let usual = DemoDay.restingHeartRateUsual else { return HealthReadout() }
            let today = calendar.startOfDay(for: now)
            var samples: [HealthSample] = (1...14).reversed().compactMap { back in
                calendar.date(byAdding: .day, value: -back, to: today).map { HealthSample(value: usual, unit: .beatsPerMinute, date: $0) }
            }
            samples.append(HealthSample(value: latest, unit: .beatsPerMinute, date: today))
            return HealthReadout(samples: [.resting_heart_rate: samples])
        case .body, .workouts:
            return HealthReadout()
        }
    }
    #endif
}
