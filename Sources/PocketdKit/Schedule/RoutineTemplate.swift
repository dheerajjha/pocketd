import Foundation

/// A routine somebody can have in one tap.
///
/// The empty Routines tab used to be a plus button and a form with eight fields,
/// which is a fair description of what a scheduled task *is* and a poor answer
/// to what a person wants from one. These are the answers, each of which
/// resolves to an ordinary `ScheduledTask` — there is no template runtime, no
/// second scheduler and nothing that needs updating when a template changes.
/// Picking one adds it with the defaults below; from that point a templated
/// task is indistinguishable from a hand-made one.
///
/// Two of them are **briefs** (`TaskBody.brief`): the same brief Today shows,
/// announced at the hour the user chose. One is a **rule** that finishes in a
/// background refresh with no brain. One is a **question** for the brain, and
/// its prompt is part of the product rather than a placeholder: a 1.7B model
/// asked "summarise my week" writes a paragraph of throat-clearing; asked for
/// three or four sentences, told what to include and told what not to do, it
/// writes something worth reading. Those words live here so they can be changed
/// once and tested, rather than being typed into a text field by every user.
public enum RoutineTemplate: String, CaseIterable, Sendable, Codable {
    case morningBrief
    case eveningWrapUp
    case weeklyReview
    /// "Overdue nudge" on screen. The case keeps its first name because the
    /// raw value is the analytics wire value and the stored contract.
    case overdueWatcher
    case sleepWatcher

    /// The templates the Routines sheet actually shows, in the order it shows
    /// them.
    ///
    /// `sleepWatcher` is missing, and it is missing for a structural reason
    /// rather than a taste one. `WatcherRule` has exactly two cases — `.events`
    /// and `.reminders` — because a watcher's defining property is that it can
    /// run to completion inside a `BGAppRefreshTask` with no model and no GPU,
    /// and both of those are deterministic reads over EventKit rows. There is no
    /// `.health` case, so there is no way to express "tell me when last night
    /// was short" as a watcher today; `task(now:)` therefore builds it as a
    /// *prompt*, which needs the foreground and so cannot honour the word
    /// "watcher" in its own name.
    ///
    /// Offering it anyway would put a card on the sheet promising a nudge that
    /// arrives only when the user happens to open the app — which is precisely
    /// the failure the watcher/prompt split exists to make impossible. It stays
    /// in `CaseIterable` so that the case, its copy and its prompt are all
    /// written and tested, ready for the day `WatcherRule` grows a health case.
    ///
    /// The order is the order of a day and then a week: the two briefs, the
    /// nudge that lands between them, and the review that only comes on
    /// Sundays.
    public static var offered: [RoutineTemplate] {
        [.morningBrief, .eveningWrapUp, .overdueWatcher, .weeklyReview].filter { template in
            if case .prompt = template.body, template.claimsToWatch { return false }
            return true
        }
    }

    /// Whether the name promises something that runs while the app is closed.
    /// Only used by `offered`, and only to catch exactly the mismatch above.
    var claimsToWatch: Bool {
        switch self {
        case .overdueWatcher, .sleepWatcher: true
        case .morningBrief, .eveningWrapUp, .weeklyReview: false
        }
    }

    public var title: String {
        switch self {
        case .morningBrief: "Morning brief"
        case .eveningWrapUp: "Evening wrap-up"
        case .weeklyReview: "Weekly review"
        case .overdueWatcher: "Overdue nudge"
        case .sleepWatcher: "Sleep check"
        }
    }

    /// Titles a template used to have, so a routine saved under one is still
    /// recognised as this template. `RoutineMigration` renames the stored ones;
    /// this covers a file read before that migration has been written back.
    var formerTitles: [String] {
        switch self {
        case .overdueWatcher: ["Overdue watcher"]
        case .sleepWatcher: ["Sleep watcher"]
        case .morningBrief, .eveningWrapUp, .weeklyReview: []
        }
    }

    /// One sentence under the title on the templates sheet.
    ///
    /// Seventy characters, tested: the sheet's rows have about that much on the
    /// narrowest iPhone in support before the line wraps a third time.
    public var blurb: String {
        switch self {
        case .morningBrief: "Your day in a few lines, ready when you wake."
        case .eveningWrapUp: "What is still open, and how tomorrow starts."
        case .weeklyReview: "Sunday evening: the week ahead, before it starts."
        case .overdueWatcher: "A nudge when something on your list slips past its date."
        case .sleepWatcher: "Tells you when last night was shorter than your usual."
        }
    }

    public var symbolName: String {
        switch self {
        case .morningBrief: "sun.horizon"
        case .eveningWrapUp: "moon.stars"
        case .weeklyReview: "calendar"
        case .overdueWatcher: "exclamationmark.circle"
        case .sleepWatcher: "bed.double"
        }
    }

