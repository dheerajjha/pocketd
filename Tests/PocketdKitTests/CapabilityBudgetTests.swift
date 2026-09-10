import Foundation
import Testing
@testable import PocketdKit

/// Tools priced the way the library actually prices them.
///
/// Every schema here is built with `JSONSerialization` in the shape
/// `AnyLLMTool.toOAICompatJSON` produces and serialised with `options: []`, the
/// same options `LlamaEngine.derive` passes — so these are not invented lengths
/// standing in for real ones. The two that exist carry their real names,
/// descriptions and argument lists, read out of `CalendarEventsTool`,
/// `RemindersTool`, `CalendarRange` and `ReminderFilter`. That the first two of
/// them come to exactly the 537 tokens this workstream was briefed with is the
/// check that the fixture is honest rather than convenient.
enum CapabilityFixture {

    static func schema(
        name: String,
        description: String,
        argument: String,
        argumentDescription: String,
        values: [String]
    ) -> String {
        var property: [String: any Sendable] = [
            "type": "string",
            "description": argumentDescription
        ]
        if !values.isEmpty { property["enum"] = values }
        let object: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": [argument: property],
                    "required": [argument]
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ]
        // Key order is whatever the hash seed gives, which does not matter: the
        // same keys and the same values are always the same number of
        // characters, and characters are all the budget reads.
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A tool that takes no arguments at all — the cheapest schema the library
    /// can serialise, and a shape real tools have: "list the timers that are
    /// running" needs nothing from the model to answer it.
    static func schema(name: String, description: String) -> String {
        let object: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": [String: any Sendable](),
                    "required": [String]()
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The serialised schemas, kept beside the tools they price so that the
    /// comparison against `ContextGuard` runs on the real text rather than on
    /// something the same length as it.
    static let schemas: [String: String] = [
        PersonalDataToolNames.calendar: schema(
            name: PersonalDataToolNames.calendar,
            description: "List the user's calendar events (meetings, appointments) for a range of days.",
            argument: "range",
            argumentDescription: "Which days to list.",
            values: CalendarRange.allCases.map(\.rawValue)
        ),
        PersonalDataToolNames.reminders: schema(
            name: PersonalDataToolNames.reminders,
            description: "List the user's reminders (to-dos) that are not completed yet.",
            argument: "filter",
            argumentDescription: "Which reminders to list.",
            values: ReminderFilter.allCases.map(\.rawValue)
        ),
        "get_activity_summary": schema(
            name: "get_activity_summary",
            description: "Summarise the user's steps, exercise and calories for a range of days.",
            argument: "range", argumentDescription: "Which days to summarise.",
            values: ["today", "yesterday", "this_week"]
        ),
        "get_sleep_summary": schema(
            name: "get_sleep_summary",
            description: "Summarise how long and how well the user slept for a range of nights.",
            argument: "range", argumentDescription: "Which nights to summarise.",
            values: ["last_night", "this_week"]
        ),
        "get_alarms": schema(
            name: "get_alarms",
            description: "List the alarms the user has set, and which of them are switched on.",
            argument: "filter", argumentDescription: "Which alarms to list.",
            values: ["enabled", "all"]
        ),
        "set_alarm": schema(
            name: "set_alarm",
            description: "Set an alarm for a time of day, repeating on the days given.",
            argument: "time", argumentDescription: "The time of day, as HH:mm on a 24-hour clock.",
            values: []
        ),
        "start_timer": schema(
            name: "start_timer",
            description: "Start a countdown timer for a number of minutes.",
            argument: "minutes", argumentDescription: "How many minutes to count down.",
            values: []
        ),
        "get_timers": schema(
            name: "get_timers",
            description: "List the countdown timers that are currently running.",
            argument: "filter", argumentDescription: "Which timers to list.",
            values: ["running", "all"]
        ),
        "get_running_timers": schema(
            name: "get_running_timers",
            description: "List the timers that are running."
        )
    ]

    private static func tool(_ name: String, _ group: CapabilityGroup, _ priority: Int) -> CapabilityTool {
        CapabilityTool(name: name, group: group, priority: priority, schema: schemas[name] ?? "")
    }

    static let calendar = tool(PersonalDataToolNames.calendar, .calendar, 1)
    static let reminders = tool(PersonalDataToolNames.reminders, .reminders, 2)
    static let activity = tool("get_activity_summary", .health, 3)
    static let sleep = tool("get_sleep_summary", .health, 4)
    static let listAlarms = tool("get_alarms", .alarms, 5)
    static let setAlarm = tool("set_alarm", .alarms, 6)
    static let startTimer = tool("start_timer", .timers, 7)
    static let listTimers = tool("get_timers", .timers, 8)

    /// Everything the product plan asks for, in the order it would be given up.
    static let inventory = [
        calendar, reminders, activity, sleep, listAlarms, setAlarm, startTimer, listTimers
    ]

    /// Deliberately outside `inventory`: it exists to reach one arithmetic the
    /// product's own tools cannot, and adding it to the pinned set would change
    /// every number the rest of this file measures.
    static let runningTimers = tool("get_running_timers", .timers, 0)

    /// The array as the library serialises it: the tools' own objects, comma
    /// separated, in brackets, with no whitespace anywhere.
    static func serialised(_ tools: [CapabilityTool]) -> String {
        guard !tools.isEmpty else { return "" }
        return "[" + tools.map { schemas[$0.name] ?? "" }.joined(separator: ",") + "]"
    }
}

/// The precondition for every capability after the first two.
///
/// Registering a tool injects its schema into every prompt whether or not the
/// question needed it: 89 guard tokens for the preamble the moment any tool
/// exists, and ~110 per tool, doubled on a tool-native template. Against 4,032
/// usable tokens the product plan's five capabilities do not fit, and the
/// failure mode of finding that out at runtime is `contextExhausted` on a
/// question that would have worked yesterday.
@Suite("Capability budget")
struct CapabilityBudgetTests {

