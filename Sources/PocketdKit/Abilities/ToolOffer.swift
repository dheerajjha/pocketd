import Foundation

/// Whether a question would have been answered by an ability that is switched
/// off, and which one.
///
/// The failure this exists for: somebody types "what's on tomorrow?" with the
/// calendar switch off, and the model — which has no calendar and no way to say
/// so — invents a day. The three abilities that make this app something other
/// than a local chat box default off and live two thirds of the way down
/// Settings, so the person most likely to want one is the person who has never
/// seen it. The moment it would have helped is the moment worth saying it
/// exists, and it is also the only moment the user can judge the trade: they
/// have just said what they want it for.
///
/// ## Taken from `CapabilityRouter`, and the one thing inverted
///
/// The router answers a near-identical question — which capability is this
/// sentence about — without a model round, and its mechanics are borrowed
/// whole: lowercased runs of letters and digits, cues matched as whole words
/// rather than as prefixes, and every inflection written out because a form
/// nobody listed is a form nobody matches. Its tests record the bug that taught
/// this repo the rule: the stem `weigh` matched `weightlessness`, and a
/// sentence about space armed the health tools.
///
/// What is inverted is the direction to be wrong in. The router fails OPEN: a
/// miss there is the model announcing it cannot see a calendar that is sitting
/// right there, and a false positive is a slightly smaller context window. Here
/// the two costs trade places, and not by a little. A miss is silence, which is
/// exactly what ships today. A false positive is a privacy-first app
/// volunteering to read somebody's Health data because they asked how heavy
/// their suitcase was. So every rule below is built to fail closed:
///
/// - Three signals, never one. A cue for the data, an *ask* — a question or an
///   imperative — and something that makes the sentence about the asker's own
///   life. Two of the three is silence.
/// - Where a word is ambiguous, the cue is a phrase that settles it. `weight`
///   is not a cue and `my weight` is; `heart` is not a cue and `heart rate` is;
///   `steps` is not a cue and `how many steps` is. Health goes furthest: no
///   single ordinary English word cues it at all, because a wrong health offer
///   is the one that makes this app feel like it is watching.
/// - Exactly one, or nothing. A sentence that cued two switched-off abilities
///   is a sentence this understood less well than it looks, and picking between
///   them would be guessing at the one moment guessing costs most.
///
/// The misses that buys are real, and worth naming rather than discovering:
/// "how much exercise did I get", "what's on my plate tomorrow", "I wonder
/// what's on tomorrow" (not an ask), anything in a language other than English,
/// and every sentence where a cue and its window sit more than a phrase apart.
/// All of them fall through to today's behaviour, which is no offer at all.
public struct ToolOffer: Sendable, Equatable {

    /// Which ability to offer. Always one that reads personal data: the server
    /// is on the same `Ability` list and can never be offered here, because no
    /// sentence someone types at an assistant is a request for a listening
    /// socket.
    public var ability: Ability

    /// What to put on screen. One sentence, and it offers the switch rather
    /// than the answer.
    ///
    /// Computed rather than stored so that no caller can build an offer whose
    /// words disagree with the switch it flips, and built from `Ability.noun`
    /// so the abilities screen and this sentence cannot end up calling the same
    /// data two different things.
    ///
    /// It says "check your health data" and never "tell you how you slept".
    /// Turning the switch on is where iOS gets asked, and HealthKit never
    /// reports whether a *read* was granted — a refusal and an empty store are
    /// the same silence, which is why `Ability.grantIsReportedByOS` is false for
    /// exactly that one. A sentence promising the figure would be promising
    /// something this app has no way to know it can deliver.
    public var sentence: String { "I can check \(ability.noun) — turn that on?" }

    public init(ability: Ability) {
        self.ability = ability
    }

    /// Which switches are on, in the order `AppModel.registrations` takes them,
    /// so the call site reads the same as the line above it.
    public struct Enabled: Sendable, Equatable {
        public var calendar: Bool
        public var reminders: Bool
        public var health: Bool

        public init(calendar: Bool, reminders: Bool, health: Bool) {
            self.calendar = calendar
            self.reminders = reminders
            self.health = health
        }

        public func isOn(_ ability: Ability) -> Bool {
            switch ability {
            case .calendar: calendar
            case .reminders: reminders
            case .health: health
            // Not reachable: `decide` only ever considers the abilities that
            // read personal data. Answering yes rather than trapping means that
            // if that filter is ever loosened, the result is one missed offer
            // and not a suggestion to turn on a server nobody mentioned.
            case .localServer: true
            }
        }
    }