    /// When it fires if the user changes nothing.
    ///
    /// 07:30 for the brief because it wants to be read before the day starts and
    /// after the phone has been picked up. 21:00 for the wrap-up because
    /// tomorrow is still worth knowing about at nine and is not at eleven. 18:00
    /// on Sunday for the review, which is the hour people plan a week in. 09:00
    /// for the nudge — early enough to act on, late enough that it is not the
    /// first thing anyone sees.
    public var defaultTime: TimeOfDay {
        switch self {
        case .morningBrief: TimeOfDay(hour: 7, minute: 30)
        case .eveningWrapUp: TimeOfDay(hour: 21, minute: 0)
        case .weeklyReview: TimeOfDay(hour: 18, minute: 0)
        case .overdueWatcher, .sleepWatcher: TimeOfDay(hour: 9, minute: 0)
        }
    }

    /// What the task does.
    ///
    /// A computed property rather than something `task(now:)` builds inline, so
    /// that `offered` can ask whether a template resolves to a watcher without
    /// having to invent a `Date` to ask the question.
    public var body: TaskBody {
        switch self {
        case .morningBrief, .eveningWrapUp:
            // The same brief as Today's, at the hour chosen. What it says is
            // decided by the time it is written — a 21:00 brief is an evening
            // brief because `BriefPrompt` reads the clock — so the two need no
            // instructions of their own. See `TaskBody.brief`.
            .brief
        case .weeklyReview:
            .prompt("""
            Look at the week ahead. In three or four sentences: what the week looks like, \
            which days have the most on them, and anything already overdue. \
            Plain and specific. No lists and no headings. Only mention things you actually found.
            """)
        case .overdueWatcher:
            // `notifyWhenEmpty: false`, because a daily notification saying
            // nothing is overdue is the fastest way to have this app's
            // notifications switched off.
            .watcher(rule: .reminders(.overdue), notifyWhenEmpty: false)
        case .sleepWatcher:
            // A prompt, not a watcher, and the name would therefore promise
            // something this cannot keep — which is why `offered` leaves it
            // out. See the note there.
            .prompt("""
            Compare how I slept last night with how I usually sleep. One or two sentences, \
            plain, no advice. Say nothing if you cannot read my sleep.
            """)
        }
    }

    /// A real `ScheduledTask`, ready to save or to open in the editor.
    ///
    /// - Parameter time: Overrides `defaultTime`. The onboarding time picker
    ///   passes one; the templates sheet does not.
    /// - Parameter weekdaysOnly: Applies to every template whose natural cadence
    ///   is daily, and is ignored by `weeklyReview`, which is weekly by
    ///   definition. Defaulted to `true` because the morning brief is the one
    ///   the onboarding flow creates and a 07:30 alert on a Sunday is how a
    ///   person decides they do not want a morning brief.
    /// - Parameter calendar: Accepted and not used, deliberately. A `Recurrence`
    ///   is a *rule* and carries no calendar — `FireSequence` applies the
    ///   device's at evaluation time, which is the whole reason a 09:00 task
    ///   survives a flight. Taking the parameter anyway keeps this signature
    ///   stable for the first template that does need one, such as "the first
    ///   working day of the month", and keeps the call site reading like every
    ///   other date-shaped API in the package.
    public func task(
        now: Date = Date(),
        calendar: Calendar = .current,
        time: TimeOfDay? = nil,
        weekdaysOnly: Bool = true
    ) -> ScheduledTask {
        ScheduledTask(
            title: title,
            body: body,
            recurrence: recurrence(time: time ?? defaultTime, weekdaysOnly: weekdaysOnly),
            // `createdAt` is what `settledThrough` starts at, and that single
            // line is what stops a 07:30 task created at 14:00 from firing the
            // instant it is saved. Passed in rather than read from the clock so
            // a test can assert the next firing without racing it.
            createdAt: now
        )
    }

    func recurrence(time: TimeOfDay, weekdaysOnly: Bool) -> Recurrence {
        switch self {
        case .weeklyReview:
            .weekly(days: [.sunday], at: time)
        case .morningBrief, .eveningWrapUp, .overdueWatcher, .sleepWatcher:
            weekdaysOnly ? .weekdays(at: time) : .daily(at: time)
        }
    }

    /// The template a saved task came from, if any.
    ///
    /// Matched on the title, which is the only thing a `ScheduledTask` carries
    /// that could say. That is a deliberate limit rather than an oversight: a
    /// stored `template` field would be a second source of truth about a task
    /// the user is free to rename, retime and rewrite until it has nothing to
    /// do with the card it started from, and the one thing it is used for — not
    /// offering a routine somebody already has, and the icon on its card — is
    /// better served by the name they are looking at than by a provenance they
    /// cannot see.
    public static func matching(_ task: ScheduledTask) -> RoutineTemplate? {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { template in
            ([template.title] + template.formerTitles).contains {
                $0.caseInsensitiveCompare(title) == .orderedSame
            }
        }
    }
}
