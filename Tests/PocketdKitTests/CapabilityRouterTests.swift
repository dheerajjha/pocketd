import Foundation
import Testing
@testable import PocketdKit

/// Arming every capability on every question is what makes the budget run out.
///
/// The router is the half of that problem the budget cannot solve: the budget
/// decides how many schemas fit, and this decides which ones were worth the
/// room. It gets no model round to do it with — a second inference pass would
/// cost more than the tokens it saves, and would hand the choice of which of
/// the user's data to reach for to whatever the last turn said.
@Suite("Capability router")
struct CapabilityRouterTests {

    @Test("a calendar question arms the calendar and nothing else")
    func calendarQuestion() {
        #expect(CapabilityRouter.decide("What's on my calendar tomorrow?") == .named([.calendar]))
        #expect(CapabilityRouter.decide("Am I free on Friday?") == .named([.calendar]))
        #expect(CapabilityRouter.decide("When is my next appointment") == .named([.calendar]))
    }

    @Test("a question about sleep does not pay for the alarm schema")
    func sleepIsNotAnAlarm() {
        // The two live one word apart in English and several hundred tokens
        // apart in the prompt.
        #expect(CapabilityRouter.decide("How did I sleep last night?") == .named([.health]))
        #expect(CapabilityRouter.decide("How many steps did I walk this week?") == .named([.health]))
        #expect(CapabilityRouter.decide("Set an alarm for 7am") == .named([.alarms]))
    }

    @Test("a timer question arms the timer and not the calendar")
    func timerQuestion() {
        #expect(CapabilityRouter.decide("Set a timer for 10 minutes") == .named([.timers]))
        // "time" is deliberately not a cue. A model is told the date and time
        // in the system message by `DateContext`, which costs half of what a
        // tool for it would, so a question about the clock arms nothing.
        #expect(CapabilityRouter.decide("What time is it?") == .unrelated)
    }

    @Test("an ambiguous question is answered as ambiguous")
    func ambiguityIsHonest() {
        // "What's on today?" is the calendar and the reminders and the day's
        // activity. Picking one of the three would be a guess wearing the face
        // of a decision — and so would `.named`, which is the case that says
        // the words asked for these. No word here asked for anything; a time
        // word narrowed a guess. The groups are the same either way, and the
        // label is the only place the router can admit which one it did.
        #expect(CapabilityRouter.decide("What's on today?") == .unsure([.calendar, .reminders, .health]))
        #expect(CapabilityRouter.decide("How was my week?") == .unsure([.calendar, .reminders, .health]))
    }

    @Test("a time word sharpens a named capability rather than adding two more")
    func timeWordsDoNotIntroduce() {
        // The rule that keeps the ambiguous case above from costing every
        // question three schemas: "tomorrow" argues for whatever the sentence
        // already named, and only stands in for a capability when nothing did.
        #expect(CapabilityRouter.decide("What meetings do I have tomorrow?") == .named([.calendar]))
        #expect(CapabilityRouter.decide("What did I have on this week?") == .unsure([.calendar, .reminders, .health]))
    }

    @Test("hello arms nothing at all")
    func greetingArmsNothing() {
        #expect(CapabilityRouter.decide("hello") == .unrelated)
        #expect(CapabilityRouter.decide("hello").groups.isEmpty)
        #expect(CapabilityRouter.decide("thanks, that's great") == .unrelated)
        #expect(CapabilityRouter.decide("") == .unrelated)
    }

    @Test("a question about the user's own day fails open rather than closed")
    func failsOpen() {
        // Nothing here names a capability, and all of it is about the asker. A
        // question that needed a tool and got none is a visible failure — the
        // model says it cannot see the calendar while the calendar sits there —
        // where a question that armed one schema too many is a slightly smaller
        // window nobody notices.
        #expect(CapabilityRouter.decide("Sort my day out") == .unsure(CapabilityGroup.allCases))
        #expect(CapabilityRouter.decide("Do I have anything on?") == .unsure(CapabilityGroup.allCases))
        #expect(CapabilityRouter.decide("what should I be doing right now?") == .unsure(CapabilityGroup.allCases))
    }

