import Foundation
import Testing
@testable import PocketdKit

/// What reaches the transcript after a tool round, when the model narrates by
/// copying out the thing it was asked to narrate.
///
/// As with the syntax screen, the false-positive half is the half that matters:
/// this deletes text a model produced, and deleting somebody's real answer
/// because it mentioned their calendar would be a far worse bug than the echo
/// it exists to remove.
@Suite("Narration echo")
struct NarrationEchoTests {

    /// Exactly what `ToolResult.encode` produces and exactly what the engine
    /// passes as `toolOutputs` — sorted keys, no spaces.
    private static let calendar = ToolResult.encode(["text": "No events tomorrow."])
    private static let reminders = ToolResult.encode(["count": 2, "text": "Two reminders due today."])

    private static let armed = NarrationEcho(payloads: [calendar])

    @Test("the payload is what the engine actually hands over")
    func payloadIsTheRenderedPrompt() {
        // Not decoration: if this drifts, every other test here is comparing
        // against a string the model never saw.
        #expect(Self.calendar == #"{"text":"No events tomorrow."}"#)
        #expect(Self.armed.isArmed)
    }

    // MARK: - The echo

    @Test("a turn that is nothing but the payload is withheld and comes back empty")
    func exactEcho() {
        #expect(Self.armed.safeCount(in: Self.calendar) == 0)
        #expect(Self.armed.resolve(Self.calendar) == "")
    }

    @Test("a payload copied out inside a fence is still the payload")
    func echoInsideFences() {
        let text = "```json\n" + Self.calendar + "\n```"
        #expect(Self.armed.resolve(text) == "")
        // And the same with the tag spelled the other two ways a model writes it.
        #expect(Self.armed.resolve("``` JSON " + Self.calendar + " ```") == "")
        #expect(Self.armed.resolve("```\n" + Self.calendar + "\n```") == "")
    }

    @Test("a reasoning model's echo, below its own closing tag, is caught")
    func echoAfterReasoning() {
        let text = "<think>\nThey asked about tomorrow.\n</think>\n\n" + Self.calendar
        #expect(Self.armed.resolve(text) == "")
    }

    @Test("an echo with a real sentence after it keeps the sentence")
    func echoThenSentence() {
        let text = Self.calendar + "\n\nYou have nothing scheduled tomorrow."
        #expect(Self.armed.resolve(text) == "You have nothing scheduled tomorrow.")
    }

    @Test("the sentence survives whichever side of the echo it is written on")
    func sentenceBeforeEcho() {
        let text = "Here is what I found:\n```json\n" + Self.calendar + "\n```"
        #expect(Self.armed.resolve(text) == "Here is what I found:")
    }

    // MARK: - False positives

    @Test("a real sentence that mentions a value from the payload is untouched")
    func mentionsAValue() {
        // Every word of the payload's one value is in here, in order. What is
        // not in here is the payload, and that is the only thing compared.
        let text = "No events tomorrow — your calendar is clear until Thursday."
        #expect(Self.armed.resolve(text) == nil)
        #expect(Self.armed.safeCount(in: text) == text.count)
    }

    @Test("a reply that quotes one field of the payload is untouched")
    func quotesAField() {
        let text = #"The tool reported "text": "No events tomorrow." and nothing else."#
        #expect(Self.armed.resolve(text) == nil)
    }

    @Test("a clean turn is returned as nil rather than as itself")
    func cleanIsNilNotEmpty() {
        // `nil` is what tells the engine to leave `produced` byte for byte
        // alone — its reasoning block, its line breaks, its trailing newline.
        // An empty string means the opposite: rewrite the turn to nothing.
        #expect(Self.armed.resolve("Nothing tomorrow.") == nil)
        #expect(Self.armed.resolve("") == nil)
        #expect(Self.armed.resolve("<think>still working") == nil)
    }

    // MARK: - Mid-stream

