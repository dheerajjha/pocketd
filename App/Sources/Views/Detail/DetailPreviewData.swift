import PocketdKit
import SwiftUI

/// Fabricated pages, for the previews of the four detail screens.
///
/// The same invented day as `TodayPreviewData` — Sam's standup, lunch at The
/// Arches, the dentist — so a preview of Today and a preview of the page
/// behind its tile describe one morning. Built through the Kit's own `make`
/// functions, so the grouping, the summaries and the suggested questions are
/// the real rules applied to made-up rows. Nothing here is written anywhere.
@MainActor
enum DetailPreviewData {

    /// 09:41, the time every capture says.
    static var now: Date { at(9, 41) }

    static func at(_ hour: Int, _ minute: Int, daysFromToday offset: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    static var day: DayAgenda {
        DayAgenda.make(
            events: [
                DayEvent(eventIdentifier: "standup", title: "Standup", start: at(9, 30), end: at(9, 45)),
                DayEvent(
                    eventIdentifier: "lunch", title: "Lunch at The Arches", location: "The Arches, Leith Walk",
                    start: at(13, 0), end: at(14, 0)
                ),
                DayEvent(eventIdentifier: "dentist", title: "Dentist", location: "Bruntsfield Dental", start: at(16, 30), end: at(17, 15)),
                DayEvent(eventIdentifier: "call", title: "Call with Priya", start: at(18, 0), end: at(18, 30)),
                DayEvent(
                    eventIdentifier: "birthday", title: "Mum's birthday",
                    start: at(0, 0, daysFromToday: 1), end: at(0, 0, daysFromToday: 2), isAllDay: true
                ),
                DayEvent(eventIdentifier: "review", title: "Design review", start: at(10, 0, daysFromToday: 1), end: at(11, 0, daysFromToday: 1)),
            ],
            availability: .connected,
            now: now
        )
    }

    static var reminders: ReminderAgenda {
        ReminderAgenda.make(
            reminders: [
                DayReminder(id: "expenses", title: "Submit expenses", due: at(18, 0, daysFromToday: -1), dueHasTime: true, priority: 1),
                DayReminder(id: "plumber", title: "Call the plumber", due: at(17, 0), dueHasTime: true),
                DayReminder(id: "plants", title: "Water the plants", due: at(0, 0)),
                DayReminder(id: "passport", title: "Renew passport", due: at(0, 0, daysFromToday: 4)),
                DayReminder(id: "book", title: "Return the library book"),
            ],
            availability: .connected,
            now: now
        )
    }

    static var sleep: SleepDetail {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let minutes = [412, 431, 398, 425, 447, 405, 425, 460, 389, 436, 425, 418, 452, 425]
        var nights = minutes.enumerated().compactMap { index, value -> DailyValue? in
            guard let morning = calendar.date(byAdding: .day, value: -(minutes.count - index), to: today) else { return nil }
            return DailyValue(day: morning, value: Double(value * 60))
        }
        nights.append(DailyValue(day: today, value: 396 * 60))
        return SleepDetail.make(nights: nights, availability: .connected, now: now)
    }

    static var activity: ActivityDetail {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let steps: [Double] = [5_800, 6_400, 6_100, 7_200, 5_200, 6_100, 6_900, 4_800, 6_100, 6_600, 5_900, 6_100, 7_400, 6_300]
        var daily = steps.enumerated().compactMap { index, value -> DailyValue? in
            guard let day = calendar.date(byAdding: .day, value: -(steps.count - index), to: today) else { return nil }
            return DailyValue(day: day, value: value)
        }
        daily.append(DailyValue(day: today, value: 4_120))
        return ActivityDetail.make(daily: daily, hourly: nil, availability: .connected, now: now)
    }

    /// One model for every preview, so a preview does not build a new one —
    /// and its engine, stores and timers — on every redraw.
    static let model = AppModel()
}

extension View {
    /// What a detail page reads from its surroundings, for a preview.
    @MainActor
    func detailPreviewEnvironment() -> some View {
        environment(DetailPreviewData.model)
            .environment(Navigator())
            .environment(ToastCenter())
    }
}