    @Test("saying 'me' is not the same as asking about me")
    func pronounIsNotEnough() {
        // The accepted cost of the rule above is that the question mark decides
        // this pair, so "can you write me a poem?" does fall open. Erring that
        // way is the point; erring the other way is a feature that silently
        // stops working.
        #expect(CapabilityRouter.decide("Write me a poem about the sea") == .unrelated)
        #expect(CapabilityRouter.decide("Find me a restaurant") == .unrelated)
    }

    @Test("a whole-word cue never matches as a prefix")
    func prefixesDoNotLeak() {
        // Every one of these begins with a word that is a cue for something.
        // Matching them as stems is how a router starts arming the calendar for
        // "it worked out eventually".
        #expect(CapabilityRouter.decide("Listen to some music") == .unrelated)
        #expect(CapabilityRouter.decide("It worked out eventually") == .unrelated)
        #expect(CapabilityRouter.decide("Play a duet") == .unrelated)
    }

    @Test("a stem never matches the opening of an unrelated word")
    func stemsDoNotLeak() {
        // The other half of the same class, and the half that used to leak.
        // None of these is about the asker's own day — no possessive, and no
        // pronoun inside a question — so the fail-open path is not what answers
        // them: the router is asserting that the words named a capability. On a
        // 4,096-token tool-native model, arming health for "write a
        // heartbreaking story" spends 517 tokens of a 1,344-token ceiling on
        // the exact kind of prompt this file promises arms nothing.
        for prompt in [
            "Write a heartbreaking story",
            "Tell me about Stephen King",
            "What is on the taskbar",
            "A busybody neighbour, in one paragraph",
            "Write a walkthrough for the new setup",
            "Write the choreography for the finale",
            "Explain why that trend is alarming",
            "Describe the weightlessness of space",
            "Describe an inviting living room"
        ] {
            #expect(CapabilityRouter.decide(prompt) == .unrelated, "\(prompt)")
        }
    }

    @Test("the cues that moved to whole words still arm their capability")
    func movedCuesStillWork() {
        // The other direction of the same move: narrowing a stem is only free
        // if the forms people actually type are still listed.
        #expect(CapabilityRouter.decide("Am I busy on Friday") == .named([.calendar]))
        #expect(CapabilityRouter.decide("What tasks are left") == .named([.reminders]))
        #expect(CapabilityRouter.decide("Add a chore") == .named([.reminders]))
        #expect(CapabilityRouter.decide("What was my heart rate") == .named([.health]))
        #expect(CapabilityRouter.decide("How many steps yesterday") == .named([.health]))
        #expect(CapabilityRouter.decide("Did I walk today") == .named([.health]))
        #expect(CapabilityRouter.decide("Set an alarm for 7am") == .named([.alarms]))
        #expect(CapabilityRouter.decide("Send the invite") == .named([.calendar]))
    }

    @Test("a stem covers the forms of its word")
    func stemsCoverInflections() {
        for prompt in ["remind me to buy milk", "what was I reminded about", "show the reminders", "anything overdue"] {
            #expect(CapabilityRouter.decide(prompt).groups.first == .reminders, "\(prompt)")
        }
    }

    @Test("capitalisation and punctuation change nothing")
    func caseInsensitive() {
        let plain = CapabilityRouter.decide("what's on my calendar tomorrow")
        #expect(CapabilityRouter.decide("WHAT'S ON MY CALENDAR TOMORROW?!") == plain)
        #expect(CapabilityRouter.decide("  What's on my CALENDAR, tomorrow?  ") == plain)
    }

    @Test("the order is total: score first, then rank, never the dictionary")
    func orderingIsTotal() {
        // The scores live in a dictionary, whose iteration order is seeded per
        // process. Without a total ordering over them the same question would
        // arm the capabilities in a different order on every launch — and the
        // budget truncates by order, so a different order is a different set of
        // tools.
        //
        // Both branches of that sort are pinned here because only a pin can
        // catch it. A loop of identical calls inside one process cannot: the
        // seed is fixed for the life of the process and the same keys go in in
        // the same order every time, so fifty more calls are fifty copies of
        // the first answer, and the loop stays green with no tie-break at all.

        // A three-way tie — nothing named a capability, so each temporal group
        // scored exactly one — where rank is the only thing left to order by.
        #expect(CapabilityRouter.decide("What's on today?").groups == [.calendar, .reminders, .health])

        // And the half rank must not decide: health scores nine to reminders'
        // three and leads, though it ranks below reminders everywhere else.
        #expect(
            CapabilityRouter.decide("remind me about my workout, my exercise and my sleep")
                == .named([.health, .reminders])
        )
    }

    @Test("only the last thing the user said is routed on")
    func routesOnTheLastTurn() {
        let conversation: [ChatMessage] = [
            .user("What's on my calendar tomorrow?"),
            .assistant("You have two meetings."),
            .user("Set a timer for 10 minutes")
        ]
        // Not the whole conversation: a calendar question three turns back
        // would keep the schema armed — and charged — through everything after
        // it.
        #expect(CapabilityRouter.decide(conversation) == .named([.timers]))
        #expect(CapabilityRouter.decide([ChatMessage.assistant("hello")]) == .unrelated)
        #expect(CapabilityRouter.decide([ChatMessage]()) == .unrelated)
    }
}

