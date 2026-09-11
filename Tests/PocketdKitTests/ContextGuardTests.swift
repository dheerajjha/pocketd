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
        // Four bytes per token is the English average; the guard uses three
        // so that code, JSON and non-Latin text cannot slip past it.
        let text = String(repeating: "x", count: 1200)
        #expect(ContextGuard.estimateTokens(text) >= text.utf8.count / 4)
        #expect(ContextGuard.bytesPerToken < 4)
    }

    /// The unit, pinned against the thing that kills the process.
    ///
    /// `String.count` is extended grapheme clusters, and dividing those by three
    /// is a claim of three *bytes* per token that holds only for ASCII. Measured
    /// in clusters, 12,000 Japanese characters priced at 4,004 guard tokens
    /// against a budget of 4,032 — admitted, and about 12,000 real tokens once a
    /// Qwen-class tokenizer had them. llama.cpp does not error on that batch.
    @Test("a prompt is priced by its bytes, so non-Latin text cannot walk past the guard")
    func nonLatinTextIsPricedByItsBytes() {
        let guardian = ContextGuard(contextTokens: 4096)
        #expect(guardian.promptBudget == 4032)

        // 12,000 clusters, 36,000 bytes. Counted as clusters this was 4,000
        // guard tokens, which is nine bytes for every token reserved.
        let japanese = [ChatMessage.user(String(repeating: "\u{65E5}", count: 12_000))]
        #expect(ContextGuard.estimateTokens(japanese) >= 12_000)
        #expect(guardian.fits(japanese) == false)

        // The worse of the two: one grapheme cluster, four emoji and three
        // joiners, twenty-five bytes — seventy-five bytes per guard token.
        let emoji = [ChatMessage.user(String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 4_000))]
        #expect(ContextGuard.estimateTokens(emoji) >= 33_000)
        #expect(guardian.fits(emoji) == false)

        // And the half that must not move. ASCII is one byte per character, so
        // every prompt the guard admitted before this it still admits, at the
        // same number.
        let ascii = String(repeating: "a paragraph of prose. ", count: 100)
        #expect(ascii.utf8.count == ascii.count)
        #expect(ContextGuard.estimateTokens(ascii) == (ascii.count + 2) / 3)
        #expect(guardian.fits([ChatMessage.user(ascii)]))
    }

    /// The same defect, through the route that would have served the 500.
    ///
    /// A 1,000-character Japanese question is 338 guard tokens counted as
    /// clusters and 1,004 counted as bytes, against a 448-token budget — so it
    /// went to the model, and what came back was whatever llama.cpp does with a
    /// batch twice the size of its window.
    @Test("a Japanese prompt past the window is refused exactly like an English one")
    func refusesOversizedNonLatin() async throws {
        let harness = try await TestServer.start(
            configuration: ServerConfiguration(port: 0, binding: .loopback, maxContextTokens: 512)
        )
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: String(repeating: "\u{65E5}", count: 1_000))],
                stream: false
            )
        ))

        #expect(status == 413)
        let body = try JSONDecoder().decode(OpenAI.ErrorResponse.self, from: data)
        #expect(body.error.type == "context_length_exceeded")
    }

    @Test("reserves room for the answer")
    func reservesCompletion() {
        let guardian = ContextGuard(contextTokens: 1000, reservedForCompletion: 200)
        #expect(guardian.promptBudget == 800)
        // A prompt that exactly fills the window leaves nowhere to reply.
        let filling = [ChatMessage.user(String(repeating: "x", count: 1000 * ContextGuard.bytesPerToken))]
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

    /// The reservation and the estimate have to be in one unit or the budget
    /// admits a tool set the guard then charges more for, under-reserves by the
    /// difference, and hands llama.cpp the batch this file exists to refuse.
    @Test("a schema is priced by its bytes too, so the two sides stay one number")
    func schemasArePricedByTheirBytes() {
        let schema = #"[{"type":"function","function":{"description":"健康データを読みます"}}]"#
        #expect(schema.utf8.count > schema.count)

        #expect(
            ContextGuard.toolOverhead(toolsJSON: schema, templateIsToolNative: false)
                == ContextGuard.toolOverhead(schemaCharacters: schema.utf8.count, templateIsToolNative: false)
        )
        // The ASCII schemas the app actually generates are unmoved, which is
        // what keeps `CapabilityBudget`'s `String.count` and this the same
        // number for every tool that exists today.
        #expect(
            ContextGuard.toolOverhead(toolsJSON: Self.personalDataToolsSchema, templateIsToolNative: true)
                == ContextGuard.toolOverhead(
                    schemaCharacters: Self.personalDataToolsSchema.count, templateIsToolNative: true
                )
        )
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

    /// What the two personal-data tools actually cost when they are switched on.
    ///
    /// Reconstructed, not imported: the schema is produced by LocalLLMClient's
    /// `@ToolArguments` macro in the app target, which this package cannot see —
    /// so the literal is written out here the same way the preamble above is,
    /// character for character with what `AnyLLMTool.toOAICompatJSON` builds
    /// from `CalendarEventsTool` and `RemindersTool`. Renaming a tool or
    /// rewording a description changes the number and this test says by how
    /// much. It cannot notice the macro itself changing shape, which is why the
    /// reconstruction is spelled out rather than hidden behind a constant.
    static let personalDataToolsSchema = #"""
    [{"type":"function","function":{"name":"get_calendar_events","description":"List the user's calendar events (meetings, appointments) for a range of days.","parameters":{"type":"object","properties":{"range":{"type":"string","description":"Which days to list.","enum":["today","tomorrow","this_week","next_week"]}},"required":["range"]}}},{"type":"function","function":{"name":"get_reminders","description":"List the user's reminders (to-dos) that are not completed yet.","parameters":{"type":"object","properties":{"filter":{"type":"string","description":"Which reminders to list.","enum":["overdue","today","tomorrow","this_week","all_open"]}},"required":["filter"]}}}]
    """#

    @Test("the calendar and reminder schemas carry every value the model may send")
    func schemaMatchesTheRangesTheAppAccepts() {
        // The macro writes `CalendarRange.allCases.map { $0.rawValue }` into the
        // schema literally, so the values the model is offered and the values
        // `PersonalDataRange` can resolve are the same list by construction —
        // and this is what keeps the reconstruction above honest about it.
        for range in CalendarRange.allCases {
            #expect(Self.personalDataToolsSchema.contains("\"\(range.rawValue)\""))
        }
        for filter in ReminderFilter.allCases {
            #expect(Self.personalDataToolsSchema.contains("\"\(filter.rawValue)\""))
        }
    }

    @Test("turning the tools off gives the whole preamble back to the conversation")
    func togglingToolsOffRestoresTheBudget() {
        // The engine derives `toolsJSON` from the registered array and hands "" to
        // the guard when that array is empty. Off is therefore not "cheaper", it
        // is free: byte-for-byte the prompt the app sent before it learned about
        // tools.
        let off = ContextGuard(contextTokens: 4096, fixedOverheadTokens:
            ContextGuard.toolOverhead(toolsJSON: "", templateIsToolNative: true))
        let plain = ContextGuard(contextTokens: 4096)
        #expect(off.promptBudget == plain.promptBudget)

        // A tool-native template — Qwen3's, the only catalogue model marked
        // tool-capable — renders the schema itself and is then handed it again
        // by the library, so it pays twice.
        let native = ContextGuard.toolOverhead(toolsJSON: Self.personalDataToolsSchema, templateIsToolNative: true)
        let on = ContextGuard(contextTokens: 4096, fixedOverheadTokens: native)
        #expect(off.promptBudget - on.promptBudget == native)

        // Roughly an eighth of a 4K window, spent on every prompt including the
        // ones that never ask about a calendar. That is the number the Settings
        // footer is describing, and the reason the switch is off by default.
        #expect(native > 500 && native < 600)
        #expect(Double(native) / Double(plain.promptBudget) > 0.12)
    }

    @Test("a short window makes the same tools cost proportionally far more")
    func smallContextsPayMore() {
        // The overhead is fixed while the window is not, so the same two tools
        // take an eighth of a 4K context and better than a quarter of a 2K one.
        let native = ContextGuard.toolOverhead(toolsJSON: Self.personalDataToolsSchema, templateIsToolNative: true)
        let small = ContextGuard(contextTokens: 2048)
        #expect(Double(native) / Double(small.promptBudget) > 0.25)
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
