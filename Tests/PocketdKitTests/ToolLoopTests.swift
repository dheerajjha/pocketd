import Foundation
import Testing
@testable import PocketdKit

/// The engine runs tools itself and re-prompts the model with their output, so
/// what the model reads is a string this package produced. These are the parts
/// of that string that are not allowed to drift.
@Suite("Tool results")
struct ToolResultTests {

    @Test("the same output renders identically every time")
    func deterministic() {
        // Not a tautology: `ToolOutput.data` is a Dictionary, whose iteration
        // order changes with the per-process hash seed, and the library's own
        // automatic path formats results by iterating it. Two runs of the same
        // tool would send two different prompts, so the same question would
        // sample differently and no report of a bad answer could be reproduced.
        let output: [String: any Sendable] = [
            "zulu": 1, "alpha": "a", "mike": true, "kilo": 2.5, "bravo": ["x", "y"]
        ]
        let rendered = (0..<20).map { _ in ToolResult.encode(output) }
        #expect(Set(rendered).count == 1)
        #expect(rendered[0] == #"{"alpha":"a","bravo":["x","y"],"kilo":2.5,"mike":true,"zulu":1}"#)
    }

    @Test("nested objects are sorted too")
    func sortsNested() {
        let rendered = ToolResult.encode(["outer": ["zed": 1, "amy": 2] as [String: any Sendable]])
        #expect(rendered == #"{"outer":{"amy":2,"zed":1}}"#)
    }

    @Test("a value JSON cannot carry still produces a stable result")
    func fallbackIsStable() {
        // A tool that hands back a Date or a URL is a bug, but it must be a bug
        // that produces an answer rather than a dead stream.
        let output: [String: any Sendable] = ["when": Date(timeIntervalSince1970: 0), "what": "x"]
        let first = ToolResult.encode(output)
        #expect(first == ToolResult.encode(output))
        #expect(first.hasPrefix("what: x, when: ") || first.hasPrefix("when: "))
        #expect(!first.isEmpty)
    }

    @Test("a failure is JSON of the same shape as a success")
    func failureIsJSON() {
        // The chat template renders one kind of thing. A bare sentence where
        // JSON was expected is how a model ends up quoting an error message as
        // though it were the answer.
        let unknown = ToolResult.unknownTool(named: "get_weather")
        #expect(unknown.hasPrefix("{") && unknown.hasSuffix("}"))
        let decoded = (try? JSONSerialization.jsonObject(with: Data(unknown.utf8))) as? [String: Any]
        #expect(decoded?["error"] != nil)
        #expect(unknown.contains("get_weather"))
    }

    @Test("recovery lines are short enough to spend on a context window")
    func recoveryIsShort() {
        #expect(ToolResult.unknownTool(named: "reminders_list").count < 120)
        #expect(ToolResult.failed(tool: "reminders_list").count < 120)
    }

    @Test("a failure tells the model what to do next, not what went wrong")
    func recoveryIsActionable() {
        // The model repeats what it reads. "Answer without it" is an
        // instruction it can follow; a Swift DecodingError is not.
        #expect(ToolResult.failed(tool: "calendar_today").contains("Answer without it"))
        #expect(ToolResult.unknownTool(named: "nope").contains("Answer without it"))
    }
}

/// A tool round costs two full prefills, which the user experiences as silence.
/// The engine announces it so a UI can say so; no wire protocol may leak it.
@Suite("Tool call announcements")
struct ToolCallAnnouncementTests {

    @Test("the announcement never reaches an OpenAI stream")
    func absentFromOpenAIStream() async throws {
        let harness = try await TestServer.start(
            engine: EchoEngine(chunkSize: 64, announcesToolCall: "calendar_today")
        )
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "what is on today")],
                stream: true
            )
        ))

        #expect(status == 200)
        let body = String(decoding: data, as: UTF8.self)
        // `tool_calls` in an OpenAI delta means "client, run this and send the
        // result back". The tool already ran here, so saying it would ask for
        // work the client has no tool to do.
        #expect(!body.contains("calendar_today"))
        #expect(!body.contains("tool_call"))
        #expect(body.contains("what is on today"))
        #expect(body.contains("[DONE]"))
    }

    @Test("nor an Ollama stream")
    func absentFromOllamaStream() async throws {
        let harness = try await TestServer.start(
            engine: EchoEngine(chunkSize: 64, announcesToolCall: "calendar_today")
        )
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(try harness.request("POST", "/api/chat", json:
            Ollama.ChatRequest(
                model: "echo",
                messages: [Ollama.Message(role: "user", content: "what is on today")]
            )
        ))

        #expect(status == 200)
        let body = String(decoding: data, as: UTF8.self)
        #expect(!body.contains("calendar_today"))
        #expect(body.contains("what is on today"))
    }

    @Test("a buffered response is unaffected by it")
    func absentFromBufferedResponse() async throws {
        let harness = try await TestServer.start(
            engine: EchoEngine(chunkSize: 64, announcesToolCall: "calendar_today")
        )
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.send(try harness.request("POST", "/v1/chat/completions", json:
            OpenAI.ChatCompletionRequest(
                model: "echo",
                messages: [OpenAI.Message(role: "user", content: "hello")],
                stream: false
            )
        ))

        #expect(status == 200)
        let body = try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: data)
        #expect(body.choices.first?.message.content?.text == "hello")
        #expect(body.choices.first?.finish_reason == "stop")
    }
}
