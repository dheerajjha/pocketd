import Foundation
import PocketdKit

/// Phone lookups, through the same bodies the models' tools call. Both the
/// Apple engine and a download answering an explicit list question use these.
enum SystemReads {
    /// One read, as the tool it stands in for: its registered name, the
    /// arguments a tool call would have carried (the card reads its heading
    /// from them — "Tomorrow", "Overdue"), and the body. `nil` for a domain
    /// that is switched off, which has nothing to run.
    static func call(for read: SystemModelReads.Read) -> SystemModelReads.Read.Call? {
        read.call(
            calendar: { await ToolBodies.calendar(action: .list, range: $0, origin: $1) },
            reminders: { await ToolBodies.reminders(action: .list, filter: $0, origin: $1) },
            health: { await health(focus: $0, origin: $1) }
        )
    }

    /// The health body, or — on a Debug simulator under `-pocketd.demoHealth` —
    /// the same arithmetic over the demo day Today's tiles are drawn from, so
    /// a capture of the conversation agrees with a capture of Today (QA S3-10).
    /// A simulator has no Health, and this app never writes to Health to fill
    /// one.
    static func health(focus: HealthFocus, origin: RequestOrigin) async -> [String: any Sendable] {
        #if DEBUG && targetEnvironment(simulator)
        if DemoDay.isRequested {
            return await HealthSummary.payload(focus: focus, origin: origin) { focus, _ in
                demoReadout(for: focus, now: Date(), calendar: .current)
            }
        }
        #endif
        return await ToolBodies.health(focus: focus, origin: origin)
    }

    #if DEBUG && targetEnvironment(simulator)
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
