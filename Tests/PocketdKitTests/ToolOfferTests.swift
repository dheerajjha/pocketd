import Foundation
import Testing
@testable import PocketdKit

/// The half of this feature that decides whether it is charming or creepy.
///
/// Offering to read a calendar at the moment somebody asked what is on tomorrow
/// is the whole point. Offering to read their Health data because they asked
/// how heavy a suitcase was is the thing that makes a privacy-first app feel
/// like it is listening for an excuse — and the two are one keyword list apart.
///
/// So the near misses below are the load-bearing half of this file, not the
/// trimmings. The positives are written from sentences people type, and a
/// vocabulary written only from those passes its own tests by construction; the
/// misses are what stop it. Several of them are recorded failures of the same
/// family in `CapabilityRouterTests` — `weigh` matching `weightlessness` — and
/// the rest are the sentences that family suggests: the word is there, the
/// possessive is there, the question mark is there, and the intent is not.
@Suite("Tool offers")
struct ToolOfferTests {

    private func offer(
        _ message: String,
        calendar: Bool = false,
        reminders: Bool = false,
        health: Bool = false
    ) -> ToolOffer? {
        ToolOffer.decide(
            for: message,
            enabled: .init(calendar: calendar, reminders: reminders, health: health)
        )
    }

    @Test("the question this exists for offers the calendar")
    func theMotivatingQuestion() {
        // Today this is answered by a model that has no calendar, cannot say so,
        // and invents a day rather than admitting it. Note that it names
        // nothing: no calendar, no meeting, no "my". The opener and the day are
        // what make it a question about a schedule.
        #expect(offer("What's on tomorrow?")?.ability == .calendar)
        #expect(offer("What's on today?")?.ability == .calendar)
        #expect(offer("Anything on this week?")?.ability == .calendar)
        #expect(offer("Do I have anything on Friday?")?.ability == .calendar)
    }

    @Test("genuine intent is offered, one ability at a time")
    func genuineIntent() {
        let expected: [(String, Ability)] = [
            ("What's on my calendar tomorrow?", .calendar),
            ("Do I have any meetings on Friday?", .calendar),
            ("Am I free on Thursday?", .calendar),
            ("What does my week look like?", .calendar),
            ("When is my next appointment?", .calendar),
            ("Check my calendar", .calendar),

            ("What's due today?", .reminders),
            ("Do I have anything overdue?", .reminders),
            ("What's on my shopping list?", .reminders),
            ("Show me my reminders", .reminders),
            ("What tasks do I have left?", .reminders),

            ("How did I sleep last night?", .health),
            ("How many steps did I do today?", .health),
            ("What's my resting heart rate?", .health),
            ("How much do I weigh?", .health),
            ("What workouts did I do this week?", .health),
            ("Tell me how I slept", .health)
        ]
        for (message, ability) in expected {
            #expect(offer(message)?.ability == ability, "\(message)")
        }
    }

    @Test("the word is there, the intent is not")
    func nearMisses() {
        // Every one of these contains a cue word for something, and most of them
        // contain a possessive and a question mark as well. An offer on any of
        // them is worse than the silence that ships today.
        for message in [
            // The suitcase, which is the sentence the phrase cues exist for.
            "What's the weight of my suitcase?",
            "How much does my suitcase weigh?",
            // The router's own recorded leak, one narrowing further on.
            "Describe the weightlessness of space",
            // A calendar that is a unit of time rather than anybody's week.
            "How many days are in a calendar year?",
            "Is my leave counted in the calendar year?",
            "How many calendars are there in the world today?",
            // A verb this app cannot honour — the reminders tool reads and
            // cannot write — attached to a sentence about a memory.
            "Remind me of the time we met",
            "Can you remind me of the time we went to Paris?",
            // An organ, not a figure.
            "My heart sank when I read it.",
            "Why did my heart sink?",
            // A date that is not a date.
            "What a date that was!",
            // Steps that are instructions, and sleeping on a decision.
            "What steps should I take to fix this?",
            "Can I sleep on it?",
            "Read me a story before I sleep",
            // Things that are on, and due, and belong to nobody here.
            "What's on tomorrow on TV?",
            "Is there anything on my desk?",
            "What's due on the mortgage?",
            "Is the rent due today?",
            "What's the weather tomorrow?",
            "Where's our meeting point for the hike?",
            // Work vocabulary, which is most of what anyone types at a model.
            "Should I split this into tasks?",
            "What's the agenda for the board meeting?"
        ] {
            #expect(offer(message) == nil, "\(message)")
        }
    }

