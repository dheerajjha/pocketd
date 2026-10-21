#if DEBUG
import Foundation
import os
import PocketdKit

/// `-pocketd.dumpDay`: writes everything the Today tiles and their detail pages
/// would show, as text, so it can be checked against the seed without a screen
/// to show it on.
///
/// The detail pages are built in a later pass than the data behind them, and
/// "it compiles" is not evidence that a tile says "1 overdue" on a day with one
/// overdue reminder. This reads the day exactly as the app does — `DayReader`,
/// the same availability, the same demo clock — and writes the verdicts, the
/// template brief, all four pages and the demo routine results to
/// `Library/Caches/day-dump.txt`, and to the log.
///
/// Debug only, and only when asked: the file holds event and reminder titles.
enum DayDump {

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.dumpDay")
    }

    /// Starts the dump a few seconds after launch, once the seed has landed
    /// and the app has published its own brief, which the dump quotes too.
    @MainActor
    static func scheduleIfRequested() {
        guard isRequested else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(8))
            let text = await render()
            write(text)
        }
    }

    static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("day-dump.txt")
    }

    static func write(_ text: String) {
        if let url = fileURL {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let log = Logger(subsystem: "dev.pocketd", category: "daydump")
        for line in text.split(separator: "\n") {
            log.notice("\(String(line), privacy: .public)")
        }
    }

    static func render() async -> String {
        let now = await MainActor.run { DemoClock.now }
        let calendar = Calendar.current
        let access = DayReader.Access(
            calendar: EventAccess.authorization(for: .calendar).canRead ? .connected : .off,
            reminders: EventAccess.authorization(for: .reminders).canRead ? .connected : .off,
            health: DemoDay.isRequested ? .connected : (HealthAccess.isAvailable ? .connected : .unavailable)
        )
        let name = UserDefaults.standard.string(forKey: "pd.profile.name")
        var lines: [String] = []

        lines.append("# Day dump at \(now.formatted(date: .abbreviated, time: .standard))  demoHealth=\(DemoDay.isRequested)")
        lines.append("access: calendar=\(access.calendar) reminders=\(access.reminders) health=\(access.health)")

        let snapshot = await DayReader.snapshot(now: now, calendar: calendar, access: access)
        lines.append("")
        lines.append("## Tiles (DayReader snapshot)")
        lines.append(contentsOf: tiles(snapshot, now: now, calendar: calendar))
        lines.append("BRIEF: " + BriefPrompt.fallback(snapshot: snapshot, name: name, now: now, calendar: calendar))
        lines.append("FIRST SENTENCE: " + BriefPrompt.firstSentence(snapshot: snapshot, now: now, calendar: calendar))
        lines.append("snapshot: events=\(snapshot.events.count) dueToday=\(snapshot.dueToday.count) overdue=\(snapshot.overdue.count) sleep=\(snapshot.sleepLastNight.map { Format.duration($0) } ?? "nil") usual=\(snapshot.sleepUsual.map { Format.duration($0) } ?? "nil") steps=\(snapshot.stepsToday.map { Format.count($0) } ?? "nil") usualDay=\(snapshot.stepsUsual.map { Format.count($0) } ?? "nil") usualByNow=\(snapshot.stepsUsualByNow.map { Format.count($0) } ?? "nil")")

        if let stored = AppModel.dailyBriefStore()?.read() {
            lines.append("")
            lines.append("## The app's own published brief (brief.json, \(stored.source.modelID ?? "template"))")
            lines.append("TEXT: \(stored.text)")
            lines.append(contentsOf: tiles(stored.snapshot, now: now, calendar: calendar))
        }

        let agenda = await DayReader.agenda(now: now, calendar: calendar, availability: access.calendar)
        lines.append("")
        lines.append("## Your day — \(agenda.summary)")
        lines.append("chip: \(agenda.suggestion)")
        for section in agenda.sections {
            lines.append("  \(section.group.title.uppercased()) (showing \(section.visible().count), more \(section.hiddenCount()))")
            for event in section.events {
                lines.append("    \(event.title) | \(event.detailText()) | \(event.timeText(calendar: calendar)) | directions=\(event.directionsURL?.absoluteString ?? "-") | open=\(event.calendarURL.absoluteString)")
            }
        }

        let reminders = await DayReader.reminders(now: now, calendar: calendar, availability: access.reminders)
        lines.append("")
        lines.append("## Reminders — \(reminders.summary)")
        lines.append("chip: \(reminders.suggestion)")
        for section in reminders.sections {
            lines.append("  \(section.group.title.uppercased())")
            for reminder in section.reminders {
                lines.append("    \(reminder.priorityMark ?? " ") \(reminder.title) | \(reminder.dueText(now: now, calendar: calendar) ?? "-") | id=\(reminder.id.prefix(8))…")
            }
        }

        if isTickRequested, let first = reminders.sections.first(where: { $0.group == .today })?.reminders.first {
            lines.append(contentsOf: await tickAndUndo(first, now: now, calendar: calendar))
        }

        let sleep = await DayReader.sleep(now: now, calendar: calendar, availability: access.health)
        lines.append("")
        lines.append("## Sleep — \(sleep.summary)")
        lines.append("USUAL \(sleep.usualText) | LAST NIGHT \(sleep.lastNightText) | [\(sleep.verdict.status)] \(sleep.deltaSentence)")
        lines.append("chip: \(sleep.suggestion)")
        for night in sleep.nights {
            lines.append("    \(night.label(relativeTo: now, calendar: calendar)) \(night.valueText)")
        }

        let activity = await DayReader.activity(now: now, calendar: calendar, availability: access.health)
        lines.append("")
        lines.append("## Activity — \(activity.summary)")
        lines.append("TODAY \(activity.todayText()) | \(activity.usualLabel.uppercased()) \(activity.usualText()) | [\(activity.verdict.status)] \(activity.deltaSentence)")
        lines.append("chip: \(activity.suggestion)")
        for day in activity.days {
            lines.append("    \(day.label(relativeTo: now, calendar: calendar)) \(day.valueText())")
        }

        // The three tool bodies, called exactly as an engine calls them: as
        // the phone's own chat, and as a network client. With a source that
        // iOS has never been asked about, the first must come back as a
        // sentence and no sheet may appear on screen.
        lines.append("")
        lines.append("## Tool bodies (as the phone's chat, then as a network client)")
        let clock = ContinuousClock()
        var started = clock.now
        let calendarList = await ToolBodies.calendar(action: .list, range: .today, origin: .onDeviceChat)
        lines.append("calendar.list(today) [\(milliseconds(since: started, clock))]: \(clip(ToolBodies.json(calendarList)))")
        started = clock.now
        let remindersList = await ToolBodies.reminders(action: .list, filter: .overdue, origin: .onDeviceChat)
        lines.append("reminders.list(overdue) [\(milliseconds(since: started, clock))]: \(clip(ToolBodies.json(remindersList)))")
        started = clock.now
        let healthSleep = await ToolBodies.health(focus: .sleep, origin: .onDeviceChat)
        lines.append("get_health_summary(sleep) [\(milliseconds(since: started, clock))]: \(clip(ToolBodies.json(healthSleep)))")
        started = clock.now
        let fromNetwork = await ToolBodies.calendar(action: .list, origin: .network(host: "192.168.1.9", port: 50_000))
        lines.append("calendar.list from the network [\(milliseconds(since: started, clock))]: \(clip(ToolBodies.json(fromNetwork)))")

        lines.append("")
        lines.append("## Demo routine results (DemoDay)")
        let morning = calendar.date(bySettingHour: 7, minute: 31, second: 0, of: now) ?? now
        lines.append("Morning brief 7:31: \(DemoDay.morningBrief(at: morning, calendar: calendar))")
        lines.append("Overdue nudge 9:00: \(DemoDay.overdueNudge(at: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now, calendar: calendar).replacingOccurrences(of: "\n", with: " / "))")
        lines.append("Demo snapshot tiles now:")
        lines.append(contentsOf: tiles(DemoDay.snapshot(at: now, calendar: calendar), now: now, calendar: calendar))

        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// `-pocketd.dumpDayTick`: ticks the first of today's reminders off
    /// through the same `EventAccess` path the Reminders page uses, reads the
    /// list again, puts it back with the Undo path, and reads once more — a
    /// round trip through the real store, which no unit test can make.
    static var isTickRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.dumpDayTick")
    }

    static func tickAndUndo(_ reminder: DayReminder, now: Date, calendar: Calendar) async -> [String] {
        var lines = ["  TICK \"\(reminder.title)\""]
        let ticked = await EventAccess.shared.completeReminder(identifier: reminder.id)
        let completion = ReminderCompletion(reminderID: reminder.id, title: reminder.title)
        let after = await DayReader.reminders(now: now, calendar: calendar, availability: .connected)
        let gone = !after.sections.flatMap(\.reminders).contains { $0.id == reminder.id }
        lines.append("    complete → \(ticked) · toast: \(completion.sentence) · gone from the list: \(gone) · summary now: \(after.summary)")
        let undone = await EventAccess.shared.uncompleteReminder(identifier: reminder.id)
        let back = await DayReader.reminders(now: now, calendar: calendar, availability: .connected)
        let returned = back.sections.flatMap(\.reminders).contains { $0.id == reminder.id }
        lines.append("    undo → \(undone) · \(completion.undoneSentence) · back on the list: \(returned) · summary now: \(back.summary)")
        return lines
    }

    static func milliseconds(since start: ContinuousClock.Instant, _ clock: ContinuousClock) -> String {
        "\(Int(start.duration(to: clock.now) / .milliseconds(1))) ms"
    }

    static func clip(_ text: String, limit: Int = 400) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func tiles(_ snapshot: TodaySnapshot, now: Date, calendar: Calendar) -> [String] {
        TodayVerdicts.all(snapshot, now: now, calendar: calendar).map {
            "TILE \($0.tile.label.uppercased()): [\($0.status)] \($0.sentence)  (\($0.tone.rawValue), tap=\($0.action.rawValue))"
        }
    }
}
#endif
