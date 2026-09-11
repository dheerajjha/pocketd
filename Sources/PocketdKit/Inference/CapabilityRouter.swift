import Foundation

/// Which capabilities one question plausibly needs, so that asking about sleep
/// does not also pay for the alarm schema.
///
/// No model round, and that is the constraint the whole design follows from.
/// Deciding which tools to arm by asking the model would cost a full prefill
/// and a generation — seconds, and more tokens than the schemas it was meant to
/// save — and it would put an attacker-controlled sentence in charge of which
/// of the user's data the next turn can reach. So this is keywords, stems and a
/// sum: a few thousand prefix comparisons, cheap enough to run on every turn,
/// and the same answer every time it is asked, which a sampled model could not
/// promise.
///
/// It fails open in one specific direction. A question that needed a tool and
/// got none is a visible failure — the model says it cannot see the calendar
/// while the calendar sits there — where a question that armed one capability
/// too many merely has a slightly smaller window. So when nothing in the words
/// names a capability but the question is plainly about the user's own life,
/// every capability is offered in rank order and `CapabilityBudget` truncates.
/// Only a question with no such signal at all — "hello", "write a poem about
/// the sea" — arms nothing.
///
/// The vocabulary is English, which is a real limit rather than an oversight:
/// there is no cheap language-independent way to tell "how did I sleep" from
/// "write me a sonnet", and a router that guessed would spend the context it
/// exists to save. A question in another language falls through to the
/// fail-open test and, failing that, to no tools — the same place a model that
/// cannot use tools ends up.
public enum CapabilityRouter {

    /// What one prompt asked for, and how much that answer is worth.
    ///
    /// Kept as reasons rather than a bare array for the reason `ToolGate` is:
    /// the difference between "the question named the calendar" and "nothing
    /// was named, so here is everything" changes what a caller should do with a
    /// tie, and collapsing the two would hide the only case where the router
    /// admits it is guessing.
    public enum Decision: Sendable, Equatable {
        /// The words named these, most strongly argued first.
        case named([CapabilityGroup])
        /// Nothing here named a capability. These are the ones the question
        /// could be about, in rank order, for the budget to truncate — every
        /// capability when only a possessive said the question was personal,
        /// and the day's three when only a time word did.
        case unsure([CapabilityGroup])
        /// Nothing here that any tool could answer.
        case unrelated

        /// The only thing the engine asks.
        public var groups: [CapabilityGroup] {
            switch self {
            case let .named(groups), let .unsure(groups): groups
            case .unrelated: []
            }
        }
    }

    /// The weight of a word that belongs to one capability and no other —
    /// "snooze", "groceries", "appointment".
    private static let namingWeight = 3

    /// The weight of a time word, which sharpens an ordering rather than
    /// deciding one. Three of them still lose to a single naming word.
    private static let shadedWeight = 1

    /// Prefix-matched at the start of a word, so `remind` covers reminder,
    /// reminders and reminded without listing the three.
    ///
    /// An entry earns a place here only if every common word beginning with it
    /// still means the capability. `remind` opens nothing but reminders, where
    /// `heart` opens hearth and heartbreaking, `step` opens Stephen, `task`
    /// opens taskbar, `chore` opens choreography and `alarm` opens alarming —
    /// so those live in `wholeWords` below with their forms written out.
    /// `stemsDoNotLeak` is what keeps this paragraph true rather than
    /// aspirational: it types the sentences each leak was found in.
    ///
    /// Losing an inflection to that move costs far less than the leak does. A
    /// question about the user's own day carries a possessive or a pronoun and
    /// falls open whichever list its cue is in, so the miss is caught; the
    /// sentences a stem leaks into — "write a heartbreaking story", "a busybody
    /// neighbour" — are the creative-writing prompts this file promises will
    /// arm nothing, and nothing downstream is going to catch those.
    private static let stems: [CapabilityGroup: [String]] = [
        .calendar: ["calendar", "meeting", "appointment", "schedul", "agenda", "diary", "booked", "booking"],
        .reminders: ["remind", "todo", "errand", "grocer", "shopping", "deadline", "overdue"],
        // Widened when the health focuses went from four to five. Prefixes are
        // chosen to survive their own inflections — `breath` catches breathing,
        // `mindful` catches mindfulness — while the ones that would collide
        // with ordinary words live in the whole-word set below.
        .health: [
            "sleep", "slept", "workout", "exercis", "calorie", "hydrat", "fitness",
            "vo2", "mindful", "meditat", "breath", "oxygen",
            "distance", "hiked", "cardio"
        ],
        .alarms: ["snooze"],
        .timers: ["timer", "stopwatch", "countdown"]
    ]

