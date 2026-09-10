import Foundation
import Testing
@testable import PocketdKit

/// What reaches the transcript when the model gets the tool protocol wrong.
///
/// The false-positive half of this suite is the important half: a backstop that
/// eats a legitimate reply about JSON is a worse bug than the one it fixes,
/// because the leak at least looks broken.
@Suite("Tool syntax screen")
struct ToolSyntaxScreenTests {

    private static let armed = ToolSyntaxScreen(toolNames: ["get_calendar_events", "get_reminders"])

    /// The reply Llama 3.2 1B actually produced, first characters verbatim.
    private static let observedLeak = """
    <|python_tag|>{
        "function": {
            "description": "List the user's calendar events (meetings, appointments) for a range of days.",
            "name": "get_calendar_events",
            "parameters": {
                "properties": {
                    "range": {
                        "description": "Which days to list.",
                        "enum": ["today", "tomorrow", "this_week", "next_week"],
                        "type": "string"
                    }
                },
                "required": ["range"],
                "type": "object"
            }
        },
        "type": "function"
    }
    """

    // MARK: - The leak

    @Test("the reply that shipped never reaches the transcript")
    func observedFailure() {
        #expect(Self.armed.safeCount(in: Self.observedLeak) == 0)
        #expect(Self.armed.resolve(Self.observedLeak) == .leaked(keeping: 0))
    }

    @Test("every marker in the catalogue's templates is caught")
    func allMarkers() {
        for marker in ToolSyntaxScreen.markers {
            let text = marker + #"{"name": "get_reminders"}"#
            #expect(Self.armed.resolve(text) == .leaked(keeping: 0), "\(marker)")
            #expect(Self.armed.safeCount(in: text) == 0, "\(marker)")
        }
    }

    @Test("a bare call with no marker around it is caught")
    func bareCall() {
        // Llama 3.2's own template renders a call as exactly this, with nothing
        // wrapping it, so no marker test can see it.
        let text = #"{"name": "get_calendar_events", "parameters": {"range": "next_week"}}"#
        #expect(Self.armed.resolve(text) == .leaked(keeping: 0))
    }

    @Test("a hallucinated tool name in the OpenAI shape is caught too")
    func hallucinatedName() {
        let text = #"{"name": "get_weather", "arguments": {"city": "Paris"}}"#
        #expect(Self.armed.resolve(text) == .leaked(keeping: 0))
    }

    @Test("a reasoning model's bare call, one line below its own closing tag, is caught")
    func afterReasoningBlock() {
        // Watched on a device: Qwen3 1.7B puts `<think>…</think>` in front of
        // every reply, so a call it forgot to wrap arrives *after* the block
        // and not at the front of the turn. A rule that looked only at the
        // first character would wave it straight through.
        let think = "<think>\n\nThe user wants their calendar.\n\n</think>\n\n"
        let text = think + #"{"name": "get_calendar_events", "arguments": {"range": "today"}}"#
        let keeping = text.distance(from: text.startIndex, to: text.range(of: "{\"name")!.lowerBound)
        #expect(Self.armed.resolve(text) == .leaked(keeping: keeping))
        #expect(Self.armed.safeCount(in: text) == keeping)
    }

    @Test("a reasoning model's legitimate JSON answer is still untouched")
    func afterReasoningBlockClean() {
        let think = "<think>\n\nThey asked for JSON.\n\n</think>\n\n"
        let text = think + #"{"city": "Paris", "country": "France", "population": 2100000}"#
        // Verified against the running app over its own HTTP API: this exact
        // shape came back byte for byte with both tools registered.
        #expect(Self.armed.resolve(text) == .clean)
    }

    @Test("prose before a leak is kept, and never left promising an answer")
    func prosePlusLeak() {
        let prose = "Let me check your calendar.\n\n"
        let text = prose + "<|python_tag|>" + #"{"name": "get_calendar_events"}"#
        // The prose is 29 characters including the two newlines; the engine
        // trims them and appends the notice, so nothing is left hanging.
        #expect(Self.armed.resolve(text) == .leaked(keeping: prose.count))
        #expect(Self.armed.safeCount(in: text) == prose.count)
    }

    @Test("the notice does not claim anything was read")
    func noticeIsHonest() {
        // The one thing worse than a schema dump would be telling someone their
        // calendar was consulted when no tool ran.
        #expect(ToolSyntaxScreen.notice.contains("Nothing was read"))
        #expect(!ToolSyntaxScreen.notice.contains("your calendar"))
        #expect(ToolSyntaxScreen.notice.count < 200)
    }

    // MARK: - False positives

    @Test("a reply that merely talks about JSON and tool tags is untouched")
    func mentionsJSON() {
        let text = """
        Sure. A JSON object has a "name" key and an "arguments" key, and you \
        write it like {"name": "x", "arguments": {}}. The <tool_call> tag is \
        Qwen's, not JSON's.
        """
        // Every trigger in this file is in there: both key pairs, a brace, and
        // a marker. None of it fires. The reply does not open with a brace, and
        // the marker is followed by the word it is being explained with rather
        // than by a payload.
        #expect(Self.armed.resolve(text) == .clean)
        #expect(Self.armed.safeCount(in: text) > 0)
    }

