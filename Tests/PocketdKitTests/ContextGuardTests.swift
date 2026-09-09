import Foundation
import Testing
@testable import PocketdKit

/// A crash report from a real device is the reason this file exists:
/// `llama_batch.add(id:pos:seq_ids:logits:)` raising a Swift assertion inside
/// `Context.decode(text:)`, SIGTRAP, process gone. One oversized request from
/// any client took the whole server down and every other connection with it.
@Suite("Oversized prompts")
struct ContextGuardTests {

    @Test("a prompt past the window is refused, not passed to the model")
    func refusesOversized() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 512)
        )
        defer { Task { await harness.stop() } }

        let huge = String(repeating: "word ", count: 20_000)
        let (status, data) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: huge)],
                stream: false
            )
        ))

        #expect(status == 413)
        let body = try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: data)
        #expect(body.error.type == "context_length_exceeded")
    }

    @Test("the server still answers after refusing one")
    func survivesOversized() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 512)
        )
        defer { Task { await harness.stop() } }

        _ = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: String(repeating: "word ", count: 20_000))],
                stream: false
            )
        ))

        // The real defect was not the 413 — it was that nothing worked afterwards.
        let (status, _) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "still here?")],
                stream: false
            )
        ))
        #expect(status == 200)
    }

    @Test("refuses on the Ollama route too, in its own error shape")
    func ollamaRoute() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 512)
        )
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(try harness.request("POST", "/api/chat", json:
            Ollama.ChatRequest(
                model: "echo",
                messages: [Ollama.Message(role: "user", content: String(repeating: "word ", count: 20_000))],
                stream: false
            )
        ))
        #expect(status == 413)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(Ollama.ErrorResponse.self, from: data)
        }
    }

    @Test("an ordinary prompt is not refused")
    func allowsNormal() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 4096)
        )
        defer { Task { await harness.stop() } }

        let (status, _) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: String(repeating: "a paragraph of prose. ", count: 100))],
                stream: false
            )
        ))
        #expect(status == 200, "a 2 KB prompt in a 4096-token window must go through")
    }

    @Test("the estimate is pessimistic, never optimistic")
    func estimateIsPessimistic() {
        // Four characters per token is the English average; the guard uses three
        // so that code, JSON and non-Latin text cannot slip past it.
        let text = String(repeating: "x", count: 1200)
        #expect(ContextGuard.estimateTokens(text) >= text.count / 4)
        #expect(ContextGuard.charactersPerToken < 4)
    }

    @Test("reserves room for the answer")
    func reservesCompletion() {
        let guardian = ContextGuard(contextTokens: 1000, reservedForCompletion: 200)
        #expect(guardian.promptBudget == 800)
        // A prompt that exactly fills the window leaves nowhere to reply.
        let filling = [ChatMessage.user(String(repeating: "x", count: 1000 * ContextGuard.charactersPerToken))]
        #expect(guardian.fits(filling) == false)
    }
}

@Suite("Prompt overhead the guard cannot see")
struct PromptOverheadTests {

    /// Tool schemas are injected downstream, inside the inference library, after
    /// the guard has approved the prompt. Since llama.cpp asserts rather than
    /// erroring on an oversized prompt — the crash this guard exists to stop —
    /// an overhead it cannot see is an invitation to the same SIGTRAP.
    @Test("declared overhead comes out of the prompt budget")
    func overheadReducesBudget() {
        let plain = ContextGuard(contextTokens: 4096)
        let withTools = ContextGuard(contextTokens: 4096, fixedOverheadTokens: 860)
        #expect(withTools.promptBudget == plain.promptBudget - 860)

        let message = [ChatMessage.user(String(repeating: "x", count: 3 * 3900))]
        #expect(plain.fits(message))
        #expect(withTools.fits(message) == false, "the same prompt must be refused once tools are registered")
    }

    @Test("overhead can never drive the budget below one token")
    func budgetFloor() {
        let absurd = ContextGuard(contextTokens: 512, fixedOverheadTokens: 100_000)
        #expect(absurd.promptBudget == 1)
    }

    @Test("a tool-native template pays for the schema twice")
    func nativeTemplateDoubles() {
        let schema = String(repeating: "{\"name\":\"x\"}", count: 20)
        let plain = ContextGuard.toolOverhead(toolsJSON: schema, templateIsToolNative: false)
        let native = ContextGuard.toolOverhead(toolsJSON: schema, templateIsToolNative: true)
        // The template renders the tool block itself AND the library appends it
        // again, so a Qwen3-style model is charged for both.
        #expect(native > plain)
        #expect(native - ContextGuard.toolOverhead(toolsJSON: "", templateIsToolNative: true) > plain / 2)
    }

    @Test("no tools means no overhead at all")
    func freeWhenUnused() {
        #expect(ContextGuard.toolOverhead(toolsJSON: "", templateIsToolNative: true) == 0)
    }

    /// The first version of this asserted the constant against itself, which
    /// cannot fail and was also wrong by a character. This reconstructs the
    /// literal LocalLLMClient actually emits, so an edit to the constant is
    /// caught. It cannot detect the dependency changing — a test has no way to
    /// read that — so the comment on the constant says where to look.
    @Test("the preamble constant matches the string the library emits")
    func preambleLength() {
        let preamble = """
        If you decide to invoke any of the function(s), you MUST put it in the format of
        <tool_call>
        {"name": function name, "arguments": dictionary of argument name and its value}
        </tool_call>\n
        You SHOULD NOT include any other text in the response if you call a function
        \n
        """
        #expect(preamble.count == ContextGuard.toolPreambleCharacters)
    }
}

@Suite("Date context")
struct DateContextTests {
    private let noon = Date(timeIntervalSince1970: 1_788_955_200)

    @Test("names yesterday and tomorrow explicitly")
    func spellsOutRelativeDays() {
        let line = DateContext.sentence(
            now: noon,
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        // Small models are unreliable at date arithmetic, and every relative
        // question depends on it, so the neighbours are precomputed.
        #expect(line.contains("Yesterday was"))
        #expect(line.contains("Tomorrow is"))
        #expect(line.contains("UTC+00:00"))
    }

    @Test("is cheaper than the tool it replaces")
    func cheaperThanATool() {
        let line = DateContext.sentence(now: noon)
        // A get_current_datetime tool costs its schema plus forces the 264-char
        // preamble into existence: about 160 guard tokens before anything runs.
        #expect(ContextGuard.estimateTokens(line) < 120)
    }

    @Test("creates a system turn when the client sent none")
    func createsSystemTurn() {
        let injected = DateContext.inject(into: [.user("what's on tomorrow?")], now: noon)
        #expect(injected.count == 2)
        #expect(injected[0].role == .system)
        #expect(injected[1].role == .user)
    }

    @Test("prepends to an existing system turn without losing it")
    func preservesExistingSystemPrompt() {
        let injected = DateContext.inject(into: [.system("You are terse."), .user("hi")], now: noon)
        #expect(injected.count == 2)
        #expect(injected[0].content.contains("You are terse."))
        #expect(injected[0].content.contains("Current date and time"))
    }
}