    /// Cues that must match a whole word, because each is the opening of a
    /// common word that means something else: `list` starts `listen`, `free`
    /// starts `freelance`, `event` starts `eventually`, `due` starts `duet`,
    /// `wake` starts `wakeboard`, `heart` starts `hearth`, `step` starts
    /// `Stephen`, `task` starts `taskbar`, `busy` starts `busybody`, `chore`
    /// starts `choreography`, `alarm` starts `alarming`, `weight` starts
    /// `weightless` and `invite` starts nothing but `inviting`, which is a word
    /// about sofas as often as about meetings. Prefix-matching these is how a
    /// router starts arming the calendar for "what happened eventually".
    ///
    /// Every form has to be written out, because there is no stem behind these
    /// to catch the rest: `walk` here means walk, walks, walked and walking,
    /// and a form nobody listed is a form nobody arms.
    private static let wholeWords: [CapabilityGroup: [String]] = [
        .calendar: [
            "event", "events", "free", "meet", "plan", "plans", "planned", "busy",
            "invite", "invites", "invited", "invitation", "invitations"
        ],
        .reminders: ["list", "lists", "due", "task", "tasks", "chore", "chores"],
        .health: [
            "run", "ran", "runs", "running", "active", "activity", "activities",
            "heart", "hearts", "heartrate", "step", "steps",
            "walk", "walks", "walked", "walking", "weight", "weights",
            "weigh", "weighed", "kilos", "kilograms", "stood", "standing"
        ],
        .alarms: ["alarm", "alarms", "wake", "waking", "woke", "oversleep", "overslept"],
        .timers: []
    ]

    /// Time words, which name no capability on their own and several together.
    ///
    /// "What's on today?" is the calendar and the reminders and the day's
    /// activity, and a router that picked one of the three would be guessing
    /// with a confident face — so when nothing else is named, all three are.
    ///
    /// But a time word cannot *introduce* a capability that the rest of the
    /// sentence did not ask for. "What's on my calendar tomorrow" is one
    /// capability and "how did I sleep this week" is one capability, and
    /// crediting the time word regardless would arm three schemas for each of
    /// them, which is the exact cost this type exists to avoid.
    private static let temporal = [
        "today", "tonight", "tomorrow", "yesterday",
        "week", "weeks", "weekend", "morning", "afternoon", "evening", "upcoming"
    ]

    /// Alarms and timers are absent on purpose. "Tomorrow" says nothing about a
    /// stopwatch, and crediting it would arm two schemas for every question
    /// about the day.
    private static let temporalGroups: [CapabilityGroup] = [.calendar, .reminders, .health]

    /// Words that make a sentence about the asker's own life rather than about
    /// the world. A possessive is enough on its own; a bare pronoun is not,
    /// because "write me a poem" is not a question about the user.
    private static let possessives: Set<String> = ["my", "mine", "our", "ours"]
    private static let pronouns: Set<String> = ["i", "me", "we", "us", "myself", "ourselves"]

    /// Openers that make a sentence a question without a question mark, which
    /// is how most people type on a phone.
    private static let interrogatives: Set<String> = [
        "what", "whats", "when", "where", "which", "who", "whose", "why", "how",
        "do", "does", "did", "is", "are", "am", "was", "were",
        "can", "could", "should", "shall", "will", "would", "have", "has", "had", "any"
    ]

