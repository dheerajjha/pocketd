import Foundation
import Testing
@testable import PocketdKit

/// The routine editor's model.
///
/// The first test is the reason this type moved into the Kit. It lived in the
/// editor's view file with `==` comparing an identity UUID alone, and SwiftUI
/// decides whether a `@State` write changed anything with `==`: every keystroke
/// in the name field was "no change", the form kept saying "It needs a name."
/// under a typed name, and no routine could be made from scratch.
@Suite("Routine draft")
struct RoutineDraftTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// Friday 18 September 2026, two in the afternoon.
    static let now = date(18, 14)

    static func blank() -> RoutineDraft { RoutineDraft(now: now, calendar: calendar) }

    // MARK: - The bug

    @Test("every edit makes a different draft, and the draft keeps its identity")
    func editsAreChanges() {
        let original = Self.blank()
        var edits: [(String, (inout RoutineDraft) -> Void)] = [
            ("title", { $0.title = "Gym" }),
            ("prompt", { $0.prompt = "What is on this weekend?" }),
            ("kind", { $0.kind = .ask }),
            ("source", { $0.source = .events }),
            ("range", { $0.calendarRange = .tomorrow }),
            ("filter", { $0.reminderFilter = .today }),
            ("notify", { $0.notifyWhenEmpty = true }),
            ("repeats", { $0.repeats = .monthly }),
            ("time", { $0.time = $0.time.addingTimeInterval(60) }),
            ("days", { $0.toggle(.saturday) }),
            ("month day", { $0.monthDay = 31 }),
            ("short months", { $0.whenShort = .skip }),
            ("once", { $0.onceAt = $0.onceAt.addingTimeInterval(60) }),
            ("enabled", { $0.isEnabled = false }),
        ]
        edits.append(("origin", { $0.origin = .weeklyReview }))
        for (name, edit) in edits {
            var draft = original
            edit(&draft)
            #expect(draft != original, "editing \(name) compared equal to the untouched draft")
            #expect(draft.id == original.id, "editing \(name) changed the draft's identity")
        }
        #expect(original == original)
    }

    @Test("typing a name is what clears the name problem")
    func typingANameEnablesSave() {
        var draft = Self.blank()
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == "Give it a name.")
        draft.title = "   "
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == "Give it a name.")
        draft.title = "Gym check"
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == nil)
    }

    // MARK: - A routine from scratch

    @Test("a routine from scratch is a brief, on weekdays at nine")
    func blankIsAWeekdayBrief() {
        let draft = Self.blank()
        #expect(draft.kind == .brief)
        #expect(draft.taskID == nil)
        #expect(draft.origin == nil)
        #expect(draft.days == Weekday.workdays)
        #expect(draft.timeOfDay(calendar: Self.calendar) == TimeOfDay(hour: 9, minute: 0))
        // A brief needs nothing typed but its name, so a person who only names
        // it can save it.
        var named = draft
        named.title = "Lunch brief"
        let task = named.newTask(now: Self.now, calendar: Self.calendar)
        #expect(task.body == .brief)
        #expect(task.recurrence == .weekdays(at: TimeOfDay(hour: 9, minute: 0)))
        #expect(task.title == "Lunch brief")
        #expect(task.createdAt == Self.now)
    }

    @Test("a question needs words before it can be saved")
    func askNeedsAQuestion() {
        var draft = Self.blank()
        draft.title = "Weekend"
        draft.kind = .ask
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == "Type a question for Pocketd.")
        draft.prompt = " \n "
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == "Type a question for Pocketd.")
        draft.prompt = "  What is on this weekend?\n"
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == nil)
        #expect(draft.work == .prompt("What is on this weekend?"))
    }

    @Test("no days, a past moment and an impossible date are refused")
    func scheduleProblems() {
        var draft = Self.blank()
        draft.title = "Check"
        draft.days = []
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == "Pick at least one day.")

        draft.days = [.monday]
        draft.repeats = .once
        draft.onceAt = Self.now.addingTimeInterval(-60)
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == "Pick a time that hasn't passed.")
        draft.onceAt = Self.now.addingTimeInterval(60)
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == nil)

        draft.repeats = .monthly
        draft.monthDay = 32
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == "This can never come round.")
    }

    // MARK: - Every day

    @Test("all seven days is stored as every day, and every day opens as seven chips")
    func everyDayIsSevenDays() {
        var draft = Self.blank()
        draft.days = Set(Weekday.allCases)
        #expect(draft.recurrence(calendar: Self.calendar) == .daily(at: TimeOfDay(hour: 9, minute: 0)))

        let daily = ScheduledTask(
            title: "Every morning", body: .brief,
            recurrence: .daily(at: TimeOfDay(hour: 6, minute: 45)), createdAt: Self.date(10, 8)
        )
        let opened = RoutineDraft(daily, now: Self.now, calendar: Self.calendar)
        #expect(opened.repeats == .weekly)
        #expect(opened.days == Set(Weekday.allCases))
        #expect(opened.recurrence(calendar: Self.calendar) == daily.recurrence)
    }

    // MARK: - Round trips

    @Test("every kind of routine opens in the editor and saves back as itself")
    func roundTrips() {
        let bodies: [TaskBody] = [
            .brief,
            .watcher(rule: .events(.tomorrow), notifyWhenEmpty: true),
            .watcher(rule: .reminders(.this_week), notifyWhenEmpty: false),
            .prompt("What is on this weekend?"),
        ]
        let recurrences: [Recurrence] = [
            .weekly(days: [.monday, .thursday], at: TimeOfDay(hour: 18, minute: 15)),
            .daily(at: TimeOfDay(hour: 7, minute: 0)),
            .monthly(day: 31, at: TimeOfDay(hour: 9, minute: 0), whenShort: .skip),
            .once(Self.date(25, 15, 30)),
        ]
        for body in bodies {
            for recurrence in recurrences {
                let task = ScheduledTask(
                    title: "Mine", body: body, recurrence: recurrence, createdAt: Self.date(10, 8)
                )
                let draft = RoutineDraft(task, now: Self.now, calendar: Self.calendar)
                #expect(draft.taskID == task.id)
                let saved = draft.newTask(now: Self.now, calendar: Self.calendar)
                #expect(saved.id == task.id)
                #expect(saved.body == body)
                #expect(saved.recurrence == recurrence)
            }
        }
    }

    @Test("a template draft is that template, ready to add")
    func templateDraft() {
        let draft = RoutineDraft(.morningBrief, now: Self.now, calendar: Self.calendar)
        #expect(draft.origin == .morningBrief)
        #expect(draft.taskID == nil)
        #expect(draft.kind == .brief)
        #expect(draft.title == "Morning brief")
        #expect(draft.days == Weekday.workdays)
        #expect(draft.timeOfDay(calendar: Self.calendar) == TimeOfDay(hour: 7, minute: 30))
        #expect(draft.problem(now: Self.now, calendar: Self.calendar) == nil)

        let review = RoutineDraft(.weeklyReview, now: Self.now, calendar: Self.calendar)
        #expect(review.kind == .ask)
        #expect(review.days == [.sunday])
        #expect(!review.prompt.isEmpty)
    }

    // MARK: - Saving an edit

    @Test("an edit keeps the run history and settles a changed schedule")
    func applyKeepsHistory() {
        var task = RoutineTemplate.morningBrief.task(now: Self.date(10, 8), calendar: Self.calendar)
        let ran = TaskRun.reported(
            firing: Self.date(18, 7, 30), ranAt: Self.date(18, 7, 30),
            context: .backgroundRefresh, output: Untrusted("1 reminder is due today.")
        )
        task.settle(ran, at: Self.date(18, 7, 30))
        let settled = task.settledThrough

        // A rename moves nothing in the schedule.
        var draft = RoutineDraft(task, now: Self.now, calendar: Self.calendar)
        draft.title = "Wake-up brief"
        var renamed = task
        draft.apply(to: &renamed, now: Self.now, calendar: Self.calendar)
        #expect(renamed.title == "Wake-up brief")
        #expect(renamed.runs == task.runs)
        #expect(renamed.settledThrough == settled)

        // A new time at 14:00 for a 10:00 brief must not be owed this morning.
        draft.time = RoutineDraft.date(from: TimeOfDay(hour: 10, minute: 0), on: Self.now, calendar: Self.calendar)
        var retimed = task
        draft.apply(to: &retimed, now: Self.now, calendar: Self.calendar)
        #expect(retimed.settledThrough == Self.now)
        #expect(retimed.dueness(now: Self.now, calendar: Self.calendar).isDue == false)
        #expect(retimed.runs == task.runs)
    }

    @Test("switching a routine back on skips what it missed, from the card or the editor")
    func resumeSkipsMissedFirings() {
        // Paused on the 10th, back on at two in the afternoon on the 18th: the
        // 07:30 brief is not owed for this morning or any morning in between.
        var task = RoutineTemplate.morningBrief.task(now: Self.date(10, 8), calendar: Self.calendar)
        task.setEnabled(false, at: Self.date(10, 9))
        #expect(task.dueness(now: Self.now, calendar: Self.calendar) == .idle)

        var fromCard = task
        fromCard.setEnabled(true, at: Self.now)
        #expect(fromCard.isEnabled)
        #expect(fromCard.dueness(now: Self.now, calendar: Self.calendar).isDue == false)
        #expect(fromCard.settledThrough == Self.now)

        var fromEditor = task
        var draft = RoutineDraft(task, now: Self.now, calendar: Self.calendar)
        draft.isEnabled = true
        draft.apply(to: &fromEditor, now: Self.now, calendar: Self.calendar)
        #expect(fromEditor.isEnabled)
        #expect(fromEditor.settledThrough == fromCard.settledThrough)

        // Pausing moves nothing: the schedule is kept for when it comes back.
        var paused = fromCard
        paused.setEnabled(false, at: Self.now.addingTimeInterval(60))
        #expect(paused.settledThrough == fromCard.settledThrough)
        #expect(paused.recurrence == fromCard.recurrence)
    }

    @Test("a question turned into a brief stops waiting to be written")
    func kindChangeDropsPromises() {
        var task = ScheduledTask(
            title: "Weekend", body: .prompt("What is on this weekend?"),
            recurrence: .weekly(days: [.friday], at: TimeOfDay(hour: 9, minute: 0)), createdAt: Self.date(10, 8)
        )
        task.settle(.awaitingForeground(firing: Self.date(18, 9), ranAt: Self.date(18, 9), context: .backgroundRefresh))
        #expect(task.pendingRun(now: Self.now, calendar: Self.calendar) != nil)

        var draft = RoutineDraft(task, now: Self.now, calendar: Self.calendar)
        draft.kind = .brief
        draft.apply(to: &task, now: Self.now, calendar: Self.calendar)
        #expect(task.body == .brief)
        #expect(task.pendingRun(now: Self.now, calendar: Self.calendar) == nil)
    }

    // MARK: - Copy

    @Test("the labels speak plainly")
    func labelsHaveNoJargon() {
        let banned = ["model", "prompt", "watcher", "brain", "task", "schedule", "LLM", "token"]
        let labels = RoutineDraft.Kind.allCases.map(\.label)
            + RoutineDraft.Source.allCases.map(\.label)
            + RoutineDraft.Repeats.allCases.map(\.label)
        for label in labels {
            for word in banned {
                #expect(!label.lowercased().contains(word.lowercased()), "\(label) says \(word)")
            }
        }
    }
}