    private static let native = CapabilityBudget(contextTokens: 4096, templateIsToolNative: true)
    private static let plain = CapabilityBudget(contextTokens: 4096, templateIsToolNative: false)
    private static let small = CapabilityBudget(contextTokens: 2048, templateIsToolNative: true)

    @Test("a model with no tools is charged nothing, preamble included")
    func emptyCostsNothing() {
        #expect(Self.native.cost(of: []) == 0)
        #expect(Self.native.fit(of: []) == .comfortable)
        #expect(Self.native.admit([]).tokens == 0)
        #expect(Self.native.admit([]).registered.isEmpty)
    }

    @Test("the window a prompt has is the guard's, not the model's")
    func usableMatchesTheGuard() {
        // 4,096 minus the 64 the guard holds back for the answer. If these ever
        // disagree the budget spends tokens the guard has already reserved.
        #expect(Self.native.usableTokens == 4032)
        #expect(Self.native.usableTokens == ContextGuard(contextTokens: 4096).promptBudget)
        #expect(Self.small.usableTokens == 1984)
        #expect(Self.native.ceilingTokens == 1344)
        #expect(Self.small.ceilingTokens == 661)
    }

    @Test("one tool costs its doubled schema plus the whole preamble")
    func firstToolPaysThePreamble() {
        // 336 characters of schema and two of array punctuation is 113 guard
        // tokens; the template renders them twice; the 265-character preamble
        // exists the moment any tool does and never again.
        #expect(CapabilityFixture.calendar.schemaCharacters == 336)
        #expect(Self.native.cost(of: [CapabilityFixture.calendar]) == 113 * 2 + 89)
        #expect(Self.native.cost(of: [CapabilityFixture.calendar]) - 113 * 2 == 89)
    }

    @Test("two tools cost 537 tokens, which is 13% of a 4,096-token window")
    func theBriefedNumber() {
        let two = [CapabilityFixture.calendar, CapabilityFixture.reminders]
        #expect(Self.native.cost(of: two) == 537)
        #expect(Self.native.usableTokens == 4032)
    }