    @Test("no ordinary English word cues health on its own")
    func healthNeedsMoreThanAWord() {
        // The strictest rule in the file, and the one with the clearest reason:
        // a wrong calendar offer is noise, and a wrong health offer is an app
        // that looks like it has been waiting for an opening. Only jargon —
        // "hrv", "workout" — cues health as a single word; everything else has
        // to arrive inside a phrase that names the asker.
        for message in [
            "Is my running app any good?",
            "Did I walk into that one?",
            "How is the heart of the story?",
            "What's the calorie count of a bagel?",
            "Should I take steps to fix this?"
        ] {
            #expect(offer(message) == nil, "\(message)")
        }
        // And the same words, one phrase later, do fire.
        #expect(offer("How far did I walk today?")?.ability == .health)
        #expect(offer("What's my step count today?")?.ability == .health)
    }

    @Test("a statement is not an ask")
    func statementsAreNotAsks() {
        // The cue is there and there is nothing to answer. An offer here is an
        // app interrupting a sentence about somebody's afternoon to talk about
        // permissions.
        for message in [
            "My meeting went badly today.",
            "I slept terribly last night.",
            "My calendar is a disaster.",
            "I wonder what's on tomorrow"
        ] {
            #expect(offer(message) == nil, "\(message)")
        }
        // The same sentences, asked.
        #expect(offer("How did I sleep last night?")?.ability == .health)
        #expect(offer("What's on my calendar today?")?.ability == .calendar)
    }

    @Test("asking to be reminded of something offers reminders, now that it can file one")
    func remindMeTo() {
        // `remind` was kept out of every cue list while the tool could only
        // read, because offering an ability that could not honour the request
        // was worse than silence. It can file one now, so the silence became
        // the bug: the app could do exactly what was asked and said nothing.
        for message in [
            "Remind me to buy milk",
            "remind me to call mum at 6",
            "Set a reminder to take the bins out",
            "Add a reminder to book the dentist"
        ] {
            #expect(offer(message)?.ability == .reminders, "\(message)")
        }
    }

    @Test("remind me OF is a memory, not a task, and still says nothing")
    func remindMeOf() {
        // The preposition is the whole difference, and it is the half of the
        // old "remind is absent everywhere" rule that was doing real work.
        // These are also in `nearMisses` above; they are repeated here because
        // that list would still pass if the cue were removed altogether, and
        // this one fails if the distinction is lost in either direction.
        for message in [
            "Remind me of the time we met",
            "Can you remind me of the time we went to Paris?",
            "Remind me of that song"
        ] {
            #expect(offer(message) == nil, "\(message)")
        }
    }

    @Test("an ability that is already on is never offered")
    func neverOffersWhatIsOn() {
        #expect(offer("What's on tomorrow?", calendar: true) == nil)
        #expect(offer("How did I sleep last night?", health: true) == nil)
        #expect(offer("What's due today?", reminders: true) == nil)
        // Nothing at all to offer once all three are on, whatever is typed.
        for message in ["What's on my calendar tomorrow?", "What's due today?", "How many steps did I do today?"] {
            #expect(offer(message, calendar: true, reminders: true, health: true) == nil, "\(message)")
        }
    }

    @Test("two switched-off abilities in one sentence is silence")
    func neverOffersTwo() {
        let both = "How did I sleep, and what's on my calendar tomorrow?"
        #expect(offer(both) == nil)
        // The same sentence stops being ambiguous the moment one of the two is
        // already on, which is why the switched-off filter runs before the
        // count and not after it.
        #expect(offer(both, health: true)?.ability == .calendar)
        #expect(offer(both, calendar: true)?.ability == .health)
    }

    @Test("the apostrophe an iPhone actually types")
    func curlyApostrophe() {
        // U+2019, which is what iOS smart punctuation inserts. Handling only the
        // ASCII one gives a feature that works in this file and never once on
        // the device it shipped to.
        #expect(offer("What\u{2019}s on tomorrow?")?.ability == .calendar)
        #expect(offer("What\u{2019}s my resting heart rate?")?.ability == .health)
    }