    public static func decide(_ prompt: String) -> Decision {
        let words = tokens(in: prompt)
        guard !words.isEmpty else { return .unrelated }

        var scores: [CapabilityGroup: Int] = [:]
        for group in CapabilityGroup.allCases {
            var total = 0
            for word in words {
                total += (stems[group] ?? []).filter { word.hasPrefix($0) }.count * namingWeight
                total += (wholeWords[group] ?? []).filter { word == $0 }.count * namingWeight
            }
            if total > 0 { scores[group] = total }
        }
        // A time word is credited to whatever the sentence already named, and
        // only stands in for a capability of its own when it named nothing.
        let named = !scores.isEmpty
        let credited = named ? Array(scores.keys) : temporalGroups
        for word in words where temporal.contains(word) {
            for group in credited { scores[group, default: 0] += shadedWeight }
        }

        if !scores.isEmpty {
            let ordered = scores.sorted { left, right in
                // Rank breaks the tie rather than the dictionary's iteration
                // order, which is seeded per process: without this the same
                // question would arm the same capabilities in a different order
                // on every launch, and the budget truncates by order.
                left.value == right.value
                    ? left.key.rank < right.key.rank
                    : left.value > right.value
            }.map(\.key)
            // A time word sharpens an ordering; it cannot name a capability.
            // "What's on today?" argued for three of them and named none, and
            // `.named` there would claim a certainty the words do not carry —
            // in the one case the caller most needs to know it is a guess.
            return named ? .named(ordered) : .unsure(ordered)
        }

        guard asksAboutTheAsker(words, prompt: prompt) else { return .unrelated }
        return .unsure(CapabilityGroup.allCases)
    }

    /// The last thing the user said, which is the only turn worth routing on.
    ///
    /// Not the whole conversation: a calendar question three turns back would
    /// keep the calendar armed through everything after it, and the schemas are
    /// charged again on every one of those prompts. A follow-up that still
    /// needs the tool nearly always says so — "and tomorrow?" carries its own
    /// cue — and one that does not is a miss the fail-open test still catches.
    public static func decide(_ messages: [ChatMessage]) -> Decision {
        guard let last = messages.last(where: { $0.role == .user }) else { return .unrelated }
        return decide(last.content)
    }

    private static func asksAboutTheAsker(_ words: [String], prompt: String) -> Bool {
        if words.contains(where: possessives.contains) { return true }
        guard words.contains(where: pronouns.contains) else { return false }
        // A pronoun alone is not enough, but a pronoun in a question is: "do I
        // have anything on" has no capability word in it and is exactly what
        // this path exists for. The cost is that "can you write me a poem?"
        // also arms whatever fits, which is the direction this is meant to err
        // in — an unnecessary schema is a smaller window, a missing one is an
        // answer that says the calendar cannot be seen.
        return isQuestion(words, prompt: prompt)
    }

    private static func isQuestion(_ words: [String], prompt: String) -> Bool {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return true }
        return words.first.map(interrogatives.contains) ?? false
    }

    /// Lowercased runs of letters and digits, which is all the matching needs.
    ///
    /// Apostrophes split rather than being stripped, so "what's" becomes
    /// "what" and "s" — and "what" is the token the interrogative test wants.
    /// "whats" is in that table as well, for the phone keyboard that does not
    /// insert the apostrophe and the person who does not go back for it.
    private static func tokens(in prompt: String) -> [String] {
        prompt
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

public extension CapabilityBudget {
    /// What to register for one question: routed, then truncated.
    ///
    /// The two steps in the one order that works. Routing first means the
    /// budget spends its ceiling on the capabilities the question argued for
    /// rather than on the highest-ranked ones in general, which is the whole
    /// saving — a sleep question that pays for the calendar has routed nothing.
    ///
    /// `ToolGate` still comes before both. A model that cannot work the tool
    /// protocol is handed nothing at all, and neither of these runs.
    func plan(for prompt: String, from tools: [CapabilityTool]) -> Plan {
        admit(tools, routedTo: CapabilityRouter.decide(prompt).groups)
    }

    func plan(for messages: [ChatMessage], from tools: [CapabilityTool]) -> Plan {
        admit(tools, routedTo: CapabilityRouter.decide(messages).groups)
    }
}