/// The two halves together, which is the only form the engine sees.
@Suite("Routed capability plans")
struct RoutedCapabilityPlanTests {

    private static let budget = CapabilityBudget(contextTokens: 4096, templateIsToolNative: true)

    @Test("a sleep question pays for health and for nothing else")
    func routedPlanIsCheaper() {
        let routed = Self.budget.plan(for: "How did I sleep last night?", from: CapabilityFixture.inventory)
        let everything = Self.budget.admit(CapabilityFixture.inventory)

        #expect(routed.liveGroups == [.health])
        #expect(routed.tokens == 517)
        #expect(everything.tokens == 1161)
        // 644 tokens of a 4,032-token window, bought by reading the question
        // rather than by asking the model about it.
        #expect(everything.tokens - routed.tokens == 644)
        #expect(routed.toolNames.contains("get_alarms") == false)
    }

    @Test("an unsure question arms what fits rather than nothing")
    func unsureStillArms() {
        let unsure = Self.budget.plan(for: "Sort my day out", from: CapabilityFixture.inventory)

        // The fail-open promise, end to end: nothing in the sentence named a
        // capability, and the answer is still five tools rather than none.
        #expect(unsure.registered.count == 5)
        #expect(unsure.registered == Self.budget.admit(CapabilityFixture.inventory).registered)
        #expect(unsure.fit == .tight)
    }

    @Test("a question no tool can answer costs nothing")
    func unrelatedCostsNothing() {
        let plan = Self.budget.plan(for: "Write a poem about the sea", from: CapabilityFixture.inventory)

        #expect(plan.registered.isEmpty)
        #expect(plan.tokens == 0)
        #expect(plan.dropped.allSatisfy { $0.reason == .notRouted })
        // What the same question would have cost with everything registered.
        #expect(plan.everythingTokens == 1713)
    }

    @Test("routing cannot rescue a window too small for one schema")
    func aWindowTooSmallForAnything() {
        // 512 tokens leaves 448 for the prompt and 149 for schemas, and the
        // cheapest tool here costs 265. Routing narrows the set; it cannot make
        // a schema smaller, and the honest answer is no tools.
        let tiny = CapabilityBudget(contextTokens: 512, templateIsToolNative: true)
        let plan = tiny.plan(for: "What's on my calendar tomorrow?", from: CapabilityFixture.inventory)

        #expect(plan.registered.isEmpty)
        #expect(plan.dropped.contains { $0.group == .calendar && $0.reason == .overBudget })
        #expect(plan.dropped.first { $0.group == .calendar }?.contextTokens == 1024)

        // And the verdict has to say so. Nothing was registered, nothing can
        // be, and a plan that graded only its survivors would report the empty
        // set as comfortable — the same green a model carrying everything it
        // asked for shows, on the model that can carry nothing at all.
        #expect(plan.fit == .willNotFit)
        #expect(plan.fit.allowsRegistration == false)

        // The rows the question never asked for live in the same window, and
        // their sentence has to know it: at a 149-token ceiling, "asking for it
        // would cost 311 tokens" invites a rephrasing that buys nothing.
        let reminders = plan.dropped.first { $0.group == .reminders }
        #expect(reminders?.reason == .notRouted)
        #expect(reminders?.needsABiggerContext == true)
        #expect(reminders?.explanation.contains("Asking for it") == false)
        #expect(reminders?.explanation.contains("A 1024-token context fits it") == true)
    }
}
