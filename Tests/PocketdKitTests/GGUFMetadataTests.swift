import Foundation
import Testing
@testable import PocketdKit

/// Builds GGUF headers byte by byte, because the only alternative is a
/// multi-gigabyte fixture.
private struct GGUFBuilder {
    enum Value {
        case string(String)
        case uint32(UInt32)
        case bool(Bool)
        case stringArray([String])
        case uint32Array([UInt32])
    }

    var version: UInt32 = 3
    var pairs: [(String, Value)] = []
    /// Lets a test claim more pairs than it writes, which is what a truncated
    /// download looks like.
    var declaredPairCount: UInt64?

    func build() -> Data {
        var data = Data("GGUF".utf8)
        data += le(version)
        data += le(UInt64(0))                                   // tensor count
        data += le(declaredPairCount ?? UInt64(pairs.count))
        for (key, value) in pairs {
            data += string(key)
            switch value {
            case .string(let text):
                data += le(UInt32(8))
                data += string(text)
            case .uint32(let number):
                data += le(UInt32(4))
                data += le(number)
            case .bool(let flag):
                data += le(UInt32(7))
                data.append(flag ? 1 : 0)
            case .stringArray(let items):
                data += le(UInt32(9))
                data += le(UInt32(8))
                data += le(UInt64(items.count))
                for item in items { data += string(item) }
            case .uint32Array(let items):
                data += le(UInt32(9))
                data += le(UInt32(4))
                data += le(UInt64(items.count))
                for item in items { data += le(item) }
            }
        }
        return data
    }

    private func string(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        return le(UInt64(bytes.count)) + bytes
    }

    private func le(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    private func le(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
}

@Suite("GGUF metadata")
struct GGUFMetadataTests {

    @Test("the chat template comes back out of the header")
    func readsChatTemplate() {
        let template = "{% for message in messages %}{{ message['content'] }}{% endfor %}"
        let file = GGUFBuilder(pairs: [
            ("general.architecture", .string("qwen3")),
            (GGUFMetadata.chatTemplateKey, .string(template))
        ]).build()

        #expect(GGUFMetadata.string(forKey: GGUFMetadata.chatTemplateKey, in: file) == template)
    }

    @Test("keys before the one asked for are skipped whatever their type")
    func skipsEveryValueType() {
        // A real header puts `tokenizer.ggml.tokens` — a hundred thousand
        // strings — and `tokenizer.ggml.token_type` ahead of the template. Get
        // the skip wrong and the reader lands mid-string and returns nonsense
        // rather than failing.
        let file = GGUFBuilder(pairs: [
            ("a.number", .uint32(7)),
            ("a.flag", .bool(true)),
            ("tokenizer.ggml.tokens", .stringArray(["<s>", "</s>", "hello", "world"])),
            ("tokenizer.ggml.token_type", .uint32Array([1, 2, 3, 4, 5, 6])),
            ("a.text", .string("ignored")),
            (GGUFMetadata.chatTemplateKey, .string("found me"))
        ]).build()

        #expect(GGUFMetadata.string(forKey: GGUFMetadata.chatTemplateKey, in: file) == "found me")
    }

    @Test("a header with no template reads as absent, not as an error")
    func missingKey() {
        let file = GGUFBuilder(pairs: [("general.architecture", .string("gemma3"))]).build()
        #expect(GGUFMetadata.string(forKey: GGUFMetadata.chatTemplateKey, in: file) == nil)
    }

    @Test("garbage never traps")
    func refusesGarbage() {
        // The caller is a context-budget estimate. An estimate that crashes the
        // app on a half-downloaded file is worse than one that guesses.
        #expect(GGUFMetadata.string(forKey: "k", in: Data()) == nil)
        #expect(GGUFMetadata.string(forKey: "k", in: Data("not a gguf at all".utf8)) == nil)
        #expect(GGUFMetadata.string(forKey: "k", in: Data(repeating: 0xFF, count: 4096)) == nil)

        var truncated = GGUFBuilder(pairs: [(GGUFMetadata.chatTemplateKey, .string("x"))]).build()
        truncated = truncated.prefix(truncated.count - 1)
        #expect(GGUFMetadata.string(forKey: GGUFMetadata.chatTemplateKey, in: truncated) == nil)

        // A header that promises more pairs than the file holds.
        var lying = GGUFBuilder(pairs: [("a", .string("b"))])
        lying.declaredPairCount = 1 << 40
        #expect(GGUFMetadata.string(forKey: "anything", in: lying.build()) == nil)
    }

    @Test("v1 files are refused rather than misread")
    func refusesVersion1() {
        // v1 counted with 32-bit fields. Parsing one with the v3 layout would
        // read plausible garbage, which is the worst outcome available.
        var old = GGUFBuilder(pairs: [(GGUFMetadata.chatTemplateKey, .string("x"))])
        old.version = 1
        #expect(GGUFMetadata.string(forKey: GGUFMetadata.chatTemplateKey, in: old.build()) == nil)
    }

    @Test("a file that cannot be opened reads as nil")
    func missingFile() {
        let url = URL(fileURLWithPath: "/does/not/exist/model.gguf")
        #expect(GGUFMetadata.chatTemplate(inFileAt: url) == nil)
    }

    @Test("a template on disk survives the round trip")
    func readsFromDisk() throws {
        let template = "{%- if tools %}{{ tools | tojson }}{%- endif %}"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-\(UUID().uuidString).gguf")
        try GGUFBuilder(pairs: [(GGUFMetadata.chatTemplateKey, .string(template))]).build().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(GGUFMetadata.chatTemplate(inFileAt: url) == template)
    }
}

@Suite("Tool-native chat templates")
struct ToolNativeTemplateTests {

    @Test("the test matches the library's, word for word")
    func matchesLibraryHeuristic() {
        // `StandardToolInstructionProcessor.hasNativeToolSupport(in:)` is
        // `template.contains("tools")`. The number this feeds has to predict
        // what that code does, not what a better test would do.
        #expect(ContextGuard.templateIsToolNative("{%- if tools %}{{ tools | tojson }}{%- endif %}"))
        #expect(ContextGuard.templateIsToolNative("{% for message in messages %}{{ message }}{% endfor %}") == false)
        #expect(ContextGuard.templateIsToolNative("") == false)
    }

    @Test("llama.cpp's fallback template is not tool-native")
    func defaultTemplateIsNotNative() {
        // A GGUF with no template of its own gets a Gemma3-shaped default from
        // the library. It mentions no tools, so a model with no template must
        // not be charged the doubled schema — which is why `nil` from the
        // reader has to mean "unreadable", not "absent".
        let fallback = """
        {{ bos_token }} {%- if messages[0]['role'] == 'system' -%} \
        {%- set loop_messages = messages[1:] -%} {%- else -%} \
        {%- set loop_messages = messages -%} {%- endif -%}
        """
        #expect(ContextGuard.templateIsToolNative(fallback) == false)
    }

    @Test("a native template is charged twice for the schema")
    func nativeCostsMore() {
        let schema = String(repeating: "{\"name\":\"calendar_today\"}", count: 8)
        let plain = ContextGuard.toolOverhead(toolsJSON: schema, templateIsToolNative: false)
        let native = ContextGuard.toolOverhead(toolsJSON: schema, templateIsToolNative: true)
        #expect(native > plain)
    }
}
