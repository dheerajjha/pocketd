import Foundation
import Testing
@testable import PocketdKit

/// The tail of Qwen3's hybrid template, as read from `Qwen3-1.7B-Q4_K_M.gguf`.
private let qwen3Template = """
{%- for message in messages %}{%- if '</think>' in message.content %}{%- set content = (message.content.split('</think>')|last) %}{%- endif %}{%- endfor %}
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\\n' }}
    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\\n\\n</think>\\n\\n' }}
    {%- endif %}
{%- endif %}
"""

/// Gemma 4's switch, as read from `gemma-4-E2B-it-Q4_K_M.gguf`.
private let gemma4Template = """
{%- set enable_thinking = enable_thinking | default(false) -%}
{%- if enable_thinking -%}{{- '<|think|>\\n' -}}{%- endif -%}
{%- if add_generation_prompt -%}{{- '<|turn>model\\n' -}}{%- endif -%}
"""

/// A template that opens the block itself (DeepSeek R1 distills, Qwen3 "Thinking").
private let prefillTemplate = """
{%- if add_generation_prompt %}{{'<｜Assistant｜><think>\\n'}}{%- endif %}
"""

private let smolTemplate = """
{% for message in messages %}{{'<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>' + '\\n'}}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% endif %}
"""

@Suite("Thinking policy")
struct ThinkingPolicyTests {

    @Test("the phone's own generations never think; other devices follow the server switch")
    func policy() {
        let routine = RequestOrigin.scheduledTask(id: UUID())
        let laptop = RequestOrigin.network(host: "192.168.1.9", port: 50_000)
        for serverSetting in [true, false] {
            #expect(!ThinkingPolicy.allowsThinking(for: .onDeviceChat, serverAllowsThinking: serverSetting))
            #expect(!ThinkingPolicy.allowsThinking(for: routine, serverAllowsThinking: serverSetting))
            #expect(ThinkingPolicy.allowsThinking(for: laptop, serverAllowsThinking: serverSetting) == serverSetting)
        }
        #expect(ThinkingPolicy.stripsReasoning(for: .onDeviceChat))
        #expect(ThinkingPolicy.stripsReasoning(for: routine))
        #expect(!ThinkingPolicy.stripsReasoning(for: laptop), "a network client asked for the raw output")
    }

    @Test("Qwen3 is told /no_think on the latest user turn, once")
    func qwenSoftSwitch() {
        let messages: [ChatMessage] = [.system("Be brief."), .user("first"), .assistant("ok"), .user("What's on today?")]
        let off = ThinkingSwitch.turningThinkingOff(messages, chatTemplate: qwen3Template)

        #expect(off[3].content == "What's on today?\n/no_think")
        #expect(Array(off.prefix(3)) == Array(messages.prefix(3)), "history is not restated")
        #expect(ThinkingSwitch.turningThinkingOff(off, chatTemplate: qwen3Template) == off, "never twice")
    }

    @Test("templates without the soft switch are left alone", arguments: [gemma4Template, prefillTemplate, smolTemplate])
    func otherTemplatesUntouched(template: String) {
        let messages: [ChatMessage] = [.user("What's on today?")]
        #expect(ThinkingSwitch.turningThinkingOff(messages, chatTemplate: template) == messages)
        #expect(ThinkingSwitch.turningThinkingOff(messages, chatTemplate: nil) == messages)
    }

    @Test("a template that opens the block itself is recognised; Qwen3's closed one is not")
    func prefill() {
        #expect(ThinkingSwitch.generationPromptOpensReasoning(chatTemplate: prefillTemplate))
        #expect(!ThinkingSwitch.generationPromptOpensReasoning(chatTemplate: qwen3Template))
        #expect(!ThinkingSwitch.generationPromptOpensReasoning(chatTemplate: gemma4Template))
        #expect(!ThinkingSwitch.generationPromptOpensReasoning(chatTemplate: smolTemplate))
        #expect(!ThinkingSwitch.generationPromptOpensReasoning(chatTemplate: nil))
    }
}

@Suite("Reasoning filter")
struct ReasoningFilterTests {

    /// Feeds `chunks` one at a time and returns what a reader would have seen.
    private func stream(_ chunks: [String], startsInside: Bool = false) -> String {
        var filter = ReasoningFilter(startsInsideReasoning: startsInside)
        return chunks.map { filter.feed($0) }.joined() + filter.finish()
    }

    @Test("Qwen3 with thinking off: the empty block and its blank lines vanish")
    func emptyBlock() {
        #expect(stream(["<think>\n\n</think>\n\n", "You have ", "one meeting."]) == "You have one meeting.")
    }

    @Test("a full block of working never reaches the screen")
    func fullBlock() {
        #expect(ReasoningFilter.strip("<think>The user wants today. Check the calendar.</think>\n\nOne meeting at 3.") == "One meeting at 3.")
    }

    @Test("tags split across chunks are still tags", arguments: [
        ["<th", "ink>work</th", "ink>Answer."],
        ["<", "think>", "work", "<", "/think>", "Answer."],
        ["<think>work</think", ">Answer."],
    ])
    func splitTags(chunks: [String]) {
        #expect(stream(chunks) == "Answer.")
    }

    @Test("a block that never closes is all working: nothing is shown")
    func unclosed() {
        // The brief capped at 160 tokens used to run out inside `<think>`.
        #expect(stream(["<think>Let me think about the user's day", " and what matters most"]) == "")
    }

    @Test("prose streams as it arrives; only a possible tag is held back")
    func streamingLatency() {
        var filter = ReasoningFilter()
        #expect(filter.feed("Lunch is at 1") == "Lunch is at 1")
        #expect(filter.feed(":00 <") == ":00 ")
        #expect(filter.feed("3 to go") == "<3 to go", "a `<` that turned out to be prose is released")
        #expect(filter.finish() == "")
    }

    @Test("a reply ending in a bare `<` keeps it")
    func trailingAngle() {
        #expect(stream(["1 <"]) == "1 <")
    }

    @Test("Gemma 4's thought channel is working too")
    func gemmaChannel() {
        #expect(stream(["<|channel>thought\nThe user asks", " about lunch.<channel|>", "Lunch is at 1."]) == "Lunch is at 1.")
    }

    @Test("two rounds of working around a tool call both go")
    func twoBlocks() {
        #expect(ReasoningFilter.strip("<think>a</think>Checking.<think>b</think> Done.") == "Checking.Done.")
    }

    @Test("a template that opened the block itself: everything before the close is working")
    func prefilled() {
        #expect(stream(["The user wants", " lunch.</think>\n\n", "Lunch is at 1."], startsInside: true) == "Lunch is at 1.")
        #expect(stream(["still thinking"], startsInside: true) == "")
    }

    @Test("a stray closing tag is removed, the text around it kept")
    func strayClose() {
        #expect(ReasoningFilter.strip("Lunch is at 1.</think> See you.") == "Lunch is at 1. See you.")
    }

    @Test("an answer with no reasoning passes through, minus leading blank lines")
    func plainAnswer() {
        #expect(stream(["\n\n", "Hello ", "there.\n\nTwo lines."]) == "Hello there.\n\nTwo lines.")
    }
}