    @Test("an echo is withheld while it forms, and released when it turns into prose")
    func prefixWithholdingThenRelease() {
        let full = Self.calendar + " Nothing is scheduled."
        var accumulated = ""
        var releasedAt: Int?
        for character in full {
            accumulated.append(character)
            let safe = Self.armed.safeCount(in: accumulated)
            #expect(safe == 0 || safe == accumulated.count)
            if safe > 0, releasedAt == nil { releasedAt = accumulated.count }
        }
        // Not one character before the payload is complete, and not one after
        // the first character that could not belong to it. The space in between
        // is trimmed by normalisation, so divergence lands on the "N".
        #expect(releasedAt == Self.calendar.count + 2)
    }

    @Test("a turn that is only the echo is never released at all")
    func pureEchoNeverStreams() {
        var accumulated = ""
        for character in Self.calendar {
            accumulated.append(character)
            #expect(Self.armed.safeCount(in: accumulated) == 0)
        }
        // Which is what lets the end of the turn delete it: nothing withheld
        // has been shown, and nothing shown can be taken back.
        #expect(Self.armed.resolve(accumulated) == "")
    }

    @Test("an ordinary answer streams from its first character")
    func proseIsNotDelayed() {
        // The one latency this type could add, and it does not: a narration
        // that opens with a letter has already diverged from a payload that
        // opens with a brace.
        #expect(Self.armed.safeCount(in: "Y") == 1)
        #expect(Self.armed.safeCount(in: "You have nothing tomorrow.") == 26)
    }

    // MARK: - Disarmed

    @Test("a payload too short to be distinctive is ignored")
    func shortPayloadsIgnored() {
        // Eleven characters against twelve. The short one is a sentence
        // somebody could plausibly write; the long one is not.
        let short = NarrationEcho(payloads: [#"{"count":3}"#])
        #expect(#"{"count":3}"#.count == 11)
        #expect(!short.isArmed)
        #expect(short.resolve(#"{"count":3}"#) == nil)
        #expect(short.safeCount(in: #"{"count":3}"#) == 11)

        let long = NarrationEcho(payloads: [#"{"count":30}"#])
        #expect(long.isArmed)
        #expect(long.resolve(#"{"count":30}"#) == "")
    }

    @Test("a round whose payloads are all short disarms as if none ran")
    func mixedLengthsKeepOnlyTheLongOnes() {
        let echo = NarrationEcho(payloads: [#"{"n":1}"#, Self.calendar])
        #expect(echo.payloads == [Self.calendar])
    }

    @Test("no payloads disarms it entirely")
    func emptyPayloadsDisarm() {
        // A generation with no tools must behave exactly as it did before this
        // type existed: nothing withheld, nothing rewritten, ever.
        let disarmed = NarrationEcho(payloads: [])
        #expect(!disarmed.isArmed)
        #expect(disarmed.safeCount(in: Self.calendar) == Self.calendar.count)
        #expect(disarmed.resolve(Self.calendar) == nil)
        #expect(disarmed.safeCount(in: "") == 0)
    }

    // MARK: - More than one call

    @Test("two calls in one round arm the screen with both payloads")
    func twoPayloads() {
        let echo = NarrationEcho(payloads: [Self.calendar, Self.reminders])
        #expect(echo.payloads.count == 2)

        // Both copied out, one after the other.
        #expect(echo.resolve(Self.calendar + "\n" + Self.reminders) == "")
        // Either one on its own, with the model's own sentence about the other.
        #expect(echo.resolve(Self.reminders + " Your calendar is clear.") == "Your calendar is clear.")
        #expect(echo.resolve("Two reminders, and " + Self.calendar) == "Two reminders, and")
        // And each is still withheld while it forms.
        #expect(echo.safeCount(in: String(Self.reminders.prefix(20))) == 0)
        // Prose about both is untouched.
        #expect(echo.resolve("Two reminders today, and nothing on tomorrow.") == nil)
    }

    @Test("the acknowledgement the engine substitutes says only what is true")
    func acknowledgementIsNeutral() {
        // It replaces narration that was deleted, on a round that produced no
        // card — so it must not claim anything about what was found.
        #expect(NarrationEcho.acknowledgement == "Done.")
        #expect(NarrationEcho.acknowledgement.count < 20)
    }
}