    /// The offer to make for one message, or nothing — which is the answer for
    /// nearly every message, and is meant to be.
    ///
    /// - Parameter message: What the user typed on this turn, and only this
    ///   turn. Not the conversation: an offer arriving three turns after the
    ///   question that prompted it has lost the thing that made it welcome,
    ///   which is that the user is still thinking about what they just asked
    ///   for. `CapabilityRouter.decide(_: [ChatMessage])` reads the last user
    ///   turn for the same reason.
    public static func decide(for message: String, enabled: Enabled) -> ToolOffer? {
        let words = tokens(in: message)
        guard !words.isEmpty, isAsk(words, message: message) else { return nil }

        // Switched-off first, and the count taken after. An ability the user has
        // already turned on is not a candidate, so it also cannot be the second
        // cue that silences the one genuine offer: "what's on my calendar, and
        // how did I sleep?" with the calendar already on is an unambiguous
        // request to turn on health.
        let cued = Ability.allCases.filter {
            $0.readsPersonalData && !enabled.isOn($0) && isCued($0, by: words)
        }
        guard cued.count == 1, let ability = cued.first else { return nil }
        return ToolOffer(ability: ability)
    }
}

// MARK: - Matching

private extension ToolOffer {

    /// Lowercased runs of letters and digits, with apostrophes removed rather
    /// than split on.
    ///
    /// The one place this parts company with `CapabilityRouter`, which splits on
    /// them because all it needs from "what's" is the token "what". Phrases here
    /// are matched as contiguous runs, and splitting invents a token — the "s"
    /// in `what`, `s`, `on` — that no phrase can be written across.
    ///
    /// Both apostrophes, and that is not tidiness. An iPhone keyboard inserts
    /// U+2019 by default, so stripping only the ASCII one gives a file whose
    /// tests pass on a Mac and whose feature never fires on the device it
    /// shipped to.
    static func tokens(in message: String) -> [String] {
        message
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Whether the sentence asks for something, as against mentioning it.
    ///
    /// "My meeting went badly today" names the calendar as plainly as any
    /// question does and wants nothing from it; an offer there is an app
    /// interrupting a sentence about somebody's afternoon to talk about
    /// permissions. So: a question mark, an opening interrogative — how most
    /// people type on a phone, where the mark is one more tap — or an imperative
    /// in first position.
    static func isAsk(_ words: [String], message: String) -> Bool {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return true }
        guard let first = words.first else { return false }
        return interrogatives.contains(first) || imperatives.contains(first)
    }

    static func isCued(_ ability: Ability, by words: [String]) -> Bool {
        guard !(blocked[ability] ?? []).contains(where: { contains($0, in: words) }) else { return false }
        // The self-evident pairs carry their own "whose" and their own "when",
        // so they are the one route that does not need a possessive: "what's on
        // tomorrow?" is the sentence this file exists for and it has neither.
        if (selfEvident[ability] ?? []).contains(where: { contains($0, in: words) }) { return true }
        guard words.contains(where: selfWords.contains) else { return false }
        if words.contains(where: { (wordCues[ability] ?? []).contains($0) }) { return true }
        return (phraseCues[ability] ?? []).contains { contains($0, in: words) }
    }

    /// A contiguous run, never a subsequence. "my weight" must not match "my
    /// suitcase's weight", which is the sentence the whole phrase mechanism was
    /// built to stay silent for.
    static func contains(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        return (0...(words.count - phrase.count)).contains { words[$0...].starts(with: phrase) }
    }

    static func split(_ list: [String]) -> [[String]] {
        list.map { $0.split(separator: " ").map(String.init) }
    }
}

// MARK: - Vocabulary

private extension ToolOffer {

    /// Openers that make a sentence a question without a question mark.
    /// Narrower than the router's list by one word: `any` is missing, because
    /// "any luck with the weight of that suitcase" is not a question about
    /// anybody's body.
    static let interrogatives: Set<String> = [
        "what", "whats", "when", "where", "which", "who", "whose", "why", "how",
        "do", "does", "did", "is", "are", "am", "was", "were",
        "can", "could", "should", "shall", "will", "would", "have", "has", "had"
    ]

    /// Imperatives, and only in first position. Mid-sentence they are ordinary
    /// verbs: "read me a story before I sleep" is not a request for HealthKit.
    ///
    /// `remind` is deliberately absent, here and from every cue list. The
    /// reminders tool reads incomplete reminders and cannot write one, so
    /// "remind me to buy milk" is a request this offer could not honour — and
    /// leaving the verb out is also what makes "remind me of the time we met"
    /// silent without needing a rule to make it so.
    static let imperatives: Set<String> = ["check", "show", "tell", "list", "look"]

    /// What makes a sentence about the asker rather than about the world.
    ///
    /// Stricter than the router, which takes a time word as evidence that a
    /// question is personal. "How many days are in a calendar year?" is a
    /// question, mentions a calendar and names a span of time, and has nothing
    /// to do with anybody's Tuesday.
    static let selfWords: Set<String> = [
        "my", "mine", "our", "ours", "i", "im", "ive", "me", "myself", "we", "us"
    ]

    /// Unambiguous nouns. Each of these means its ability in very nearly every
    /// sentence an English speaker types, which is the bar for being here rather
    /// than in `phraseCues`.
    ///
    /// Health's entries are all jargon — nobody reaches for "hrv" by accident —
    /// and that is the whole of health's word list on purpose. See the type's
    /// note: no ordinary English word may cue health on its own.
    static let wordCues: [Ability: Set<String>] = [
        .calendar: [
            "calendar", "calendars", "meeting", "meetings",
            "appointment", "appointments", "agenda", "itinerary",
            "schedule", "schedules", "scheduled"
        ],
        .reminders: [
            "reminder", "reminders", "overdue", "todo", "todos",
            "errand", "errands", "groceries"
        ],
        // Jargon only. "workout" and "workouts" were here and are ordinary
        // English — "a workout plan", "workouts for beginners", "my code needs
        // a workout" — so a bare match on either offered to read somebody's
        // Health data because they asked a training question. They moved to
        // the phrase list, where a possessive settles them.
        .health: ["hrv", "vo2", "heartrate"]
    ]

