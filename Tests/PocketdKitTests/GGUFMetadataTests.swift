import Foundation
import Testing
@testable import PocketdKit

/// Builds GGUF headers byte by byte, because the only alternative is a
/// multi-gigabyte fixture.
///
/// Internal rather than private: the memory estimate is tested against headers
/// too, and a second builder would be a second set of assumptions about the
/// format for a reader bug to hide behind.
struct GGUFBuilder {
    enum Value {
        case string(String)
        case uint8(UInt8)
        case int8(Int8)
        case uint16(UInt16)
        case int16(Int16)
        case uint32(UInt32)
        case int32(Int32)
        case uint64(UInt64)
        case int64(Int64)
        case float32(Float)
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
            case .uint8(let number):
                data += le(UInt32(0))
                data.append(number)
            case .int8(let number):
                data += le(UInt32(1))
                data.append(UInt8(bitPattern: number))
            case .uint16(let number):
                data += le(UInt32(2))
                data += le(number)
            case .int16(let number):
                data += le(UInt32(3))
                data += le(UInt16(bitPattern: number))
            case .uint32(let number):
                data += le(UInt32(4))
                data += le(number)
            case .int32(let number):
                data += le(UInt32(5))
                data += le(UInt32(bitPattern: number))
            case .uint64(let number):
                data += le(UInt32(10))
                data += le(number)
            case .int64(let number):
                data += le(UInt32(11))
                data += le(UInt64(bitPattern: number))
            case .float32(let number):
                data += le(UInt32(6))
                data += le(number.bitPattern)
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