    @Test("a tag in prose is a mention; the same tag with a payload is a call")
    func mentionVersusCall() {
        let mention = "You would normally see <tool_call> followed by the arguments."
        #expect(Self.armed.resolve(mention) == .clean)

        let call = "Checking your calendar. <tool_call>" + #"{"name": "get_reminders"}"#
        let prefix = call.distance(from: call.startIndex, to: call.range(of: "<tool_call>")!.lowerBound)
        #expect(Self.armed.resolve(call) == .leaked(keeping: prefix))
    }

    @Test("a reply that is a JSON object because the user asked for one is untouched")
    func legitimateJSONReply() {
        let text = #"{"city": "Paris", "temperature": 12, "conditions": "overcast"}"#
        #expect(Self.armed.resolve(text) == .clean)
    }

    @Test("a fenced JSON code block is untouched")
    func fencedBlock() {
        let text = """
        Here you go:

        ```json
        {"name": "example", "parameters": {"a": 1}}
        ```
        """
        // Both keys of a tool call are in there. It is not one, and the only
        // reason the screen can tell is that the turn does not open with a
        // brace.
        #expect(Self.armed.resolve(text) == .clean)
    }

    @Test("a long JSON array of the user's own data is untouched")
    func longArray() {
        let rows = (0..<40).map { #"{"id": \#($0), "label": "row \#($0)"}"# }.joined(separator: ", ")
        let text = "[" + rows + "]"
        #expect(text.count > ToolSyntaxScreen.blobProbeCharacters)
        #expect(Self.armed.resolve(text) == .clean)
        // And it streams: once the probe is past and clean, the screen stops
        // withholding.
        #expect(Self.armed.safeCount(in: text) > 0)
    }

    @Test("with no tools registered nothing is screened at all")
    func disarmed() {
        let screen = ToolSyntaxScreen()
        #expect(screen.isArmed == false)
        #expect(screen.resolve(Self.observedLeak) == .clean)
        #expect(screen.safeCount(in: Self.observedLeak) == Self.observedLeak.count)
        // Someone asking what `<|python_tag|>` means deserves to be shown it,
        // and with no tools in the prompt there is nothing for a model to leak.
        let question = "The <|python_tag|> token marks a call to Llama's code interpreter."
        #expect(screen.resolve(question) == .clean)
    }

    // MARK: - Streaming

    @Test("a marker is never half-emitted, however the chunks fall")
    func neverPartiallyEmitted() {
        let full = "Checking. <|python_tag|>" + #"{"name": "get_reminders"}"#
        let safeBefore = full.distance(from: full.startIndex, to: full.range(of: "<|python_tag|>")!.lowerBound)
        var accumulated = ""
        var cleared = 0
        for character in full {
            accumulated.append(character)
            let next = Self.armed.safeCount(in: accumulated, clearedThrough: cleared)
            // Monotone: nothing already released is ever un-released, because
            // it cannot be.
            #expect(next >= cleared)
            // And never past the marker, at any chunk boundary.
            #expect(next <= safeBefore)
            cleared = next
        }
        #expect(cleared == safeBefore)
    }

    @Test("the cleared-through hint does not change the answer")
    func hintIsOnlyAnOptimisation() {
        // The engine passes it so a growing reply is not rescanned from the
        // top; a wrong answer under the hint would be a silent leak.
        let text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa<tool_call>{}"
        let cold = Self.armed.safeCount(in: text, clearedThrough: 0)
        for hint in 0...cold {
            #expect(Self.armed.safeCount(in: text, clearedThrough: hint) == cold, "hint \(hint)")
        }
    }

    @Test("an ordinary reply is held back only by the length of the longest marker")
    func holdBackIsBounded() {
        let text = String(repeating: "the quick brown fox. ", count: 20)
        let longest = ToolSyntaxScreen.markers.map(\.count).max()!
        #expect(Self.armed.safeCount(in: text) == text.count - (longest - 1))
        // And the tail comes back at the end of the turn.
        #expect(Self.armed.resolve(text) == .clean)
    }

    @Test("a brace-opening reply streams once the probe has cleared it")
    func braceReplyStreamsEventually() {
        let text = #"{"note": "#
            + #"""#
            + String(repeating: "a genuinely long answer that happens to be JSON. ", count: 8)
            + #""}"#
        var cleared = 0
        var releasedAt: Int?
        var accumulated = ""
        for character in text {
            accumulated.append(character)
            cleared = Self.armed.safeCount(in: accumulated, clearedThrough: cleared)
            if cleared > 0, releasedAt == nil { releasedAt = accumulated.count }
        }
        // Withheld until the probe, then released — not withheld to the end.
        #expect(releasedAt == ToolSyntaxScreen.blobProbeCharacters)
        #expect(Self.armed.resolve(text) == .clean)
    }
}