    /// Cues whose single word means something else often enough to be dangerous,
    /// written as the phrase that settles it.
    ///
    /// This is the `weigh`/`weightlessness` lesson taken one step further than
    /// the router takes it. Narrowing a stem to a whole word saves
    /// "weightlessness"; it does not save "what's the weight of my suitcase?",
    /// which is a whole-word match, a question, and has a possessive in it. The
    /// only thing separating it from "what's my weight?" is which word the
    /// possessive is attached to — so the possessive goes inside the cue.
    static let phraseCues: [Ability: [[String]]] = [
        .calendar: split([
            "am i free", "am i busy", "my day", "my week"
        ]),
        .reminders: split([
            "to do list", "task list", "shopping list", "grocery list",
            "my tasks", "tasks left", "tasks are left", "tasks do i have",
            "due today", "due tomorrow", "due tonight", "due this week", "due soon"
        ]),
        .health: split([
            "heart rate", "my pulse", "blood oxygen",
            "my sleep", "how did i sleep", "did i sleep", "i slept", "hours of sleep",
            // NOT "how many steps" on its own: "how many steps are in my build
            // pipeline" and "how many steps to fix this" are both questions,
            // both have the phrase, and neither is about a person. Every
            // surviving step cue carries something that only makes sense about
            // a body.
            "my steps", "step count", "steps today", "steps this week",
            "how many steps did i", "how many steps have i",
            "my weight", "do i weigh", "i weigh", "weighed myself",
            "lost weight", "gained weight",
            "how far did i run", "how far did i walk", "calories did i burn",
            "my workout", "my workouts", "workout yesterday", "workouts this week",
            // "what workouts did i do this week" — the possessive is carried by
            // "did i", not by "my", and the words between break contiguity with
            // "workouts this week".
            "workout did i", "workouts did i", "workout i did", "workouts i did",
            "did i work out", "did i exercise"
        ])
    ]

    /// Openers that ask what is happening. Half a cue each: "what's on" is
    /// television, and "tomorrow" is any sentence at all.
    static let scheduleOpeners = [
        "whats on", "what is on", "whats on for", "anything on", "anything on for",
        "do i have anything on", "what do i have on", "what have i got on", "whats booked"
    ]

    /// The same for the list: "what's due on the mortgage" is not a reminder.
    static let dueOpeners = [
        "whats due", "what is due", "anything due", "whats overdue", "anything overdue",
        "what do i have due", "anything left to do"
    ]

    /// The day a question is about. Bare "week" is missing on purpose — it is
    /// the second word of "calendar week".
    static let days = [
        "today", "tonight", "tomorrow", "this week", "this weekend",
        "this morning", "this afternoon", "this evening", "next week",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
    ]

    /// Cues that say whose and when by themselves, and so are the one route past
    /// the possessive test.
    ///
    /// "What's on tomorrow?" is the sentence this whole file exists for, and it
    /// names nothing — no calendar, no meeting, no appointment, no "my". What
    /// makes it a schedule question is the pairing: an opener asking what is
    /// happening, and a day for it to happen on. The pairs are built rather than
    /// listed because nine openers by sixteen days is a hundred and forty-four
    /// lines to keep in step by hand, and the one that goes missing is silent.
    ///
    /// Health has none. Every genuine health question names the asker — "how did
    /// I sleep", "what's my resting heart rate" — so the possessive costs health
    /// nothing and is the cheapest guard it could have.
    static let selfEvident: [Ability: [[String]]] = [
        .calendar: split(scheduleOpeners.flatMap { opener in days.map { "\(opener) \($0)" } }),
        .reminders: split(dueOpeners.flatMap { opener in days.map { "\(opener) \($0)" } })
    ]

    /// Phrases that cancel a cue.
    ///
    /// Only the calendar has any, and that is the honest state of things rather
    /// than an oversight: a block list patches a cue that was written too wide,
    /// so the other two vocabularies were narrowed until nothing needed
    /// patching. The calendar cannot be narrowed the same way, because
    /// "calendar" really is the word for the user's own calendar *and* the word
    /// for a span of time, "what's on tomorrow" really is what a British
    /// newspaper prints above the television listings, and a meeting point is a
    /// place rather than a meeting.
    static let blocked: [Ability: [[String]]] = [
        .calendar: split([
            "calendar year", "calendar years", "calendar month", "calendar months",
            "calendar week", "calendar weeks", "calendar quarter",
            "calendar day", "calendar days",
            "on tv", "on telly", "on netflix", "on iplayer", "on the radio", "at the cinema",
            "meeting point", "meeting points"
        ])
    ]
}
