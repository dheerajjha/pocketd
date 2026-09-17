import Foundation

/// What the Today widget is told, and deliberately nothing more.
///
/// The sibling of `SchedulePublication`, written to the same App Group by the
/// same discipline, and it has to answer that type's argument rather than ignore
/// it. `SchedulePublication` carries **no run text at all** — not the output,
/// not the lines, not the headline — because a home screen is permanent, lands
/// in screenshots, and is read over shoulders by people who were never shown a
/// permission prompt. This type carries a sentence about the owner's day and the
/// title of their next meeting. That is a real difference and it needs a reason.
///
/// The reason is what each widget is *for*. The schedules widget answers "is
/// something waiting for me", and the headline it was refused would have been a
/// watcher report — five lines of event titles written by whoever sent the
/// invites, routinely naming other people, none of whom chose to be on anybody's
/// home screen. The Today widget's entire purpose is the brief: a person adds it
/// because they want the first sentence of their own day where they can see it,
/// and a version that withheld the sentence would be a blank rectangle.
///
/// What is bounded is how much crosses. One sentence, not the paragraph. One
/// event title, not the day. A count of what is due, not the list — a number
/// discloses nothing, and "3 due" is the whole of what a glance wants. Sleep and
/// steps are absent entirely: they are the most sensitive numbers this app
/// holds, a widget is the least private surface it has, and nobody needs their
/// step count on the lock screen badly enough to put it there by default.
///
/// Every string in here has already been through `PromptSanitiser` on its way
/// into `TodaySnapshot`, so a calendar event cannot ship control tokens into a
/// second process through this file.
public struct WidgetBrief: Codable, Sendable, Equatable {

    /// The same group as the schedules widget, and referenced rather than
    /// repeated. One literal, in one place, that the two entitlements files and
    /// the App ID all have to agree with; a second copy of it here would be a
    /// second thing to get wrong on the one build where it is overridden.
    public static let appGroup = SchedulePublication.appGroup
    public static let filename = "today-brief.json"

    /// "Good morning, Dheeraj" — no trailing stop, so the widget can end it the
    /// way its own layout wants.
    public var greetingLine: String
    /// The first sentence of the brief. The medium widget's body; the small one
    /// leaves it out.
    public var firstSentence: String
    public var nextEventTitle: String?
    /// An instant, not "in 2 hours".
    ///
    /// For the reason `SchedulePublication.Upcoming.firing` gives: a widget's
    /// timeline is reloaded on the system's schedule and not ours, so a rendered
    /// relative phrase is stale the moment it is written, while
    /// `Text(_:style:.relative)` counts down on its own between reloads.
    public var nextEventTime: Date?
    /// How many reminders are due today. A number and not the titles.
    public var dueCount: Int
    public var generatedAt: Date

    public init(
        greetingLine: String,
        firstSentence: String,
        nextEventTitle: String? = nil,
        nextEventTime: Date? = nil,
        dueCount: Int = 0,
        generatedAt: Date
    ) {
        self.greetingLine = greetingLine
        self.firstSentence = firstSentence
        self.nextEventTitle = nextEventTitle
        self.nextEventTime = nextEventTime
        self.dueCount = dueCount
        self.generatedAt = generatedAt
    }
}

// `WidgetBrief.make(from:)` lives in WidgetBrief+Make.swift, not here, and the
// split is load-bearing rather than tidy — the same split, for the same reason,
// as SchedulePublication's. THIS file and its store are compiled into the widget
// extension directly instead of linking PocketdKit, because the kit depends on
// FlyingFox: an HTTP server, in a process with a ~30 MB ceiling that only ever
// reads one small JSON file. Keeping this file free of every PocketdKit type is
// what makes that possible, and one reference to `DailyBrief` would end it.
// Nothing the widget does needs that initialiser: only the app publishes; the
// widget reads.
