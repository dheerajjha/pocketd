import Testing
import Foundation

/// Mirrors `MessageMarkdown.splitReasoning`.
///
/// The real one lives in the app target, which has no test bundle, so this
/// pins the behaviour against a copy. That is worth saying plainly: if the two
/// drift, these tests keep passing and the app keeps failing. The alternative
/// — no coverage of the rule that decides whether a reasoning model's answer is
/// visible at all — is worse.
private func splitReasoning(from text: String) -> (reasoning: String?, answer: String, isComplete: Bool) {
    let open = "<think>"
    let close = "</think>"
    // Plural, and that is not defensive coding. A tool turn runs the model
    // twice — once to decide on the call, once to speak with the result —
    // and both rounds land in one message, so a reply that used a tool
    // carries two reasoning blocks. Stripping only the first left the
    // second rendering as literal `<think>` in the bubble.
    var rest = Substring(text)
    var collected: [String] = []

    while true {
        let trimmed = rest.drop { $0.isWhitespace }

        // A half-arrived opening tag. Rendering `<think` as the answer and
        // then retracting it one token later is the same flicker the block
        // parser holds markers back to avoid; the neutral placeholder is
        // right here, because we genuinely do not know yet. Only `<` is
        // ambiguous with real prose — no other prefix of `<think>` opens a
        // plausible reply — so at most one character waits one token.
        if !trimmed.isEmpty, trimmed.count < open.count, open.hasPrefix(trimmed) {
            return (collected.isEmpty ? nil : collected.joined(separator: "\n\n"), "", true)
        }
        guard trimmed.hasPrefix(open) else { break }

        let afterOpen = trimmed.dropFirst(open.count)
        guard let closeRange = afterOpen.range(of: close) else {
            collected.append(String(afterOpen))
            return (collected.joined(separator: "\n\n"), "", false)
        }
        collected.append(String(afterOpen[..<closeRange.lowerBound]))
        rest = afterOpen[closeRange.upperBound...]
    }

    guard !collected.isEmpty else { return (nil, text, true) }
    return (collected.joined(separator: "\n\n"), String(rest), true)
}

@Suite("Reasoning blocks")
struct ReasoningSplitTests {
    @Test("a closed block separates working from answer")
    func closedBlock() {
        let result = splitReasoning(from: "<think>The user wants today.</think>You have one meeting.")
        #expect(result.reasoning == "The user wants today.")
        #expect(result.answer == "You have one meeting.")
        #expect(result.isComplete)
    }

    @Test("an unterminated block is all reasoning and no answer")
    func streamingBlock() {
        // The state every reasoning reply passes through, for seconds. Reading
        // the tail as an answer would flash half-formed working into the answer
        // slot and then retract it once the close tag lands.
        let result = splitReasoning(from: "<think>Let me check the calendar")
        #expect(result.reasoning == "Let me check the calendar")
        #expect(result.answer.isEmpty)
        #expect(result.isComplete == false)
    }

    @Test("a reply with no reasoning is untouched")
    func noReasoning() {
        let result = splitReasoning(from: "Just an answer.")
        #expect(result.reasoning == nil)
        #expect(result.answer == "Just an answer.")
        #expect(result.isComplete)
    }

    @Test("a mid-reply mention of the tag is not a reasoning block")
    func onlyAtTheStart() {
        // Qwen3 opens with the block; a model explaining the convention does
        // not, and swallowing everything after the word would delete the
        // answer someone asked for.
        let text = "Reasoning models emit <think> before answering."
        let result = splitReasoning(from: text)
        #expect(result.reasoning == nil)
        #expect(result.answer == text)
    }

    @Test("leading whitespace before the tag still counts")
    func leadingWhitespace() {
        let result = splitReasoning(from: "\n  <think>working</think>done")
        #expect(result.reasoning == "working")
        #expect(result.answer == "done")
    }

    @Test("an empty block yields nothing to show")
    func emptyBlock() {
        let result = splitReasoning(from: "<think></think>Answer.")
        #expect(result.reasoning == "")
        #expect(result.answer == "Answer.")
        #expect(result.isComplete)
    }

    @Test("a tool turn's two reasoning blocks are both stripped")
    func twoBlocksFromAToolTurn() {
        // The real shape of a reply that used a tool, taken from a transcript
        // on disk: the model reasons, calls, then reasons again before
        // speaking. Handling one block left the second rendering as literal
        // `<think>` in the bubble — which is exactly what shipped.
        let reply = "<think>\nI should call get_calendar_events.\n</think>"
            + "<think>\nThe tool returned one event.\n</think>"
            + "You have a dentist appointment at 11."
        let result = splitReasoning(from: reply)
        #expect(result.answer == "You have a dentist appointment at 11.")
        #expect(result.reasoning?.contains("I should call") == true)
        #expect(result.reasoning?.contains("The tool returned") == true)
        #expect(result.isComplete)
    }

    @Test("a second block still arriving leaves no answer showing")
    func secondBlockStreaming() {
        let reply = "<think>\nDecided.\n</think><think>\nStill working"
        let result = splitReasoning(from: reply)
        #expect(result.answer.isEmpty)
        #expect(result.isComplete == false)
    }

    @Test("every prefix of a reasoning reply is readable")
    func everyPrefixIsSane() {
        // The property that matters while streaming: the answer only ever
        // grows. A prefix that produced an answer must never produce a shorter
        // one as more text arrives, or the reader watches text disappear.
        let full = "<think>Checking the calendar now.</think>You have a dentist appointment."
        var longestAnswer = 0
        for length in 0...full.count {
            let prefix = String(full.prefix(length))
            let result = splitReasoning(from: prefix)
            #expect(result.answer.count >= longestAnswer,
                    "answer shrank at prefix length \(length)")
            longestAnswer = result.answer.count
        }
        #expect(longestAnswer == "You have a dentist appointment.".count)
    }
}