    @Test("case and punctuation change nothing")
    func caseInsensitive() {
        let plain = offer("what's on my calendar tomorrow?")
        #expect(offer("WHAT'S ON MY CALENDAR TOMORROW?!") == plain)
        #expect(offer("  What's on my CALENDAR, tomorrow?  ") == plain)
        #expect(plain?.ability == .calendar)
    }

    @Test("nothing is offered for nothing")
    func emptyMessages() {
        #expect(offer("") == nil)
        #expect(offer("   \n ") == nil)
        #expect(offer("???") == nil)
        #expect(offer("hello") == nil)
        #expect(offer("thanks, that's great") == nil)
    }

    @Test("an offer only ever names something that reads personal data")
    func neverOffersTheServer() {
        // `Ability` also carries the local server, which no sentence anybody
        // types at an assistant is a request for. Asserted over the corpus
        // rather than over the enum, because the way this would break is a cue
        // list growing an entry, not the filter being deleted.
        for message in [
            "What's on tomorrow?", "What's due today?", "How did I sleep last night?",
            "Check my calendar", "Show me my reminders", "What's my resting heart rate?"
        ] {
            #expect(offer(message)?.ability.readsPersonalData == true, "\(message)")
        }
    }

    @Test("the sentence offers the switch, and says which one")
    func theSentence() {
        let offerable = Ability.allCases.filter(\.readsPersonalData)
        for ability in offerable {
            let sentence = ToolOffer(ability: ability).sentence
            // Read against `title`, which is a separate property with a
            // separate author, so a template that dropped the noun or pasted
            // the wrong one is a red test rather than a shipped sentence
            // offering to check your calendar when it means your health data.
            #expect(sentence.lowercased().contains(ability.title.lowercased()), "\(ability)")
            #expect(sentence.hasSuffix("?"), "\(ability)")
        }
        #expect(Set(offerable.map { ToolOffer(ability: $0).sentence }).count == offerable.count)
    }

    @Test("the offer and the router agree about what the words mean")
    func agreesWithTheRouter() {
        // Two keyword lists in one package that disagree about which sentences
        // are about a calendar is how a user turns an ability on at this
        // prompt's invitation and watches the next prompt not use it: the
        // router is what arms the tool once the switch is on.
        let canonical: [(String, Ability)] = [
            ("What's on my calendar tomorrow?", .calendar),
            ("What reminders do I have?", .reminders),
            ("How did I sleep last night?", .health)
        ]
        for (message, ability) in canonical {
            #expect(offer(message)?.ability == ability, "\(message)")
            let group = CapabilityGroup(rawValue: ability.rawValue)
            #expect(group != nil, "\(ability)")
            #expect(group.map { CapabilityRouter.decide(message).groups.contains($0) } == true, "\(message)")
        }
    }
}

@Suite("Health cues do not fire on ordinary English")
struct HealthCueNearMissTests {
    private func offer(_ text: String) -> ToolOffer? {
        ToolOffer.decide(for: text, enabled: .init(calendar: false, reminders: false, health: false))
    }

    @Test("ordinary uses of workout, steps and exercise offer nothing")
    func noFalsePositives() {
        // Each of these was a real false positive. "workout" and "workouts"
        // were bare word cues, and "how many steps" was a phrase cue — so a
        // build question and a training question both offered to read the
        // user's Health data. On an app whose whole promise is privacy, an
        // unprompted offer to read health records is the single creepiest
        // thing it could do, which is why the bar for this ability is higher
        // than for the other two.
        for text in [
            "How many steps are in my build pipeline?",
            "How many steps are in this recipe?",
            "What steps should I take to fix this?",
            "Write me a workout plan for beginners",
            "Suggest some workouts I could try",
            "This regex needs a workout",
            "Give me an exercise to practise Swift generics",
        ] {
            #expect(offer(text)?.ability != .health, "offered health for: \(text)")
        }
    }

    @Test("genuinely personal health questions still offer")
    func truePositivesSurvive() {
        // Narrowing is only correct if it keeps the thing it is for.
        for text in [
            "How many steps did i do today?",
            "What was my workout yesterday?",
            "Did i work out this week?",
            "How did i sleep last night?",
            "What is my resting heart rate?",
        ] {
            #expect(offer(text)?.ability == .health, "missed health for: \(text)")
        }
    }
}
