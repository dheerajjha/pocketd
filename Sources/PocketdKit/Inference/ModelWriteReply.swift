import Foundation

extension ModelWriteTurn {
    /// At the phone's presentation boundary, show actual write receipts (a
    /// refusal, a failed save, an existing item, or a confirmed change). This
    /// is shared by downloaded, on-device Apple, and explicitly selected PCC.
    /// Ordinary sentences stream; only a possible status assertion is held.
    public func reporting(_ source: AsyncThrowingStream<GenerationEvent, any Error>) -> AsyncThrowingStream<GenerationEvent, any Error> {
        AsyncThrowingStream { output in
            let worker = Task {
                var prose = ModelWriteReply()
                var reported = false
                var toolWasCalled = false
                func finishText(interrupted: Bool = false) async {
                    guard !reported else { return }
                    reported = true
                    revoke()
                    let settled = await settledReceipt()
                    let actual = isRecall ? nil : settled
                    guard !Task.isCancelled else { return }
                    let result: String
                    if let actual { result = actual }
                    else if let intent {
                        guard !interrupted else { return }
                        let answer = prose.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                        result = answer.hasSuffix("?") && !ModelWriteReply.claimsChange(answer) ? answer : Self.refusal(for: intent.change)
                    } else {
                        let tail = prose.finish(toolWasCalled: toolWasCalled)
                        result = !prose.hasEmitted && tail.isEmpty ? settled ?? tail : tail
                    }
                    if !result.isEmpty { output.yield(.token((prose.hasEmitted && actual != nil ? "\n\n" : "") + result)) }
                }
                do {
                    for try await event in source {
                        switch event {
                        case .token(let text):
                            if narrationReceipt != nil { continue } // the action's own words replace any narration
                            if intent != nil { prose.tail += text; continue }
                            let safe = prose.feed(text)
                            if !safe.isEmpty { output.yield(.token(safe)) }
                        case .finished(let reason, _):
                            await finishText(interrupted: reason == .cancelled)
                            output.yield(event)
                        case .toolCallStarted:
                            toolWasCalled = true; output.yield(event)
                        case .answerCard(let card) where isRecall && Change.allCases.contains(where: { card.lede == Self.refusal(for: $0) }):
                            break // an unsolicited, refused write isn't the answer to a recall question
                        default: output.yield(event)
                        }
                    }
                    await finishText(interrupted: Task.isCancelled); output.finish()
                } catch {
                    await finishText(interrupted: true)
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { _ in self.revoke(); worker.cancel() }
        }
    }
}

/// Do not infer tool success from a model sentence. Recognize a few *personal
/// write status* forms, not words such as “set”/“done” anywhere in prose. This
/// is a presentation backstop for unparsed calls, not the authorization gate.
struct ModelWriteReply {
    var tail = ""
    private(set) var hasEmitted = false
    private var ordinary = false
    private var holding = false
    private var holdingToolSyntax = false

    private static let verbs = ["add", "set", "schedule", "book", "create", "save", "mark", "tick", "complete", "added", "scheduled", "booked", "created", "saved", "marked", "ticked", "completed", "put", "creating", "adding", "setting", "scheduling", "booking", "saving", "completing", "ticking"]
    private static let leads = ["i ", "i've ", "i have ", "i'm ", "i am ", "i'll ", "i will ", "i'm going to ", "i am going to ", "i've just ", "i have just ", "i just "].flatMap { prefix in verbs.map { prefix + $0 } }
        + ["reminder ", "event ", "calendar event ", "your reminder ", "your event ", "your appointment ", "the reminder ", "the event "].flatMap { prefix in
            ["is ", "was ", "has been ", "set", "created", "added", "scheduled", "booked", "saved", "completed", "marked"].map { prefix + $0 }
        } + ["added", "created", "scheduled", "booked", "saved", "marked", "ticked", "completed", "i'll remind you", "i will remind you", "<|tool_call_start|>", "<tool_call>"]
    private static let acknowledgments = ["sure", "okay", "ok", "yes", "done", "all set", "of course", "certainly"]
    static let noChange = "Pocketd didn't change your calendar or reminders."
    static let noLookup = "Pocketd didn't run that lookup."

    mutating func feed(_ text: String) -> String {
        var safe = ""
        for c in text {
            if holding {
                tail.append(c)
                // Once a candidate sentence is complete, release ordinary
                // prose immediately. Only raw tool syntax needs its whole tail.
                if !holdingToolSyntax, ".!?\n".contains(c) {
                    safe += finish(toolWasCalled: false)
                    tail = ""; holding = false
                }
                continue
            }
            if ordinary {
                safe.append(c)
                if ".!?\n".contains(c) { ordinary = false }
                continue
            }
            tail.append(c)
            var prefix = Self.fold(tail).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.isEmpty { continue }
            if Self.acknowledgments.contains(where: { $0.hasPrefix(prefix) }) { continue }
            if let ack = Self.acknowledgments.first(where: { prefix.hasPrefix($0) }),
               let next = prefix.dropFirst(ack.count).first, ",.!: ".contains(next) {
                prefix = String(prefix.dropFirst(ack.count)).trimmingCharacters(in: CharacterSet(charactersIn: ",.!: "))
                if prefix.isEmpty { continue }
            }
            if Self.leads.contains(where: { prefix.hasPrefix($0) }) {
                holding = true; holdingToolSyntax = prefix.hasPrefix("<"); continue
            }
            if Self.leads.contains(where: { $0.hasPrefix(prefix) }) { continue }
            safe += tail; tail = ""; ordinary = !".!?\n".contains(c)
        }
        if !safe.isEmpty { hasEmitted = true }
        return safe
    }

    func finish(toolWasCalled: Bool) -> String {
        let prefix = String(tail.prefix(while: \.isWhitespace))
        if Self.claimsChange(tail) { return prefix + Self.noChange }
        // Liquid can print a native lookup followed by “I am retrieving…”
        // without the backend accepting a single call. A literal tool prelude
        // and zero dispatches are evidence; conversational prose alone isn't.
        if !toolWasCalled, Self.fold(tail).range(of: #"^\s*<\|tool_call_start\|>\s*\[\s*(?:(?:calendar|reminders|get_health_summary)\s*\(|\{\s*"name"\s*:\s*"(?:calendar|reminders|get_health_summary)")"#, options:.regularExpression) != nil {
            return prefix + Self.noLookup
        }
        return tail
    }

    private static func fold(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "’", with: "'") }

    static func claimsChange(_ answer: String) -> Bool {
        let s = fold(answer)
        // Match at a sentence boundary, not e.g. 'The phrase “I created a
        // reminder” is in the past tense.' Unparsed Liquid calls can be
        // followed immediately by a fabricated status, with no punctuation.
        if s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"),
           s.range(of: #"(?s)(?:<\|tool_call_start\|>|<tool_call>).{0,1500}?(?:\baction["']?\s*[:=]\s*["'](?:create|complete)["']|<parameter=action>\s*(?:create|complete))"#, options: .regularExpression) != nil { return true }
        let lead = #"(?:^|[.!?\n]\s*|<\|tool_call_end\|>\s*)\s*(?:(?:sure|okay|ok|yes|done|all set|of course|certainly)[!,.:\s]+)*"#
        let finished = #"(?:added|created|scheduled|booked|saved|marked|completed|ticked off)"#
        let personalVerb = #"i(?:'ve| have|'m| am|'ll| will)?\s+(?:(?:going to|just)\s+)?(?:add|create|set(?: up)?|schedule|book|save|mark|complete|tick off|put|creating|adding|setting|scheduling|booking|saving|completing|ticking off|"# + finished + ")"
        // A bare imperative (“Create a reminder by tapping …”) is instruction,
        // not an assertion that Pocketd has done or will do it.
        let action = "(?:" + personalVerb + "|" + finished + ")"
        let object = #"(?:(?:a|an|your|the|that|this|new|you|up)\s+)*(?:reminder|event|appointment)\b(?![\s-]+(?:app|example|template|handler|class|listener|type|system)\b)"#
        let status = #"(?:(?:calendar event|reminder|event|appointment)\s+(?:set|created|added|scheduled|booked|saved|completed)\s*[:!]|your (?:reminder|event|appointment) has (?:just )?been (?:set|created|added|scheduled|booked|saved|completed)\b)"#
        let personal = #"(?:i'll|i will)\s+remind you\b(?!\s+(?:that|of|how|why|what)\b)"#
        // Scheduling a meeting is a diary-status assertion. Merely creating
        // a meeting agenda, scheduling a meeting in an example, etc. isn't.
        let meeting = #"(?:i(?:'ve| have|'m| am|'ll| will)?\s+(?:(?:going to|just)\s+)?(?:schedul(?:e|ed|ing)|book(?:ed|ing)?)|scheduled|booked)\s+(?:(?:a|the|your|our|new|team)\s+)*meeting\b(?=\s+(?:with|for|at|on|tomorrow|today|next)\b|[.!]|$)"#
        return [personal, status, meeting, action + #"\s+"# + object,
                action + #"\s+[^.!?\n]{1,180}\s+(?:to|in|on) your (?:calendar|reminders(?: list)?)\b"#]
            .contains { s.range(of: lead + $0, options: .regularExpression) != nil }
    }
}
