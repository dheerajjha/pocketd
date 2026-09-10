import Foundation

/// One capability, named the way a user would name it.
///
/// A closed set rather than an open string, because two things have to agree
/// about it and neither can be allowed to invent a value: `CapabilityRouter`
/// decides which of these a question is about, and Settings lists them. A typo
/// in a raw string would show up as a capability that silently never arms.
///
/// Cases exist for capabilities that have no tools yet. That is not
/// speculation — it is where the vocabulary is pinned, so that the router can
/// be written and tested against "how did I sleep" before HealthKit is wired
/// to anything. A group with no registered tools routes to nothing and costs
/// nothing, which is the correct behaviour for one that has not shipped.
///
/// Declaration order is the ranking used when nothing more specific is known —
/// the fail-open path in `CapabilityRouter`, and any caller that hands the
/// budget the whole inventory. Calendar and reminders lead it because they are
/// the two this app actually registers today; the rest follow in the order the
/// product plan lists them.
public enum CapabilityGroup: String, Sendable, Equatable, CaseIterable {
    case calendar
    case reminders
    case health
    case alarms
    case timers

    /// Spelled out rather than `rawValue.capitalized`, which is locale-
    /// sensitive: on a Turkish phone that call turns `timers` into `Tımers`.
    public var displayName: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .health: "Health"
        case .alarms: "Alarms"
        case .timers: "Timers"
        }
    }

    /// Position in the default ranking. Used only to break ties, so that two
    /// capabilities a question argues for equally still come back in an order
    /// that is the same on every launch.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

/// A tool, priced.
///
/// The engine holds `any LLMTool`, which is a protocol from a dependency this
/// package deliberately does not link. What the budget needs is not the tool
/// but its cost and its rank, and both are plain numbers — which is what keeps
/// every decision here testable without llama.cpp, a model file or a simulator.
public struct CapabilityTool: Sendable, Equatable {
    /// The name the model calls and the engine dispatches on, and the name a
    /// caller would arm `ToolSyntaxScreen` with. It has to be the registered
    /// one rather than a label: a plan naming a tool the engine does not have
    /// registers nothing and still reports success.
    public var name: String
    public var group: CapabilityGroup
    /// Lower registers first, the same direction EventKit numbers a reminder's
    /// priority — a scale this codebase already has to explain to the model, so
    /// having two of them pointing opposite ways would be worse than either.
    /// Read backwards this silently registers the least important tool and
    /// drops the rest, which is a failure nothing downstream can see.
    public var priority: Int
    /// Characters this tool contributes to the serialised schema array — its
    /// own object from `AnyLLMTool.toOAICompatJSONString(options: [])`, without
    /// the array's brackets, which `CapabilityBudget` adds back once.
    public var schemaCharacters: Int

    public init(name: String, group: CapabilityGroup, priority: Int, schemaCharacters: Int) {
        self.name = name
        self.group = group
        self.priority = priority
        self.schemaCharacters = schemaCharacters
    }

    /// For a caller holding the serialised schema itself, which is the shape
    /// the engine is in: it already builds this string to decide whether a
    /// client needs rebuilding.
    public init(name: String, group: CapabilityGroup, priority: Int, schema: String) {
        self.init(
            name: name,
            group: group,
            priority: priority,
            schemaCharacters: schema.count
        )
    }
}

/// How much of a context window may be spent on tool schemas, and therefore
/// which capabilities a question gets.
///
/// Registering a tool is not free and the cost is charged on every prompt,
/// answered or not. The library appends every schema to the system message,
/// preceded by a fixed 265-character preamble that exists the moment the first
/// tool does, and a tool-native chat template renders the same schemas a second
/// time. Against the 4,032 usable tokens of a 4,096-token context that is 537
/// tokens for two tools and 3,215 for fourteen — and the product plan calls for
/// calendar, reminders, health, alarms and timers. They cannot all be
/// registered. The question is not whether some are refused but which, and
/// whether the refusal can say what it would have cost.
///
/// Deliberately the same shape as `DeviceBudget`, which answers exactly this
/// question about RAM: an estimate, a ceiling, a three-state verdict, and a
/// shortfall that turns a refusal into a sentence someone can act on. The one
/// inversion is the inverse question — RAM asks for the largest context a model
/// fits in, this asks for the smallest context a set of tools fits in, because
/// the free variable moves the other way.
///
/// This composes with `ToolGate`; it does not replace it, and the order is not
/// interchangeable. The gate asks whether the resident model can work the tool
/// protocol at all — Llama 3.2 1B provably cannot, and hands back the schema as
/// chat text when given one — and a model it refuses is handed nothing at all,
/// so there is no budget to spend and none of this runs. Capability first, then
/// budget.
public struct CapabilityBudget: Sendable, Equatable {
    /// The window the client will be built with — `min(model.contextLength,
    /// configured)`, not what the weights advertise.
    public var contextTokens: Int
    /// Whether the resident model's chat template renders tool schemas itself,
    /// from `ContextGuard.templateIsToolNative`. A Qwen3-style template pays
    /// for every schema twice, so the same five tools that fit one model do not
    /// fit another with an identical context length.
    public var templateIsToolNative: Bool