    @Test("the estimate is the guard's own, for every prefix and both templates")
    func agreesWithTheGuard() {
        // The one test that has to hold. The budget prices a set of schemas
        // before they are serialised and the guard reserves the string that
        // results; if the two can disagree, the budget admits a tool the guard
        // then charges more for, under-reserves by the difference, and hands
        // llama.cpp the oversized batch `ContextGuard` exists to prevent.
        for count in 1...CapabilityFixture.inventory.count {
            let tools = Array(CapabilityFixture.inventory.prefix(count))
            let json = CapabilityFixture.serialised(tools)
            #expect(json.count == CapabilityBudget.serialisedCharacters(of: tools))
            for native in [true, false] {
                let budget = CapabilityBudget(contextTokens: 4096, templateIsToolNative: native)
                #expect(budget.cost(of: tools) == ContextGuard.toolOverhead(
                    toolsJSON: json,
                    templateIsToolNative: native
                ))
            }
        }
    }

    @Test("a tool-native template charges twice for the same schemas")
    func nativeTemplateCostsDouble() {
        let two = [CapabilityFixture.calendar, CapabilityFixture.reminders]
        let preamble = 89
        #expect(Self.native.cost(of: two) - preamble == 2 * (Self.plain.cost(of: two) - preamble))
    }

    @Test("the sixth tool is refused because the fifth spent the share")
    func refusesTheOneThatBreaches() {
        let plan = Self.native.admit(CapabilityFixture.inventory)

        #expect(plan.registered.count == 5)
        #expect(plan.tokens == 1161)
        #expect(plan.tokens <= Self.native.ceilingTokens)
        // The tool that was refused would have taken it past the ceiling, which
        // is the whole claim: the refusal is arithmetic, not a preference.
        let sixth = Array(CapabilityFixture.inventory.prefix(6))
        #expect(Self.native.cost(of: sixth) == 1349)
        #expect(Self.native.cost(of: sixth) > Self.native.ceilingTokens)
    }

    @Test("a 2,048-token model gets fewer capabilities than a 4,096-token one")
    func smallerWindowFewerCapabilities() {
        let large = Self.native.admit(CapabilityFixture.inventory)
        let smaller = Self.small.admit(CapabilityFixture.inventory)

        #expect(smaller.registered.count == 2)
        #expect(large.registered.count == 5)
        #expect(smaller.liveGroups == [.calendar, .reminders])
        #expect(smaller.tokens == 537)
    }

    @Test("the same eight tools fit a model whose template is not tool-native")
    func templateDecidesTheAnswer() {
        // Identical context, identical tools, a different chat template — and
        // the whole product plan fits one model and not the other.
        let doubled = Self.native.admit(CapabilityFixture.inventory)
        let single = Self.plain.admit(CapabilityFixture.inventory)

        #expect(single.registered.count == CapabilityFixture.inventory.count)
        #expect(single.dropped.isEmpty)
        #expect(single.tokens == 901)
        #expect(doubled.registered.count < single.registered.count)
    }

    @Test("a refusal says what it would cost and which context would carry it")
    func refusalExplainsItself() {
        let plan = Self.native.admit(CapabilityFixture.inventory)

        #expect(plan.droppedGroups == [.alarms, .timers])
        let alarms = plan.dropped.first { $0.group == .alarms }
        #expect(alarms?.reason == .overBudget)
        #expect(alarms?.additionalTokens == 188)
        #expect(alarms?.contextTokens == 8192)
        #expect(alarms?.explanation.contains("8192-token context") == true)

        // Priced cumulatively: timers sit behind alarms in the order, so their
        // price is what it costs to reach them, not what they weigh alone.
        let timers = plan.dropped.first { $0.group == .timers }
        #expect(timers?.additionalTokens == 552)
        #expect(plan.explanation?.contains("Alarms, Timers") == true)
    }

    @Test("a capability that is only half registered is named as one")
    func partialCapabilityIsNamed() {
        let plan = Self.native.admit(CapabilityFixture.inventory)

        // Alarms got its read tool and not its write tool. A settings row
        // reading "Alarms: on" here would be a lie the user finds out about by
        // asking the model to set one.
        #expect(plan.liveGroups == [.calendar, .reminders, .health, .alarms])
        #expect(plan.partialGroups == [.alarms])
    }

    @Test("routing away a group excludes it entirely and prices it honestly")
    func routingExcludes() {
        let plan = Self.native.admit(CapabilityFixture.inventory, routedTo: [.health])

        #expect(plan.registered.map(\.name) == ["get_activity_summary", "get_sleep_summary"])
        #expect(plan.tokens == 517)
        // What the whole inventory would have cost on this model, which is what
        // routing saved.
        #expect(plan.everythingTokens == 1713)

        let calendar = plan.dropped.first { $0.group == .calendar }
        #expect(calendar?.reason == .notRouted)
        // This window can pay the 226 tokens, so the invitation to ask for it
        // is a real one. The window that cannot is in `aWindowTooSmallForAnything`.
        #expect(calendar?.needsABiggerContext == false)
        #expect(calendar?.explanation.contains("not registered for this question") == true)
        // Nothing here is over budget, so there is nothing for Settings to warn
        // about. Routing is a saving, and reporting it as a fault would train
        // people to turn it off.
        #expect(plan.explanation == nil)
    }

    @Test("an empty routing registers nothing at all")
    func nothingRoutedNothingRegistered() {
        let plan = Self.native.admit(CapabilityFixture.inventory, routedTo: [])

        #expect(plan.registered.isEmpty)
        #expect(plan.tokens == 0)
        #expect(plan.dropped.allSatisfy { $0.reason == .notRouted })
        // The same promise `LlamaEngine` makes for an empty tool array: the
        // library injects nothing, so the prompt is byte for byte what it was
        // before this file existed.
        #expect(plan.toolNames.isEmpty)
        // Nothing was refused here — nothing was asked for — so the empty plan
        // is the healthy one. See `emptyPlansAreToldApart` for its twin.
        #expect(plan.fit == .comfortable)
    }

    @Test("an empty plan reads healthy only when nothing was refused")
    func emptyPlansAreToldApart() {
        // Two plans with an identical empty `registered`, and telling them
        // apart is the whole job of the verdict. A question that wanted no
        // tools got exactly what it asked for. A window too small for one
        // schema did not, and this is the only number on the screen that says
        // so — `tokens` is 0 and `ceilingTokens` is intact in both.
        let tiny = CapabilityBudget(contextTokens: 512, templateIsToolNative: true)
        let refused = tiny.admit(CapabilityFixture.inventory)
        #expect(refused.registered.isEmpty)
        #expect(refused.tokens == 0)
        #expect(refused.fit == .willNotFit)
        #expect(refused.fit.allowsRegistration == false)

        let unasked = Self.native.admit(CapabilityFixture.inventory, routedTo: [])
        #expect(unasked.registered.isEmpty)
        #expect(unasked.tokens == 0)
        #expect(unasked.fit == .comfortable)

        // And a model with nothing to register at all is the healthy answer for
        // the same reason: nothing was refused.
        #expect(Self.native.admit([]).fit == .comfortable)
    }

    @Test("a plan that lost a capability to the window is never comfortable")
    func partialRefusalIsNeverComfortable() {
        // The milder shade of the same lie. The one tool that fits here is a
        // no-argument schema, so the survivor occupies 205 tokens of a
        // 224-token comfortable share and grades `.comfortable` on its own
        // merits — while the window refused eight capabilities to get there.
        //
        // It takes a schema this small to reach the case at all: the gap
        // between the comfortable line and the ceiling is 96 tokens here, so
        // nothing in `inventory` can sit under one and be refused by the other.
        // Rare is not the same as unreachable, and a verdict that only lies in
        // configurations nobody tested is the worst kind.
        let narrow = CapabilityBudget(contextTokens: 1024, templateIsToolNative: true)
        let plan = narrow.admit([CapabilityFixture.runningTimers] + CapabilityFixture.inventory)

        #expect(plan.registered.map(\.name) == ["get_running_timers"])
        #expect(plan.tokens == 205)
        #expect(narrow.fit(of: plan.registered) == .comfortable)
        #expect(plan.dropped.contains { $0.reason == .overBudget })
        #expect(plan.fit == .tight)
    }

    @Test("routing orders the groups and priority orders within them")
    func routingBeatsPriority() {
        // Timers outrank the calendar here only because the question asked for
        // them. That inversion is the point of routing: the last slot goes to
        // what was asked about, not to what ranks highest in general.
        let plan = Self.native.admit(CapabilityFixture.inventory, routedTo: [.timers, .calendar])

        #expect(plan.registered.map(\.name) == ["start_timer", "get_timers", "get_calendar_events"])
    }

    @Test("one tool needs a 1,024-token context and two need 2,048")
    func smallestFittingContext() {
        let one = [CapabilityFixture.calendar]
        let two = [CapabilityFixture.calendar, CapabilityFixture.reminders]

        #expect(Self.native.smallestFittingContext(for: one) == 1024)
        #expect(Self.native.smallestFittingContext(for: two) == 2048)
        // Comfortable costs a tier: the same tool fits at 1,024 with nothing to
        // spare, and a phone serving at 1,024 has no room for the answer.
        #expect(Self.native.smallestFittingContext(for: one, allowing: .comfortable) == 2048)
        // A model that renders each schema once needs less window for the same
        // capability, which is the doubling seen from the other side.
        #expect(Self.plain.smallestFittingContext(for: one) == 1024)
        #expect(Self.plain.smallestFittingContext(for: two) == 1024)
    }

    @Test("the verdict has three states, all reachable at one context")
    func threeStates() {
        #expect(Self.native.fit(of: [CapabilityFixture.calendar]) == .comfortable)
        #expect(Self.native.fit(of: Array(CapabilityFixture.inventory.prefix(5))) == .tight)
        #expect(Self.native.fit(of: Array(CapabilityFixture.inventory.prefix(6))) == .willNotFit)
        #expect(Self.native.fit(of: Array(CapabilityFixture.inventory.prefix(6))).allowsRegistration == false)
        #expect(CapabilityBudget.Fit.tight > .willNotFit)
        #expect(CapabilityBudget.Fit.comfortable > .tight)
    }

    @Test("the shortfall is the sentence, not the verdict")
    func shortfallExplains() {
        let six = Array(CapabilityFixture.inventory.prefix(6))
        #expect(Self.native.shortfall(of: six) == 1349 - 1344)
        #expect(Self.native.shortfall(of: Array(CapabilityFixture.inventory.prefix(5))) == 0)
    }

    @Test("a client already carrying the plan does not need rebuilding")
    func coverageAvoidsARebuild() {
        let wide = Self.native.admit(CapabilityFixture.inventory)
        let narrow = Self.native.admit(CapabilityFixture.inventory, routedTo: [.calendar])

        // Narrowing is not worth a rebuild: the client freezes its tools at
        // construction, so dropping a schema costs a new llama_context, a
        // re-mapped model and a cold prompt cache to save a few hundred tokens.
        #expect(narrow.isCovered(by: wide.toolNames))
        #expect(wide.isCovered(by: narrow.toolNames) == false)
    }

    /// If this test is why your build is red, you added a capability. That is
    /// exactly what it is for.
    ///
    /// Registering a tool is not a local change: it charges every prompt of
    /// every conversation on every model, and the arithmetic above says the
    /// product plan already overruns a 4,096-token window by three tools. So
    /// the count is pinned, and moving it means going and looking at what got
    /// dropped to make room — which is the whole reason this workstream exists.
    @Test("adding a capability cannot happen quietly")
    func pinnedInventory() {
        #expect(CapabilityGroup.allCases.count == 5)
        #expect(CapabilityFixture.inventory.count == 8)

        let plan = Self.native.admit(CapabilityFixture.inventory)
        #expect(plan.registered.count == 5)
        #expect(plan.dropped.isEmpty == false)
        #expect(plan.fit == .tight)
        // The whole plan needs more than double the tool budget a 4,096-token
        // context allows. Nothing about that improves by adding to it.
        #expect(plan.everythingTokens == 1713)
        #expect(plan.everythingTokens > Self.native.ceilingTokens)
    }
}
