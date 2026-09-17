import PocketdKit
import SwiftUI

/// Fabricated days, for the previews of this tab.
///
/// A simulator cannot load a model large enough to write a brief and has no
/// Health database to read, so the two states that matter most on this screen —
/// a brain mid-sentence, and four tiles with real numbers in them — are
/// otherwise unphotographable. Everything here is invented: no real person, no
/// real company, nothing medical. That restraint matters for the same reason it
/// does in `DemoSeed`, minus its one risk: nothing in this file is written to
/// any store, and none of it leaves the preview.
enum TodayPreviewData {

    /// 08:12 on a Thursday, which is when a morning brief is actually read.
    static var now: Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: 8, minute: 12, second: 0, of: Date()) ?? Date()
    }

    /// Everything connected and a day with something in it.
    static var full: TodaySnapshot {
        let calendar = Calendar.current
        let today = now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        func at(_ hour: Int, _ minute: Int, _ day: Date) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        return TodaySnapshot(
            generatedAt: today,
            calendar: .connected,
            reminders: .connected,
            health: .connected,
            events: [
                BriefEvent(title: "Standup", start: at(9, 30, today), end: at(9, 45, today)),
                BriefEvent(
                    title: "Lunch at The Arches",
                    start: at(13, 0, today), end: at(14, 0, today), location: "The Arches"
                ),
                BriefEvent(title: "Dentist", start: at(16, 30, today), end: at(17, 15, today)),
                BriefEvent(title: "Design review", start: at(10, 0, tomorrow), end: at(11, 0, tomorrow)),
            ],
            dueToday: [BriefReminder(title: "Call the plumber", due: at(17, 0, today))],
            overdue: [BriefReminder(title: "Submit expenses", due: at(18, 0, calendar.date(byAdding: .day, value: -1, to: today) ?? today))],
            sleepLastNight: 23_760,
            sleepUsual: 25_500,
            stepsToday: 4_120,
            stepsUsual: 6_100
        )
    }

    /// A fresh install: nothing switched on, and nothing to say about the day.
    static var nothingConnected: TodaySnapshot {
        TodaySnapshot(generatedAt: now, calendar: .off, reminders: .off, health: .off)
    }

    static var templateBrief: DailyBrief {
        let snapshot = full
        return DailyBrief(
            text: BriefPrompt.fallback(snapshot: snapshot, name: "Sam", now: now),
            generatedAt: now,
            source: .template,
            snapshot: snapshot
        )
    }

    /// An `AppModel` with a brief already in it, for the states a simulator
    /// cannot reach on its own.
    ///
    /// Mutates `briefing` rather than injecting a different one, because the
    /// engine's whole design is that there is exactly one — see the single
    /// stored property on `AppModel`.
    @MainActor
    static func model(
        snapshot: TodaySnapshot,
        brief: DailyBrief? = nil,
        phase: BriefingState.Phase = .ready,
        streaming: String = ""
    ) -> AppModel {
        let model = AppModel()
        model.briefing.snapshot = snapshot
        model.briefing.brief = brief
        model.briefing.phase = phase
        model.briefing.streamingText = streaming
        model.briefing.lastRefresh = now
        return model
    }
}
