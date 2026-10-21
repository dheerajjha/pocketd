import Foundation
import Testing
@testable import PocketdKit

/// A message whose estimate is exactly `tokens` guard tokens (including the
/// four the guard charges per message).
private func sized(_ role: ChatMessage.Role, _ tokens: Int, _ tag: String = "") -> ChatMessage {
    let body = max(0, tokens - 4) * ContextGuard.bytesPerToken
    let text = (tag + String(repeating: "x", count: max(0, body - tag.utf8.count)))
    return ChatMessage(role: role, content: text)
}

@Suite("Long conversations never die")
struct ContextTrimTests {

    @Test("a conversation that fits is returned untouched")
    func fits() throws {
        let messages: [ChatMessage] = [.system("Be brief."), .user("hi"), .assistant("hello"), .user("what's on?")]
        #expect(try ContextGuard(contextTokens: 4096).trimmed(messages) == messages)
    }

    @Test("the oldest whole turns go first; the system turn and the question stay")
    func dropsOldestTurns() throws {
        let guardian = ContextGuard(contextTokens: 400, reservedForCompletion: 100)
        // Budget 300. System 40 + question 40 leaves 220: two 100-token turns.
        let messages: [ChatMessage] = [
            sized(.system, 40, "SYS"),
            sized(.user, 50, "U1"), sized(.assistant, 50, "A1"),
            sized(.user, 50, "U2"), sized(.assistant, 50, "A2"),
            sized(.user, 50, "U3"), sized(.assistant, 50, "A3"),
            sized(.user, 40, "Q"),
        ]
        let trimmed = try guardian.trimmed(messages)

        #expect(trimmed.map { String($0.content.prefix(3)) } == ["SYS", "U2x", "A2x", "U3x", "A3x", "Qxx"])
        #expect(guardian.fits(trimmed))
    }

    @Test("a tool call and its result are never separated")
    func toolPairsStayTogether() throws {
        let guardian = ContextGuard(contextTokens: 400, reservedForCompletion: 100)
        let messages: [ChatMessage] = [
            sized(.system, 30, "SYS"),
            sized(.user, 30, "U1"), sized(.assistant, 30, "CALL"), sized(.tool, 120, "RESULT"), sized(.assistant, 30, "A1"),
            sized(.user, 30, "U2"), sized(.assistant, 30, "A2"),
            sized(.user, 30, "Q"),
        ]
        let trimmed = try guardian.trimmed(messages)
        let tags = trimmed.map { String($0.content.prefix(4)) }

        // The 210-token tool turn does not fit beside the rest, so it goes whole.
        #expect(!tags.contains("RESU") && !tags.contains("CALL"))
        #expect(tags == ["SYSx", "U2xx", "A2xx", "Qxxx"])
    }

    @Test("a turn that does not fit stops the walk back; no gap is left in the middle")
    func noGaps() throws {
        let guardian = ContextGuard(contextTokens: 400, reservedForCompletion: 100)
        let messages: [ChatMessage] = [
            sized(.system, 20, "SYS"),
            sized(.user, 20, "OLD"),             // small, old
            sized(.user, 260, "BIG"),            // large, newer
            sized(.user, 30, "NEW"),
            sized(.user, 20, "Q"),
        ]
        let tags = try guardian.trimmed(messages).map { String($0.content.prefix(3)) }
        #expect(tags == ["SYS", "NEW", "Qxx"], "keeping OLD would skip BIG and leave a hole")
    }

    @Test("an assistant greeting before the first question is a turn of its own")
    func leadingGreeting() {
        let turns = ContextGuard.turns(in: [.assistant("Hi, I'm Pocketd."), .user("hi"), .assistant("hello")])
        #expect(turns.count == 2)
        #expect(turns[0] == [.assistant("Hi, I'm Pocketd.")])
    }

    @Test("a single message too long to read still says so")
    func hopeless() {
        let guardian = ContextGuard(contextTokens: 400, reservedForCompletion: 100)
        #expect(throws: InferenceError.contextExhausted) {
            try guardian.trimmed([.system("Be brief."), sized(.user, 1_000, "HUGE")])
        }
        #expect(throws: InferenceError.contextExhausted) {
            try guardian.trimmed([sized(.system, 1_000, "SYS")])
        }
    }

    @Test("a long chat keeps working turn after turn")
    func neverDies() throws {
        let guardian = ContextGuard(contextTokens: 4096, reservedForCompletion: 512, fixedOverheadTokens: 900)
        var history: [ChatMessage] = [.system(String(repeating: "Today is Wednesday. ", count: 20))]
        for turn in 1...200 {
            history.append(.user("Question \(turn): what is on my calendar this afternoon, and is anything overdue?"))
            let sent = try guardian.trimmed(history)
            #expect(guardian.fits(sent))
            #expect(sent.first?.role == .system)
            #expect(sent.last == history.last)
            history.append(.assistant(String(repeating: "You have a meeting at three and one reminder is overdue. ", count: 3)))
        }
    }

    @Test("reply room: what was asked, up to a quarter of the window, never below the guard's own")
    func replyReserve() {
        #expect(ContextGuard.replyReserve(contextTokens: 4096, requestedMaxTokens: 160) == 160)
        #expect(ContextGuard.replyReserve(contextTokens: 4096, requestedMaxTokens: 4096) == 1024)
        #expect(ContextGuard.replyReserve(contextTokens: 4096, requestedMaxTokens: nil) == 512)
        #expect(ContextGuard.replyReserve(contextTokens: 4096, requestedMaxTokens: 8) == 64)
        #expect(ContextGuard.replyReserve(contextTokens: 128, requestedMaxTokens: nil) == 32)
    }
}

@Suite("Engine errors in plain words")
struct InferenceErrorWordsTests {

    @Test("every failure is one short sentence with no machinery in it", arguments: [
        InferenceError.noModelLoaded, .modelNotFound("qwen3-1.7b"),
        .modelMismatch(requested: "a", loaded: "b"), .contextExhausted, .cancelled,
        .backend("llama_decode returned 2"),
    ])
    func plain(error: InferenceError) throws {
        let sentence = try #require(error.errorDescription)
        #expect(sentence.split(separator: " ").count <= 25)
        for jargon in ["model", "context", "token", "backend", "llama", "qwen", "decode", "`"] {
            #expect(!sentence.lowercased().contains(jargon), "\(jargon) in \(sentence)")
        }
        #expect((error as any Error).localizedDescription == sentence, "what the app reads is this sentence")
    }

    @Test("a conversation that got too long says how to keep going")
    func tooLong() {
        #expect(InferenceError.contextExhausted.errorDescription == "This conversation got too long. Start a new chat to keep going.")
        #expect(InferenceError.contextExhausted.suggestsNewConversation)
        #expect(!InferenceError.backend("x").suggestsNewConversation)
    }

    @Test("the engine's own words survive for the log and for other devices")
    func detail() {
        #expect(InferenceError.backend("batch decode failed").detail == "batch decode failed")
        #expect(InferenceError.modelNotFound("qwen3-1.7b").detail.contains("qwen3-1.7b"))
    }
}
