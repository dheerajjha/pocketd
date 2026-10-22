import Foundation

/// When to ask for a rating, and — mostly — when not to.
///
/// The app has never asked. That is why it has no ratings, and ratings are a
/// ranking input, so the absence compounds: Locally AI has 1,598 and Enclave
/// 1,062, both free, both the same shape of app. Nothing else in the listing
/// closes a gap like that, because nothing else in the listing is voted on by
/// other people.
///
/// Apple's own limit is three prompts per user per 365 days and the system
/// silently swallows the rest. That ceiling is the reason this type exists
/// rather than a one-line call at a convenient point: a prompt spent on a
/// mediocre moment is not merely wasted, it is one of three, and the request
/// that would have landed later never gets shown.
///
/// So the rule is that we ask after the app has done the thing it is FOR, more
/// than once, and not on the first day.
public struct ReviewMoment: Sendable, Equatable {

    /// Successful answers from the person's own data before asking.
    ///
    /// Two kinds count, and only these: a tool-backed answer in the
    /// conversation, and a tile's page that showed something from Calendar,
    /// Reminders or Health (see `reportsSomething` below). Not messages: a
    /// model answering a general question is what every app in the category
    /// does; an answer that read the user's own calendar and got it right is
    /// this app working, and it is the only moment where "was that useful?"
    /// has an obviously good answer.
    ///
    /// The pages count because Today, not the conversation, is the home since
    /// 1.1, and they need no brain. Counting only the conversation left the
    /// question unreachable for everybody who reads their day and never asks.
    ///
    /// Three rather than one. One could be luck, and the first is often the
    /// user testing whether it works at all rather than getting value from it.
    public static let answersBeforeAsking = 3

    /// Days since first launch before asking at all.
    ///
    /// A prompt on day one reads as a shakedown — the app has not yet been
    /// useful enough to have earned the question, and the person most likely to
    /// be in the app on day one is someone still deciding whether to keep it.
    public static let daysBeforeAsking = 2

    /// Our own cooling-off, under Apple's.
    ///
    /// Apple allows three a year and we intend to use roughly one. Somebody who
    /// declined in March should not meet it again in April; if they liked it
    /// enough to rate it, they already did.
    public static let daysBetweenAsks = 120

    /// What has to be remembered between launches.
    public struct State: Sendable, Equatable, Codable {
        public var firstLaunch: Date?
        public var toolBackedAnswers: Int
        public var lastAsked: Date?

        public init(firstLaunch: Date? = nil, toolBackedAnswers: Int = 0, lastAsked: Date? = nil) {
            self.firstLaunch = firstLaunch
            self.toolBackedAnswers = toolBackedAnswers
            self.lastAsked = lastAsked
        }
    }

    /// Whether this is the moment.
    ///
    /// A pure function of remembered state so that every rule above can be
    /// tested without a simulator, a store, or waiting two days.
    public static func shouldAsk(
        _ state: State,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard state.toolBackedAnswers >= answersBeforeAsking else { return false }

        // No first launch recorded means an install that predates this code.
        // Fails closed: better to wait for the next answer than to ask
        // somebody on what is, as far as we can tell, their first day.
        guard let firstLaunch = state.firstLaunch else { return false }
        guard days(from: firstLaunch, to: now, calendar: calendar) >= daysBeforeAsking else { return false }

        guard let lastAsked = state.lastAsked else { return true }
        return days(from: lastAsked, to: now, calendar: calendar) >= daysBetweenAsks
    }

    /// Whole days between two instants, floored, and never negative.
    ///
    /// Clamped because a user who moves their clock backwards would otherwise
    /// produce a negative gap that compares as "long enough ago" against a
    /// signed threshold. Counted in calendar days rather than 86,400-second
    /// units for the reason `MomentPhrase` documents: a day is not always
    /// twenty-four hours.
    static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        guard end > start else { return 0 }
        return max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
    }
}

// MARK: - Pages that count

// A tile's page counts as an answer when it showed the person something of
// their own: the source is connected and there was something in it. A "Turn on"
// link is a permission problem and an empty day is an absence, by the same rule
// as `AnswerCard.reportsSomething` — asking for a rating straight after either
// is how an app earns a one-star.

public extension DayAgenda {
    var reportsSomething: Bool { availability.isReadable && !isEmpty }
}

public extension ReminderAgenda {
    var reportsSomething: Bool { availability.isReadable && !isEmpty }
}

public extension SleepDetail {
    /// Seven rows are listed whenever Health is connected, nights or not, so
    /// the rows alone say nothing; a night with a length does.
    var reportsSomething: Bool {
        availability.isReadable && (lastNight != nil || nights.contains { $0.duration != nil })
    }
}

public extension ActivityDetail {
    var reportsSomething: Bool {
        availability.isReadable && (today != nil || days.contains { $0.steps != nil })
    }
}