    public init(contextTokens: Int, templateIsToolNative: Bool) {
        self.contextTokens = max(1, contextTokens)
        self.templateIsToolNative = templateIsToolNative
    }

    /// The most of the usable window tool schemas may occupy.
    ///
    /// The other two thirds are not spare. Every prompt also carries the system
    /// prompt and `DateContext`'s sentence — about 86 tokens together — the
    /// question, and the conversation so far. And the prompt that follows a
    /// tool call carries the schemas *again* plus the tool's own output, which
    /// `PersonalDataTools` caps at twenty rows and measures at 40–60 tokens
    /// each: a thousand tokens for one full day of calendar.
    ///
    /// A third of 4,032 is 1,344, which buys five tools on a tool-native
    /// template and leaves 2,688 for all of the above. A half buys eight and
    /// leaves 2,016 — of which one full calendar read is a thousand, before the
    /// question or a single earlier turn, which is how a win here turns into a
    /// 413 the moment a tool actually returns something.
    public static let maximumShareOfWindow = 1.0 / 3.0

    /// Where "fits" stops being "fits comfortably", as a share of the ceiling.
    /// The same 0.7 `DeviceBudget` uses, and it means the same thing: room to
    /// hold the thing, and room for the phone to still be doing something else.
    public static let comfortableShareOfCeiling = 0.7

    /// What a prompt actually has, which is the window minus what the guard
    /// holds back for the answer.
    ///
    /// Read through `ContextGuard` rather than recomputed, because the two have
    /// to be one number: a budget that spent tokens the guard has already
    /// reserved would admit a set of tools that makes every prompt fail the
    /// check it was sized against.
    public var usableTokens: Int {
        ContextGuard(contextTokens: contextTokens).promptBudget
    }

    /// The most a set of schemas may cost here.
    public var ceilingTokens: Int {
        // Rounded rather than truncated. A third has no exact binary form, so
        // 4,032 of them come to 1,343.9999999999998, and truncating would lose
        // a token to floating point rather than to a decision anyone made.
        max(0, Int((Double(usableTokens) * Self.maximumShareOfWindow).rounded()))
    }

    /// What registering exactly these would add to every prompt, in the same
    /// guard tokens `ContextGuard.fixedOverheadTokens` reserves.
    ///
    /// Zero for an empty set, and that is a cliff rather than a slope: the
    /// preamble is charged in full the moment the first tool exists, so the
    /// first tool costs 89 tokens more than the second.
    public func cost(of tools: [CapabilityTool]) -> Int {
        ContextGuard.toolOverhead(
            schemaCharacters: Self.serialisedCharacters(of: tools),
            templateIsToolNative: templateIsToolNative
        )
    }

    /// Characters the whole array serialises to.
    ///
    /// `[{…},{…}]` with no whitespace, because `LlamaEngine` passes
    /// `options: []` to match what the library injects. The punctuation is
    /// counted rather than waved away: at three characters per token, a dozen
    /// tools' commas and brackets are a token of their own, and this number is
    /// what a context reservation is built from.
    static func serialisedCharacters(of tools: [CapabilityTool]) -> Int {
        guard !tools.isEmpty else { return 0 }
        return tools.reduce(0) { $0 + $1.schemaCharacters } + tools.count + 1
    }

    /// Ordered worst to best, so a caller can ask for "at least tight" rather
    /// than enumerating the two verdicts that satisfy it.
    ///
    /// As `Plan.fit` these answer a slightly different question — how well the
    /// window carried what was asked of it, rather than how full it is — and
    /// the case notes say what that turns each of them into.
    public enum Fit: Sendable, Equatable, Comparable {
        /// Over the share. Registering the set anyway would take the room the
        /// answer and the tool's own output need. A plan reads this when it
        /// armed nothing at all because the window refused everything.
        case willNotFit
        /// Fits, and leaves little of the window for anything else — or, for a
        /// plan, fits only because a capability was refused for budget.
        case tight
        /// Everything asked for is here, with room left for the answer.
        case comfortable