    private func le(_ value: UInt16) -> Data {
        Data((0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
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

@Suite("GGUF integers")
struct GGUFIntegerTests {

    @Test("every integer width comes back widened to Int64")
    func readsEveryIntegerWidth() {
        // GGUF has eight integer types and the spec does not say which key uses
        // which. `block_count` is uint32 in llama.cpp's own converter and there
        // is nothing stopping another tool writing it as uint64 — a reader that
        // handles one width reports a perfectly good model as unreadable
        // because of the program that packaged it.
        let file = GGUFBuilder(pairs: [
            ("n.u8", .uint8(200)),
            ("n.i8", .int8(-5)),
            ("n.u16", .uint16(60_000)),
            ("n.i16", .int16(-300)),
            ("n.u32", .uint32(4_000_000_000)),
            ("n.i32", .int32(-70_000)),
            ("n.u64", .uint64(1 << 40)),
            ("n.i64", .int64(-(1 << 40)))
        ]).build()

        #expect(GGUFMetadata.integer(forKey: "n.u8", in: file) == 200)
        #expect(GGUFMetadata.integer(forKey: "n.i8", in: file) == -5)
        #expect(GGUFMetadata.integer(forKey: "n.u16", in: file) == 60_000)
        #expect(GGUFMetadata.integer(forKey: "n.i16", in: file) == -300)
        #expect(GGUFMetadata.integer(forKey: "n.u32", in: file) == 4_000_000_000)
        #expect(GGUFMetadata.integer(forKey: "n.i32", in: file) == -70_000)
        #expect(GGUFMetadata.integer(forKey: "n.u64", in: file) == 1 << 40)
        #expect(GGUFMetadata.integer(forKey: "n.i64", in: file) == -(1 << 40))
    }

    @Test("a key that is not an integer reads as absent rather than as zero")
    func refusesNonIntegers() {
        let file = GGUFBuilder(pairs: [
            ("a.text", .string("28")),
            ("a.flag", .bool(true)),
            ("a.ratio", .float32(1.5))
        ]).build()

        // Zero would be the dangerous answer: a KV cache priced at zero bytes
        // fits on any device.
        #expect(GGUFMetadata.integer(forKey: "a.text", in: file) == nil)
        #expect(GGUFMetadata.integer(forKey: "a.flag", in: file) == nil)
        #expect(GGUFMetadata.integer(forKey: "a.ratio", in: file) == nil)
        #expect(GGUFMetadata.integer(forKey: "a.missing", in: file) == nil)
    }

    @Test("several keys come out of one pass, wherever they sit in the header")
    func readsManyKeysInOnePass() {
        let file = GGUFBuilder(pairs: [
            ("general.architecture", .string("llama")),
            ("tokenizer.ggml.tokens", .stringArray(["<s>", "a", "b"])),
            ("llama.block_count", .uint32(16)),
            ("tokenizer.ggml.token_type", .uint32Array([1, 2, 3])),
            ("llama.embedding_length", .uint32(2048))
        ]).build()

        let values = GGUFMetadata.values(
            forKeys: ["general.architecture", "llama.block_count", "llama.embedding_length", "tokenizer.ggml.tokens"],
            in: file
        )

        #expect(values?["general.architecture"] == .string("llama"))
        #expect(values?["llama.block_count"] == .integer(16))
        #expect(values?["llama.embedding_length"] == .integer(2048))
        // The vocabulary comes back as a count. Building the strings to learn
        // the number is how a memory estimate causes a memory problem.
        #expect(values?["tokenizer.ggml.tokens"] == .arrayCount(3))
    }

    @Test("a corrupt header reads as nil, not as an empty result")
    func distinguishesCorruptFromAbsent() {
        // These are different answers: nothing found means the model does not
        // declare the key, and nil means nothing in this file can be trusted.
        let good = GGUFBuilder(pairs: [("a", .string("b"))]).build()
        #expect(GGUFMetadata.values(forKeys: ["absent"], in: good)?.isEmpty == true)
        #expect(GGUFMetadata.values(forKeys: ["absent"], in: Data("GGUF".utf8)) == nil)
    }
}

@Suite("GGUF model dimensions")
struct GGUFModelDimensionsTests {

    /// A header shaped like the ones llama.cpp's converter writes: the
    /// architecture first, because every other key is named after its value,
    /// then the vocabulary — which every later key costs a walk past.
    static func header(
        architecture: String = "qwen3",
        vocabularyTokens: Int = 8_000,
        keys: [(String, GGUFBuilder.Value)]
    ) -> Data {
        var pairs: [(String, GGUFBuilder.Value)] = [
            (GGUFMetadata.architectureKey, .string(architecture)),
            ("general.name", .string("fixture"))
        ]
        pairs.append((GGUFMetadata.tokensKey, .stringArray((0..<vocabularyTokens).map { "t\($0)" })))
        pairs.append(("tokenizer.ggml.token_type", .uint32Array(Array(repeating: 1, count: vocabularyTokens))))
        pairs += keys.map { ("\(architecture)\($0.0)", $0.1) }
        return GGUFBuilder(pairs: pairs).build()
    }

    /// Qwen3 1.7B's real shape.
    static let qwen3Keys: [(String, GGUFBuilder.Value)] = [
        (".block_count", .uint32(28)),
        (".context_length", .uint32(32_768)),
        (".embedding_length", .uint32(2048)),
        (".attention.head_count", .uint32(16)),
        (".attention.head_count_kv", .uint32(8)),
        (".attention.key_length", .uint32(128)),
        (".attention.value_length", .uint32(128)),
        (".vocab_size", .uint32(151_936))
    ]

    @Test("a model's shape comes out of its header")
    func readsDimensions() throws {
        let dimensions = try #require(GGUFModelDimensions.read(in: Self.header(keys: Self.qwen3Keys)))

        #expect(dimensions.architecture == "qwen3")
        #expect(dimensions.blockCount == 28)
        #expect(dimensions.embeddingLength == 2048)
        #expect(dimensions.headCount == 16)
        #expect(dimensions.headCountKV == 8)
        #expect(dimensions.keyLength == 128)
        #expect(dimensions.valueLength == 128)
        #expect(dimensions.vocabularySize == 151_936)
        #expect(dimensions.trainedContextLength == 32_768)
        #expect(dimensions.slidingWindow == nil)
        #expect(dimensions.isValid)
    }

    @Test("head widths fall back to n_embd / n_head when the model omits them")
    func derivesHeadWidths() throws {
        // Most llama-family GGUFs carry neither key; llama.cpp derives both,
        // and a reader that treats them as required declares half the
        // catalogue unmeasurable.
        let keys = Self.qwen3Keys.filter { $0.0 != ".attention.key_length" && $0.0 != ".attention.value_length" }
        let dimensions = try #require(GGUFModelDimensions.read(in: Self.header(keys: keys)))

        #expect(dimensions.keyLength == 2048 / 16)
        #expect(dimensions.valueLength == 2048 / 16)
    }

    @Test("a model with no grouped-query key is charged for full attention")
    func defaultsHeadCountKV() throws {
        let keys = Self.qwen3Keys.filter { $0.0 != ".attention.head_count_kv" }
        let dimensions = try #require(GGUFModelDimensions.read(in: Self.header(keys: keys)))

        // Pre-GQA models simply do not write the key. Reading that as zero
        // prices their cache at nothing, which is the failure mode that has to
        // be impossible.
        #expect(dimensions.headCountKV == 16)
    }

    @Test("the vocabulary is counted rather than built")
    func countsVocabularyWithoutMaterialisingIt() throws {
        let keys = Self.qwen3Keys.filter { $0.0 != ".vocab_size" }
        let dimensions = try #require(
            GGUFModelDimensions.read(in: Self.header(vocabularyTokens: 8_000, keys: keys))
        )

        #expect(dimensions.vocabularySize == 8_000)
    }

    @Test("a declared vocabulary size wins over the token array")
    func prefersDeclaredVocabulary() throws {
        let dimensions = try #require(
            GGUFModelDimensions.read(in: Self.header(vocabularyTokens: 8_000, keys: Self.qwen3Keys))
        )

        // The array is padded with tokens the model does not score, so the
        // declared number is the one llama.cpp allocates logits for.
        #expect(dimensions.vocabularySize == 151_936)
    }

    @Test("a sliding window is picked up where the model declares one")
    func readsSlidingWindow() throws {
        let keys = Self.qwen3Keys + [(".attention.sliding_window", .uint32(4096))]
        let dimensions = try #require(
            GGUFModelDimensions.read(in: Self.header(architecture: "gemma3", keys: keys))
        )

        #expect(dimensions.architecture == "gemma3")
        #expect(dimensions.slidingWindow == 4096)
    }

    @Test("keys belonging to another architecture are not borrowed")
    func ignoresForeignArchitectureKeys() {
        // The pass collects by suffix, because the prefix is not known until
        // the architecture has been read. Resolution is still by exact name:
        // reading `llama.block_count` into a qwen3 model would be a plausible
        // number attached to the wrong weights.
        let keys = Self.qwen3Keys.map { ("llama\($0.0)", $0.1) }
        var pairs: [(String, GGUFBuilder.Value)] = [(GGUFMetadata.architectureKey, .string("qwen3"))]
        pairs += keys
        #expect(GGUFModelDimensions.read(in: GGUFBuilder(pairs: pairs).build()) == nil)
    }

    @Test("a truncated or corrupt file reads as nil rather than as a shape")
    func refusesCorruptFiles() {
        // A wrong shape is worse than no shape: it produces a confident number
        // and a jetsam kill, where nil produces a hedge and a flat guess.
        var truncated = Self.header(keys: Self.qwen3Keys)
        truncated = truncated.prefix(truncated.count / 2)
        #expect(GGUFModelDimensions.read(in: truncated) == nil)

        #expect(GGUFModelDimensions.read(in: Data()) == nil)
        #expect(GGUFModelDimensions.read(in: Data(repeating: 0xFF, count: 8192)) == nil)

        // A header with an architecture and nothing else is a real file — an
        // mmproj projector has exactly this shape — and it is still unusable
        // for an estimate.
        #expect(GGUFModelDimensions.read(in: Self.header(keys: [])) == nil)
    }

    @Test("dimensions that cannot be true are refused")
    func validatesDimensions() {
        // A field of zero multiplies the KV cache to nothing and reports that
        // every model fits. It has to be caught here, not believed and divided
        // by later.
        for zeroed in [".block_count", ".embedding_length", ".attention.head_count", ".attention.head_count_kv"] {
            let keys = Self.qwen3Keys.map { $0.0 == zeroed ? ($0.0, GGUFBuilder.Value.uint32(0)) : $0 }
            #expect(GGUFModelDimensions.read(in: Self.header(keys: keys)) == nil, "\(zeroed) of zero was believed")
        }

        // Signed keys written negative by a broken converter.
        let negative = Self.qwen3Keys.map { $0.0 == ".block_count" ? ($0.0, GGUFBuilder.Value.int32(-28)) : $0 }
        #expect(GGUFModelDimensions.read(in: Self.header(keys: negative)) == nil)

        // And a value that parses but describes no model anyone has trained.
        let absurd = Self.qwen3Keys.map { $0.0 == ".block_count" ? ($0.0, GGUFBuilder.Value.uint64(1 << 40)) : $0 }
        #expect(GGUFModelDimensions.read(in: Self.header(keys: absurd)) == nil)
    }

    @Test("a header on disk survives the round trip")
    func readsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-\(UUID().uuidString).gguf")
        try Self.header(keys: Self.qwen3Keys).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(GGUFModelDimensions.read(fromFileAt: url)?.blockCount == 28)
        #expect(GGUFModelDimensions.read(fromFileAt: URL(fileURLWithPath: "/does/not/exist.gguf")) == nil)
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
