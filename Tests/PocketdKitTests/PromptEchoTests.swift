import Foundation
import Testing
@testable import PocketdKit

/// The brief's system prompt as it stood when the walkthrough caught SmolLM2
/// printing it — copied, so these tests do not move when the prompt is
/// reworded. `livePrompt` below covers whatever the prompt says today.
private let briefInstructions = """
You write a two or three sentence brief for the owner of this phone.
Warm and plain, and easy to read aloud. No lists, no markdown, no headings, no emoji.
Use only the facts below. Never invent an event, a reminder or a number, and say nothing about anything that is not listed.
Open by greeting them for the afternoon, by name: Sam.
Never mention yourself, a model, or how this was written.
"""

/// What `DateContext.inject` put in front of the chat's system turn that day.
private let chatSystem = """
Current date and time: Wednesday, 21 October 2026, 11:45 (Asia/Kolkata, UTC+05:30). \
Yesterday was Tuesday, 20 October 2026. Tomorrow is Thursday, 22 October 2026. \
The user's locale is en_IN and the week starts on Sunday.

You are a helpful assistant.
"""

@Suite("Prompt echo")
struct PromptEchoTests {

    @Test("the brief that was its own system prompt is all echo, and says so")
    func walkthroughBrief() {
        let leaked = "Warm and plain, and easy to read aloud. No lists, no markdown, no headings, no emoji. "
            + "Open by greeting them for the afternoon, by name: Sam. Never mention yourself, a model, or how this was written."
        let cleaned = PromptEcho(instructions: [briefInstructions]).clean(leaked)

        #expect(cleaned.echoed.count == 4)
        #expect(cleaned.text.isEmpty)
        #expect(cleaned.isMostlyEcho, "the brief falls back to its template on this")
        #expect(cleaned.echoFraction == 1)
    }

    @Test("whatever the brief prompt says today, echoing it is caught")
    func livePrompt() {
        let system = BriefPrompt.systemText(name: "Sam", timeOfDay: .morning)
        let lines = system.split(separator: "\n").map(String.init)
        let cleaned = PromptEcho(messages: [.system(system), .user("EVENTS\nnone")]).clean(lines.dropFirst().joined(separator: " "))
        #expect(cleaned.isMostlyEcho)
    }

    @Test("the answer that ended in its own context: machinery and narration go, the rest stays")
    func walkthroughAnswer() {
        let answer = "Next day is Friday, 23 October 2026, 11:45 (Asia/Kolkata, UTC+05:30). "
            + "Yesterday was Wednesday, 20 October 2026. "
            + "The user's locale is en_IN and the week starts on Sunday. You are a helpful assistant."
        let cleaned = PromptEcho(messages: [.system(chatSystem), .user("What's on next?")]).clean(answer)

        #expect(cleaned.echoed == [
            "Next day is Friday, 23 October 2026, 11:45 (Asia/Kolkata, UTC+05:30).",
            "The user's locale is en_IN and the week starts on Sunday.",
            "You are a helpful assistant.",
        ])
        // Wrong, but not an echo: PromptEcho is not a fact checker.
        #expect(cleaned.text == "Yesterday was Wednesday, 20 October 2026.")
        #expect(cleaned.isMostlyEcho)
    }

    @Test("the date paragraph is facts: repeating it is an answer, not a leak")
    func datesSurvive() {
        let echo = PromptEcho(messages: [.system(chatSystem)])
        #expect(echo.clean("Tomorrow is Thursday, 22 October 2026.").isClean)
        #expect(echo.clean("Yesterday was Tuesday, 20 October 2026.").isClean)
    }

    @Test("an answer with no echo comes back byte for byte")
    func cleanIsUntouched() {
        let answer = "  Good afternoon, Sam.\n\nLunch at The Arches is at 1:00 PM.   One reminder is overdue.\n"
        let cleaned = PromptEcho(instructions: [briefInstructions]).clean(answer)
        #expect(cleaned.isClean)
        #expect(cleaned.text == answer)
        #expect(!cleaned.isMostlyEcho)
        #expect(cleaned.echoFraction == 0)
    }

    @Test("a greeting that shares words with the greeting rule is not the rule")
    func greetingSurvives() {
        #expect(PromptEcho(instructions: [briefInstructions]).clean("Good afternoon, Sam.").isClean)
    }

    @Test("a real brief with an echoed tail keeps the brief")
    func echoedTail() {
        let brief = "Good afternoon, Sam. Lunch at The Arches is at 1:00 PM and one reminder is overdue. "
            + "Never mention yourself, a model, or how this was written."
        let cleaned = PromptEcho(instructions: [briefInstructions]).clean(brief)

        #expect(cleaned.text == "Good afternoon, Sam. Lunch at The Arches is at 1:00 PM and one reminder is overdue.")
        #expect(cleaned.echoed == ["Never mention yourself, a model, or how this was written."])
        #expect(!cleaned.isMostlyEcho)
    }

    @Test("a near-verbatim copy with punctuation and a word dropped is still a copy")
    func nearVerbatim() {
        let cleaned = PromptEcho(instructions: [briefInstructions]).clean("Warm and plain, easy to read aloud!")
        #expect(cleaned.echoed.count == 1)
    }

    @Test("narrating the prompt in the third person is caught; a user guide is not")
    func narration() {
        let echo = PromptEcho(instructions: [])
        #expect(!echo.clean("The user is asking about overdue appointments.").isClean)
        #expect(!echo.clean("The user wants to know what is next.").isClean)
        #expect(echo.clean("The user guide is in Settings, under Help.").isClean)
    }

    @Test("boilerplate is checked even when the request carried no system turn")
    func boilerplate() {
        let cleaned = PromptEcho(messages: [.user("hi")]).clean(
            "Hello there, how can I help today? You are a helpful AI assistant named SmolLM, trained by Hugging Face."
        )
        #expect(cleaned.text == "Hello there, how can I help today?")
        #expect(cleaned.echoed.count == 1)
    }

    @Test("the user's turn is material, never instructions")
    func userTurnIsMaterial() {
        let messages: [ChatMessage] = [.system(briefInstructions), .user("EVENTS\nLunch at The Arches, 1:00 PM")]
        #expect(PromptEcho(messages: messages).clean("Lunch at The Arches, 1:00 PM.").isClean)
    }

    @Test("removing a paragraph leaves no gap behind it")
    func tidiesParagraphs() {
        let answer = "Here is the plan.\n\nNo lists, no markdown, no headings, no emoji.\n\nYou have two meetings today."
        let cleaned = PromptEcho(instructions: [briefInstructions]).clean(answer)
        #expect(cleaned.text == "Here is the plan.\n\nYou have two meetings today.")
    }

    @Test("too little left to be an answer counts as mostly echo")
    func tooLittleLeft() {
        let cleaned = PromptEcho(instructions: [briefInstructions]).clean(
            "Hi. Use only the facts below. Never invent an event, a reminder or a number, and say nothing about anything that is not listed."
        )
        #expect(cleaned.text == "Hi.")
        #expect(cleaned.isMostlyEcho)
    }

    @Test("machine identifiers are read from the prompt that was actually sent")
    func identifiers() {
        let found = PromptEcho.machineIdentifiers(in: chatSystem)
        #expect(found.isSuperset(of: ["Asia/Kolkata", "UTC+05:30", "en_IN"]))
        #expect(PromptEcho.machineIdentifiers(in: "No identifiers here, just words.").isEmpty)
    }
}