        public var allowsRegistration: Bool { self != .willNotFit }
    }

    public func fit(of tools: [CapabilityTool]) -> Fit {
        Self.fit(ofTokens: cost(of: tools), ceiling: ceilingTokens)
    }

    /// Where a number of tokens lands against a ceiling.
    ///
    /// Split out so `Plan.fit` grades itself on exactly this curve. A plan
    /// carries its own `tokens` and `ceilingTokens` and could compare them
    /// itself, and then there would be two places that decide what
    /// "comfortable" means and one of them would drift.
    static func fit(ofTokens tokens: Int, ceiling: Int) -> Fit {
        if tokens <= Int(Double(ceiling) * comfortableShareOfCeiling) { return .comfortable }
        if tokens <= ceiling { return .tight }
        return .willNotFit
    }

    /// How far over the ceiling a set is, in tokens; zero when it fits.
    ///
    /// This is what turns a refusal into an explanation. "Health needs 220 more
    /// tokens than this window can spare" tells someone what to change; "not
    /// registered" tells them the switch is broken.
    public func shortfall(of tools: [CapabilityTool]) -> Int {
        max(0, cost(of: tools) - ceilingTokens)
    }

    /// The shortest context that could carry all of these, or `nil` if no
    /// context this app offers can.
    ///
    /// The inverse of `DeviceBudget.largestFittingContext`, and reported in the
    /// same tiers a user actually picks from: the answer exists to be shown
    /// next to a refusal, and "needs 5,376 tokens" is not a thing anyone can
    /// select. Walked upward rather than bisected because the cost of a set
    /// does not vary with the context, so there are seven candidates and the
    /// first that fits is the answer.
    public func smallestFittingContext(
        for tools: [CapabilityTool],
        allowing worstAcceptable: Fit = .tight
    ) -> Int? {
        guard !tools.isEmpty else { return contextTokens }
        return MemoryEstimate.contextTiers.first { tier in
            CapabilityBudget(contextTokens: tier, templateIsToolNative: templateIsToolNative)
                .fit(of: tools) >= worstAcceptable
        }
    }

    /// Everything the caller has, in priority order, truncated to what fits.
    ///
    /// Used where there is no question to route — Settings showing what this
    /// model would carry, and the engine's own configured set.
    public func admit(_ tools: [CapabilityTool]) -> Plan {
        plan(considering: byPriority(tools), routedAway: [], from: tools)
    }

