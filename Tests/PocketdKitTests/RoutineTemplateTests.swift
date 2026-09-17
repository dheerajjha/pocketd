import Foundation
import Testing
@testable import PocketdKit

/// A one-tap routine has to produce a task that actually fires when its card
/// says it will.
///
/// The assertion worth the most here is `morningBriefDoesNotFireTheMomentItIsMade`:
/// a 07:30 task created at two in the afternoon has a firing four and a half
/// hours behind it, and without `settledThrough` starting at `createdAt` the
/// user's reward for setting up a morning brief is a morning brief at teatime.
/// The rest is the templates keeping their own promises — a card that says
/// "watcher" must not resolve to something that needs the app open.
@Suite("Routine templates")
struct RoutineTemplateTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// Friday afternoon. Chosen because it is the one moment that exercises
    /// every branch at once: this morning's firing has gone, tomorrow is a
    /// Saturday, and Sunday is not a weekday either.
    static let fridayAfternoon = date(18, 14)

    // MARK: - When they fire

    @Test("a weekday morning brief made on Friday afternoon fires on Monday")
    func morningBriefSkipsTheWeekend() {
        let task = RoutineTemplate.morningBrief.task(now: Self.fridayAfternoon, calendar: Self.calendar)
        let dueness = task.dueness(now: Self.fridayAfternoon, calendar: Self.calendar)
        #expect(dueness.next == Self.date(21, 7, 30))
    }

    @Test("a brief created after its hour is not owed that hour")
    func morningBriefDoesNotFireTheMomentItIsMade() {
        let task = RoutineTemplate.morningBrief.task(now: Self.fridayAfternoon, calendar: Self.calendar)
        // 07:30 today has already gone. `settledThrough` starts at `createdAt`,
        // which is the whole of why this is false.
        #expect(task.dueness(now: Self.fridayAfternoon, calendar: Self.calendar).isDue == false)
        #expect(task.isEnabled)
    }

    @Test("weekdays only can be turned off, and then Saturday counts")
    func weekdaysOnlyIsHonoured() {
        let everyDay = RoutineTemplate.morningBrief.task(
            now: Self.fridayAfternoon, calendar: Self.calendar, weekdaysOnly: false
        )
        #expect(everyDay.recurrence == .daily(at: TimeOfDay(hour: 7, minute: 30)))
        #expect(everyDay.dueness(now: Self.fridayAfternoon, calendar: Self.calendar).next == Self.date(19, 7, 30))
    }

    @Test("the evening wrap-up lands the same evening")
    func eveningWrapUp() {
        let task = RoutineTemplate.eveningWrapUp.task(
            now: Self.fridayAfternoon, calendar: Self.calendar, weekdaysOnly: false
        )
        #expect(task.dueness(now: Self.fridayAfternoon, calendar: Self.calendar).next == Self.date(18, 21))
    }

    @Test("the weekly review is Sunday at six, whatever weekdaysOnly says")
    func weeklyReviewIgnoresWeekdaysOnly() {
        // Weekly by definition. A "weekdays only" flag applied here would either
        // silence it or move it, and both are wrong.
        for weekdaysOnly in [true, false] {
            let task = RoutineTemplate.weeklyReview.task(
                now: Self.fridayAfternoon, calendar: Self.calendar, weekdaysOnly: weekdaysOnly
            )
            #expect(task.recurrence == .weekly(days: [.sunday], at: TimeOfDay(hour: 18, minute: 0)))
            #expect(task.dueness(now: Self.fridayAfternoon, calendar: Self.calendar).next == Self.date(20, 18))
        }
    }

    @Test("a time passed in beats the default")
    func explicitTimeWins() {
        let task = RoutineTemplate.morningBrief.task(
            now: Self.fridayAfternoon, calendar: Self.calendar,
            time: TimeOfDay(hour: 6, minute: 15), weekdaysOnly: false
        )
        #expect(task.dueness(now: Self.fridayAfternoon, calendar: Self.calendar).next == Self.date(19, 6, 15))
    }

    @Test("every template produces a schedule that can actually fire")
    func everyTemplateIsFireable() {
        for template in RoutineTemplate.allCases {
            let task = template.task(now: Self.fridayAfternoon, calendar: Self.calendar)
            #expect(task.recurrence.isFireable)
            // A rule that never matched would sit in the list looking scheduled
            // and do nothing, which is indistinguishable from one whose next
            // firing is simply far away.
            #expect(task.dueness(now: Self.fridayAfternoon, calendar: Self.calendar).next != nil)
            #expect(task.title == template.title)
            #expect(task.createdAt == Self.fridayAfternoon)
        }
    }

    // MARK: - What they are

    @Test("the overdue watcher is a real watcher and needs no model")
    func overdueWatcherRunsInTheBackground() {
        let task = RoutineTemplate.overdueWatcher.task(now: Self.fridayAfternoon, calendar: Self.calendar)
        #expect(task.body == .watcher(rule: .reminders(.overdue), notifyWhenEmpty: false))
        // The whole point of a watcher: it can finish inside a background
        // refresh, so the notification arrives with the answer in it.
        #expect(task.body.needsModel == false)
        #expect(task.handoff(firing: Self.fridayAfternoon) == nil)
    }

    @Test("the three briefs are prompts, and ask for what the brief actually is")
    func promptsAreWorthReading() {
        for template in [RoutineTemplate.morningBrief, .eveningWrapUp, .weeklyReview] {
            guard case let .prompt(text) = template.body else {
                Issue.record("\(template) should be a prompt")
                continue
            }
            #expect(text.contains("sentences"))
            #expect(text.contains("No lists"))
            // The instruction that stops a small model filling a quiet day with
            // meetings nobody has.
            #expect(text.contains("Only mention things you actually found"))
            #expect(template.task(now: Self.fridayAfternoon, calendar: Self.calendar).body.needsModel)
        }
        guard case let .prompt(morning) = RoutineTemplate.morningBrief.body else { return }
        #expect(morning.contains("two or three sentences"))
        #expect(morning.contains("how I slept"))
    }

    @Test("a card is only offered if it can keep the promise in its own name")
    func sleepWatcherIsNotOffered() {
        // `WatcherRule` has `.events` and `.reminders` and nothing for health,
        // because a watcher is defined by being able to finish in a background
        // refresh with no GPU. So "sleep watcher" can only be built as a prompt
        // today, and a prompt arrives when the user next opens the app — which
        // is not what the word watcher promises.
        #expect(RoutineTemplate.sleepWatcher.body.needsModel)
        #expect(!RoutineTemplate.offered.contains(.sleepWatcher))
        #expect(RoutineTemplate.offered == [.morningBrief, .eveningWrapUp, .weeklyReview, .overdueWatcher])
        // Still written and still tested, ready for the day `WatcherRule` grows
        // a health case.
        #expect(RoutineTemplate.allCases.contains(.sleepWatcher))
    }

    // MARK: - Copy

    @Test("a blurb fits on a card in a two-column grid")
    func blurbsAreShort() {
        for template in RoutineTemplate.allCases {
            #expect(template.blurb.count <= 70, "\(template.rawValue): \(template.blurb.count) characters")
            #expect(template.blurb.hasSuffix("."))
            #expect(!template.title.isEmpty)
            #expect(!template.symbolName.isEmpty)
        }
    }

    @Test("no card says a word the consumer screens are not allowed to use")
    func copyStaysOutOfTheJargon() {
        // The v2 rule: never model, token, inference, prompt or GGUF on a top
        // level screen. The templates grid is one.
        let banned = ["model", "GGUF", "token", "inference", "prompt", "LLM"]
        for template in RoutineTemplate.allCases {
            let copy = (template.title + " " + template.blurb).lowercased()
            for word in banned {
                #expect(!copy.contains(word.lowercased()), "\(template.rawValue) says \(word)")
            }
        }
    }

    @Test("a template can be stored and read back")
    func rawValuesAreStable() throws {
        // The rawValue is what `routineCreated(template:)` reports and what a
        // saved editor draft would carry, so it is part of the contract.
        #expect(RoutineTemplate(rawValue: "morningBrief") == .morningBrief)
        #expect(RoutineTemplate.allCases.map(\.rawValue) == [
            "morningBrief", "eveningWrapUp", "weeklyReview", "overdueWatcher", "sleepWatcher",
        ])
    }
}