    /// The tools belonging to `groups`, in that group order, truncated to what
    /// fits.
    ///
    /// The group order is the primary key and tool priority only sorts within a
    /// group, which is the entire point of routing: when the question is about
    /// sleep, health's tools take the last slot ahead of the calendar's, even
    /// though the calendar outranks health everywhere else. A group absent from
    /// `groups` is not registered at all, which is how a caller that plans per
    /// question stops paying for the alarm schema when the question was about
    /// sleep.
    public func admit(_ tools: [CapabilityTool], routedTo groups: [CapabilityGroup]) -> Plan {
        let position = Dictionary(
            groups.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let requested = tools.enumerated().compactMap { offset, tool in
            position[tool.group].map { (place: $0, offset: offset, tool: tool) }
        }
        let excluded = tools.filter { position[$0.group] == nil }
        let ordered = requested
            .sorted { left, right in
                if left.place != right.place { return left.place < right.place }
                if left.tool.priority != right.tool.priority {
                    return left.tool.priority < right.tool.priority
                }
                // Swift's sort is not stable, and an unstable tie-break here
                // would mean the same question registering a different pair of
                // tools on different launches.
                return left.offset < right.offset
            }
            .map(\.tool)
        return plan(considering: ordered, routedAway: excluded, from: tools)
    }

    private func byPriority(_ tools: [CapabilityTool]) -> [CapabilityTool] {
        tools
            .enumerated()
            .sorted { left, right in
                if left.element.priority != right.element.priority {
                    return left.element.priority < right.element.priority
                }
                if left.element.group.rank != right.element.group.rank {
                    return left.element.group.rank < right.element.group.rank
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private func plan(
        considering candidates: [CapabilityTool],
        routedAway: [CapabilityTool],
        from all: [CapabilityTool]
    ) -> Plan {
        var registered: [CapabilityTool] = []
        var overBudget: [CapabilityTool] = []

        for tool in candidates {
            // Stopping at the first tool that will not fit, rather than
            // skipping it to see whether something smaller behind it would.
            // Skipping buys a few tokens and inverts the order the caller
            // stated — the calendar dropped so a timer could fit — which is a
            // decision nobody made and nothing downstream can explain.
            guard overBudget.isEmpty, cost(of: registered + [tool]) <= ceilingTokens else {
                overBudget.append(tool)
                continue
            }
            registered.append(tool)
        }

        let live = registered
        let spent = cost(of: live)

        // Priced cumulatively, because the stop rule is what dropped them: a
        // group behind the one that breached is not reachable on its own, and
        // quoting its price alone would offer a swap the plan will not make —
        // "timers needs 150 tokens" while a 4,096-token window it already has
        // is the one that refused it.
        var cumulative = live
        let short = group(overBudget).map { group, members -> Plan.Dropped in
            cumulative += members
            return Plan.Dropped(
                group: group,
                tools: members,
                reason: .overBudget,
                additionalTokens: cost(of: cumulative) - spent,
                contextTokens: smallestFittingContext(for: cumulative),
                needsABiggerContext: true
            )
        }

        // Routing exclusions are independent of each other and of the stop
        // rule, so each is priced on its own against what is live.
        let unasked = group(routedAway).map { group, members -> Plan.Dropped in
            let withGroup = cost(of: live + members)
            return Plan.Dropped(
                group: group,
                tools: members,
                reason: .notRouted,
                additionalTokens: withGroup - spent,
                contextTokens: smallestFittingContext(for: live + members),
                needsABiggerContext: withGroup > ceilingTokens
            )
        }

        return Plan(
            contextTokens: contextTokens,
            ceilingTokens: ceilingTokens,
            registered: registered,
            dropped: short + unasked,
            tokens: spent,
            everythingTokens: cost(of: all)
        )
    }

    /// Tools by group, in the order the groups first appear, so a plan reads
    /// back in the order it was decided rather than in a dictionary's.
    private func group(_ tools: [CapabilityTool]) -> [(CapabilityGroup, [CapabilityTool])] {
        var order: [CapabilityGroup] = []
        var members: [CapabilityGroup: [CapabilityTool]] = [:]
        for tool in tools {
            if members[tool.group] == nil { order.append(tool.group) }
            members[tool.group, default: []].append(tool)
        }
        return order.map { ($0, members[$0] ?? []) }
    }
}

public extension CapabilityBudget {
    /// What will be registered, what will not, and what the difference costs.
    ///
    /// Inspectable rather than a bare array because Settings has to show it,
    /// and a capability that is quietly absent is the same failure `ToolGate`
    /// exists to end: a switch that is on, a calendar that is never read, and
    /// nothing on screen that explains why.
    struct Plan: Sendable, Equatable {
        public var contextTokens: Int
        public var ceilingTokens: Int
        /// In the order they will be handed to the client.
        public var registered: [CapabilityTool]
        public var dropped: [Dropped]
        /// What `registered` adds to every prompt. This is the number that goes
        /// into `ContextGuard.fixedOverheadTokens`.
        public var tokens: Int
        /// What registering the whole inventory would have cost, so a plan can
        /// say what routing and truncation actually saved.
        public var everythingTokens: Int

        /// How well this window carried what was asked of it — the plan's
        /// verdict, not the survivors'.
        ///
        /// Derived rather than stored, so there is no way to hand a caller a
        /// plan whose verdict disagrees with what it holds. The verdict is the
        /// thing a badge binds to, and `fit(of: registered)` alone would paint
        /// the worst case green: a window too small for a single schema refuses
        /// everything, registers nothing, spends zero tokens of its ceiling and
        /// reads `.comfortable` — on the exact screen someone opens to find out
        /// why their calendar is never read.
        ///
        /// So the two empty plans are told apart by why they are empty. Nothing
        /// was asked for — an unrouted question, a model with no tools — and
        /// nothing failed, which is `.comfortable` and is the truth: a question
        /// about the sea does not want the calendar. Everything asked for was
        /// refused, and nothing is armed or can be, which is `.willNotFit` and
        /// makes `allowsRegistration` false, which is what a caller is really
        /// asking.
        ///
        /// A partial refusal caps at `.tight` for the same reason. Once the
        /// window is what decided which capabilities the user gets, "room to
        /// spare" is not a thing this plan has, however little of the ceiling
        /// the survivors happen to occupy.
        public var fit: Fit {
            let occupancy = CapabilityBudget.fit(ofTokens: tokens, ceiling: ceilingTokens)
            guard dropped.contains(where: { $0.reason == .overBudget }) else { return occupancy }
            return registered.isEmpty ? .willNotFit : min(occupancy, .tight)
        }

        public struct Dropped: Sendable, Equatable {
            public enum Reason: Sendable, Equatable {
                /// Nothing in the question asked for it. Whether it would have
                /// fitted is a separate question with its own answer in
                /// `needsABiggerContext` — at a small enough window it is no,
                /// and a row that assumed otherwise sent people off to reword
                /// a question that was never what refused them.
                case notRouted
                /// There was no room left under the share.
                case overBudget
            }

            public var group: CapabilityGroup
            public var tools: [CapabilityTool]
            public var reason: Reason
            /// What adding this group on top of what is live would cost. The
            /// marginal price, not the group's price in isolation, because the
            /// preamble is already paid for once anything is registered.
            public var additionalTokens: Int
            /// The shortest context that would bring this group back — the
            /// answer to "what do I change to get it".
            ///
            /// For an over-budget row that means the live set plus everything
            /// down to and including this group, because the stop rule is what
            /// refused it and nothing behind the breach is reachable on its
            /// own. For a routing exclusion it means the live set plus this
            /// group, which is all that was ever in the way. `nil` means no
            /// context this app offers is enough.
            public var contextTokens: Int?
            /// Whether this row's way out is a bigger context rather than a
            /// differently worded question.
            ///
            /// Always true for an over-budget row — the window is what refused
            /// it. For a routing exclusion it is the same arithmetic the plan
            /// would run if the question had asked: at a window too small to
            /// carry the group either way, an invitation to rephrase is an
            /// invitation to nothing, and `explanation` says so instead.
            public var needsABiggerContext: Bool
        }

        /// Capabilities with at least one tool registered.
        public var liveGroups: [CapabilityGroup] {
            var seen: [CapabilityGroup] = []
            for tool in registered where !seen.contains(tool.group) { seen.append(tool.group) }
            return seen
        }

        public var droppedGroups: [CapabilityGroup] { dropped.map(\.group) }

        /// Capabilities that are half here.
        ///
        /// Worth naming because a switch reading "Reminders: on" when only the
        /// read half of reminders was registered is a lie the user finds out
        /// about by asking the model to add one.
        public var partialGroups: [CapabilityGroup] {
            droppedGroups.filter { liveGroups.contains($0) }
        }

        /// The names to arm `ToolSyntaxScreen` with, and the names to compare
        /// against a client that is already built — see `isCovered(by:)`.
        public var toolNames: [String] { registered.map(\.name) }

        /// Whether a client already built with `resident` carries everything
        /// this plan asks for.
        ///
        /// Narrowing is not worth acting on and widening is. The client freezes
        /// its tools at construction, so changing the set means a new
        /// `llama_context`, a re-mapped model and a cold prompt cache — seconds
        /// on a phone. Paying that to *remove* a schema trades a visible stall
        /// for a couple of hundred invisible tokens, which is the wrong way
        /// round; paying it to add one is the only way the tool works at all.
        public func isCovered(by resident: [String]) -> Bool {
            let held = Set(resident)
            return registered.allSatisfy { held.contains($0.name) }
        }

        /// What Settings shows under the list, or `nil` when everything asked
        /// for is live.
        ///
        /// Only the over-budget refusals get a sentence. A capability the
        /// question never asked for is not a problem the user has, and saying
        /// so on every answer would make routing — which is a saving — read as
        /// a fault.
        public var explanation: String? {
            let short = dropped.filter { $0.reason == .overBudget }
            guard !short.isEmpty else { return nil }
            let names = short.map(\.group.displayName).joined(separator: ", ")
            return "\(names) could not be registered. A \(contextTokens)-token context allows \(ceilingTokens) tokens of tool schemas and \(tokens) of those are already spent."
        }
    }
}

public extension CapabilityBudget.Plan.Dropped {
    /// The row's own sentence, naming the price and the way out.
    ///
    /// The way out decides the wording, not the reason it was dropped. A
    /// capability this window could not carry even if the question had asked
    /// for it is a context problem however it came to be left out, and quoting
    /// it a price sends someone off to rephrase a question that was never what
    /// refused them — while the row was already holding the honest answer.
    var explanation: String {
        guard needsABiggerContext else {
            return "\(group.displayName) was not registered for this question. Asking for it would cost \(additionalTokens) tokens of context."
        }
        guard let contextTokens else {
            return "\(group.displayName) needs \(additionalTokens) more tokens than any context this app offers can spare."
        }
        return "\(group.displayName) needs \(additionalTokens) more tokens of context than this window can spare. A \(contextTokens)-token context fits it."
    }
}
