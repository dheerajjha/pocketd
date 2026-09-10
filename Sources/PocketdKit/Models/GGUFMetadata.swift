import Foundation

/// Reads values out of a GGUF file's metadata header.
///
/// This began for exactly one question: does this model's chat template render
/// tool schemas itself? LocalLLMClient answers it from
/// `llama_model_meta_val_str(model, "tokenizer.chat_template", …)` and then
/// `template.contains("tools")`, but it keeps both the `Model` and the
/// `Context` internal, and `LlamaClient._context` exists only in the library's
/// own DEBUG builds. There is no public accessor. Loading a second copy of the
/// weights to ask llama.cpp would cost gigabytes, so the header is parsed here
/// instead — the file is memory-mapped and only the pages the header occupies
/// are ever touched.
///
/// It now answers a second, more dangerous one: how big is this model's KV
/// cache going to be? That needs a handful of integers rather than one string,
/// which is why `values(forKeys:in:)` exists — see `GGUFModelDimensions`.
///
/// Deliberately total: every malformed, truncated or unexpected input returns
/// `nil` rather than trapping. The caller is a context-budget estimate, and an
/// estimate that crashes the app is worse than one that guesses.
public enum GGUFMetadata {

    /// llama.cpp's `LLM_KV_TOKENIZER_CHAT_TEMPLATE`.
    public static let chatTemplateKey = "tokenizer.chat_template"

    /// llama.cpp's `LLM_KV_GENERAL_ARCHITECTURE`. Every key that describes the
    /// model's shape is prefixed with this key's *value* — `llama.block_count`,
    /// `qwen3.block_count`, `gemma3.block_count` — so nothing else can be
    /// looked up until this one has been read.
    public static let architectureKey = "general.architecture"

    /// One string per vocabulary entry. The only thing anyone here wants from
    /// it is how many there are, which is why `Value` carries an array's length
    /// and not its contents: a quarter of a million Swift `String`s built to
    /// learn a single number is how a memory estimate causes the memory
    /// problem it exists to prevent.
    public static let tokensKey = "tokenizer.ggml.tokens"

    /// A metadata value, reduced to the shapes this app has a use for.
    public enum Value: Sendable, Equatable {
        case string(String)
        /// Any of GGUF's eight integer widths, widened. The spec does not fix
        /// which key is stored at which width, so a reader that insists on
        /// uint32 declares a model unreadable because of how it was converted.
        case integer(Int64)
        case boolean(Bool)
        case float(Double)
        /// How many elements the array held. Its contents were skipped.
        case arrayCount(Int)
    }

    /// The Jinja chat template baked into a GGUF, or `nil` if it has none or
    /// the file cannot be read.
    ///
    /// Note that `nil` is not the same as "not tool-native": a model with no
    /// template at all gets llama.cpp's Gemma3-shaped default, which mentions
    /// no tools. Callers that need to distinguish "absent" from "unreadable"
    /// cannot, and should assume the more expensive answer.
    public static func chatTemplate(inFileAt url: URL) -> String? {
        string(forKey: chatTemplateKey, inFileAt: url)
    }

    public static func string(forKey key: String, inFileAt url: URL) -> String? {
        guard let data = map(url) else { return nil }
        return string(forKey: key, in: data)
    }

    /// A key holding no value, or a value that is not a string, reads as `nil`.
    static func string(forKey key: String, in data: Data) -> String? {
        guard case .string(let text)? = values(forKeys: [key], in: data)?[key] else { return nil }
        return text
    }

    /// An integer value, whatever width the file stored it in.
    public static func integer(forKey key: String, inFileAt url: URL) -> Int64? {
        guard let data = map(url) else { return nil }
        return integer(forKey: key, in: data)
    }

    static func integer(forKey key: String, in data: Data) -> Int64? {
        guard case .integer(let number)? = values(forKeys: [key], in: data)?[key] else { return nil }
        return number
    }

    /// Reads several keys in a single traversal of the header.
    ///
    /// One pass, not one per key: the header is the front of a mapped file that
    /// is measured in gigabytes, and every key after `tokenizer.ggml.tokens`
    /// costs a walk over a quarter of a million string lengths to reach. Six
    /// separate lookups for six dimensions is six of those walks.
    ///
    /// `nil` means the header is not one this reader will trust — bad magic, a
    /// version it does not parse, or a structure that stopped making sense part
    /// way through. An empty dictionary means the header was fine and held none
    /// of the keys asked for. The difference matters: the first is a reason to
    /// fall back to a guess, the second is a reason to believe the model simply
    /// does not declare them.
    public static func values(forKeys keys: Set<String>, inFileAt url: URL) -> [String: Value]? {
        values(forKeys: keys, endingIn: [], inFileAt: url)
    }

    static func values(
        forKeys keys: Set<String>,
        endingIn suffixes: Set<String>,
        inFileAt url: URL
    ) -> [String: Value]? {
        guard let data = map(url) else { return nil }
        return values(forKeys: keys, endingIn: suffixes, in: data)
    }

    /// - Parameter suffixes: keys whose full name is not known in advance —
    ///   everything under the architecture prefix, which is itself one of the
    ///   values being read. Collecting by suffix keeps that to one pass instead
    ///   of one pass to learn the architecture and a second to use it.
    static func values(
        forKeys keys: Set<String>,
        endingIn suffixes: Set<String> = [],
        in data: Data
    ) -> [String: Value]? {
        var reader = Reader(data)

        guard reader.bytes(4).map({ Array($0) }) == Array("GGUF".utf8),
              let version = reader.u32(),
              // v1 counted with 32-bit fields. Nothing has written one since
              // 2023 and llama.cpp itself no longer reads them, so rather than
              // carry a second layout, say so by refusing.
              version == 2 || version == 3,
              reader.u64() != nil,                 // tensor count, unused here
              let pairs = reader.u64(),
              pairs <= UInt64(reader.remaining),   // every pair is at least a byte
              pairs <= Limits.keyValuePairs
        else { return nil }

        var found: [String: Value] = [:]
        for _ in 0..<pairs {
            guard let name = reader.string(maxLength: Limits.keyLength), let type = reader.u32() else { return nil }

            let wanted = keys.contains(name) || suffixes.contains(where: name.hasSuffix)
            // First occurrence wins, and a header that repeats a key thousands
            // of times cannot make this dictionary grow without bound.
            if wanted, found[name] == nil, found.count < Limits.capturedValues {
                guard let value = reader.value(ofType: type) else { return nil }
                found[name] = value
            } else {
                guard reader.skipValue(ofType: type) else { return nil }
            }

            // Only sound when every key was named outright: a suffix match
            // cannot know it has seen the last one.
            if suffixes.isEmpty, found.count == keys.count { break }
        }
        return found
    }

    /// Mapped, not read: a GGUF is measured in gigabytes and the header is the
    /// first few hundred kilobytes of it.
    private static func map(_ url: URL) -> Data? {
        try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// Bounds a corrupt or hostile header cannot talk this reader past.
    ///
    /// None of them is close to what a real file contains — a GGUF header has
    /// tens of pairs, keys are a few dozen characters, and the longest array in
    /// one is the vocabulary at a quarter of a million entries. They exist so
    /// that a file whose length fields are garbage costs a bail-out rather than
    /// a long walk or an allocation.
    private enum Limits {
        static let keyValuePairs: UInt64 = 1 << 16
        static let keyLength = 1024
        static let arrayElements: UInt64 = 1 << 22
        static let capturedValues = 64
    }

    /// The GGUF metadata value type tags, in the order the spec defines them.
    private enum ValueType {
        static let uint8: UInt32 = 0, int8: UInt32 = 1
        static let uint16: UInt32 = 2, int16: UInt32 = 3
        static let uint32: UInt32 = 4, int32: UInt32 = 5, float32: UInt32 = 6
        static let bool: UInt32 = 7
        static let string: UInt32 = 8
        static let array: UInt32 = 9
        static let uint64: UInt32 = 10, int64: UInt32 = 11, float64: UInt32 = 12

        /// Bytes on the wire for the types that have a fixed size, so a long
        /// array of them can be skipped in one jump rather than element by
        /// element — `tokenizer.ggml.token_type` is one entry per vocabulary
        /// token, and there are a hundred thousand of those.
        static func width(of type: UInt32) -> Int? {
            switch type {
            case uint8, int8, bool: 1
            case uint16, int16: 2
            case uint32, int32, float32: 4
            case uint64, int64, float64: 8
            default: nil
            }
        }
    }

    /// A bounds-checked cursor. Every read either advances and returns a value
    /// or returns `nil` and leaves the caller to give up; nothing here can run
    /// off the end of the mapping.
    private struct Reader {
        private let data: Data
        private var offset = 0

        init(_ data: Data) { self.data = data }

        var remaining: Int { data.count - offset }

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, count <= remaining else { return nil }
            let start = data.startIndex + offset
            defer { offset += count }
            return data[start..<(start + count)]
        }

        mutating func u8() -> UInt8? {
            guard let raw = bytes(1) else { return nil }
            return raw[raw.startIndex]
        }

        mutating func u16() -> UInt16? {
            guard let raw = bytes(2) else { return nil }
            return raw.enumerated().reduce(UInt16(0)) { $0 | UInt16($1.element) << (8 * $1.offset) }
        }

        mutating func u32() -> UInt32? {
            guard let raw = bytes(4) else { return nil }
            return raw.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }

        mutating func u64() -> UInt64? {
            guard let raw = bytes(8) else { return nil }
            return raw.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }

        /// GGUF strings are a 64-bit length and that many UTF-8 bytes, with no
        /// terminator. Invalid UTF-8 is repaired rather than rejected: this is
        /// only ever fed to `contains`.
        mutating func string(maxLength: Int = .max) -> String? {
            guard let raw = stringBytes(maxLength: maxLength) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }

        mutating func stringBytes(maxLength: Int = .max) -> Data? {
            // The length check is against what is left of the file, so a corrupt
            // length cannot ask for a gigabyte allocation.
            guard let length = u64(), length <= UInt64(remaining), length <= UInt64(maxLength) else { return nil }
            return bytes(Int(length))
        }

        /// Reads one value, as opposed to stepping over it.
        mutating func value(ofType type: UInt32) -> Value? {
            switch type {
            case ValueType.uint8: u8().map { .integer(Int64($0)) }
            case ValueType.int8: u8().map { .integer(Int64(Int8(bitPattern: $0))) }
            case ValueType.uint16: u16().map { .integer(Int64($0)) }
            case ValueType.int16: u16().map { .integer(Int64(Int16(bitPattern: $0))) }
            case ValueType.uint32: u32().map { .integer(Int64($0)) }
            case ValueType.int32: u32().map { .integer(Int64(Int32(bitPattern: $0))) }
            // A uint64 past Int64.max is not a layer count or a vocabulary
            // size; it is a corrupt field, and widening it by wrapping would
            // hand the estimate a negative number to multiply.
            case ValueType.uint64: u64().flatMap { Int64(exactly: $0) }.map { .integer($0) }
            case ValueType.int64: u64().map { .integer(Int64(bitPattern: $0)) }
            case ValueType.float32: u32().map { .float(Double(Float(bitPattern: $0))) }
            case ValueType.float64: u64().map { .float(Double(bitPattern: $0)) }
            case ValueType.bool: u8().map { .boolean($0 != 0) }
            case ValueType.string: string().map { .string($0) }
            case ValueType.array: arrayCount()
            default: nil
            }
        }

        /// The length of an array, with the elements stepped over rather than
        /// built. Vocabularies are read this way and only this way.
        mutating func arrayCount() -> Value? {
            guard let element = u32(), let count = u64(), count <= UInt64(remaining), count <= Limits.arrayElements else {
                return nil
            }
            guard skipElements(count: count, ofType: element) else { return nil }
            return .arrayCount(Int(count))
        }

        mutating func skipValue(ofType type: UInt32) -> Bool {
            if let width = ValueType.width(of: type) {
                return bytes(width) != nil
            }
            switch type {
            case ValueType.string:
                return stringBytes() != nil
            case ValueType.array:
                guard let element = u32(), let count = u64(),
                      count <= UInt64(remaining), count <= Limits.arrayElements
                else { return false }
                return skipElements(count: count, ofType: element)
            default:
                return false
            }
        }

        private mutating func skipElements(count: UInt64, ofType element: UInt32) -> Bool {
            if let width = ValueType.width(of: element) {
                return bytes(Int(count) * width) != nil
            }
            // Nested arrays are legal in the spec and emitted by nothing;
            // rather than guess at a layout that has never been seen, fail
            // and let the caller fall back.
            guard element == ValueType.string else { return false }
            for _ in 0..<count {
                guard stringBytes() != nil else { return false }
            }
            return true
        }
    }
}

/// The shape of a model, read out of its own GGUF header: every number the KV
/// cache size depends on.
///
/// Persisted alongside the `ModelRecord` because reading it means mapping a
/// multi-gigabyte file, and the fit badge is drawn on every scroll. Persisted
/// data is not trusted data, though — see `isValid`.
public struct GGUFModelDimensions: Sendable, Codable, Equatable, Hashable {
    /// `general.architecture`: `llama`, `qwen3`, `gemma3`. Kept because it is
    /// what every other key here was read under, so a record whose dimensions
    /// look wrong can be traced back to the file that produced them.
    public var architecture: String
    /// `{arch}.block_count` — n_layers. The KV cache holds one entry per layer.
    public var blockCount: Int
    /// `{arch}.embedding_length` — n_embd.
    public var embeddingLength: Int
    /// `{arch}.attention.head_count` — n_head.
    public var headCount: Int
    /// `{arch}.attention.head_count_kv` — n_head_kv, and the reason grouped-query
    /// models fit on a phone at all: it is n_head on an old MHA model and as
    /// little as an eighth of it on a modern one, and the cache scales with it.
    public var headCountKV: Int
    /// `{arch}.attention.key_length` — n_embd_head_k.
    public var keyLength: Int
    /// `{arch}.attention.value_length` — n_embd_head_v. Not always equal to the
    /// key length: DeepSeek-style models compress one and not the other.
    public var valueLength: Int
    /// `{arch}.vocab_size`, or the length of `tokenizer.ggml.tokens` when the
    /// model does not declare it. Feeds the compute buffer, where it dominates
    /// — the logits row is one float per vocabulary entry per batched token.
    public var vocabularySize: Int
    /// `{arch}.context_length`: the window the weights were trained for. A
    /// second opinion on `ModelRecord.contextLength`, which is hand-written in
    /// the catalogue and has been wrong before.
    public var trainedContextLength: Int?
    /// `{arch}.attention.sliding_window`, on the models that have one. Gemma
    /// attends to a fixed window rather than the whole context, so its cache
    /// stops growing at the window and a 32K context costs it nothing extra.
    public var slidingWindow: Int?

    public init(
        architecture: String,
        blockCount: Int,
        embeddingLength: Int,
        headCount: Int,
        headCountKV: Int,
        keyLength: Int,
        valueLength: Int,
        vocabularySize: Int,
        trainedContextLength: Int? = nil,
        slidingWindow: Int? = nil
    ) {
        self.architecture = architecture
        self.blockCount = blockCount
        self.embeddingLength = embeddingLength
        self.headCount = headCount
        self.headCountKV = headCountKV
        self.keyLength = keyLength
        self.valueLength = valueLength
        self.vocabularySize = vocabularySize
        self.trainedContextLength = trainedContextLength
        self.slidingWindow = slidingWindow
    }

    /// Whether these numbers may be multiplied together and believed.
    ///
    /// Two failures this catches. Zero or negative in any field is a parse that
    /// went wrong or a manifest written by a build whose reader had a bug, and
    /// it produces a KV cache of zero bytes — an estimate that says "Fits" for
    /// everything, which is the exact failure this whole type exists to end.
    /// The upper bounds are two orders of magnitude past the largest model
    /// anyone has quantised for a phone, and they keep the product of these
    /// fields and a context length inside `Int64` by construction, so the
    /// estimate never has to defend itself against overflow.
    public var isValid: Bool {
        guard !architecture.isEmpty,
              (1...1024).contains(blockCount),
              (1...(1 << 20)).contains(embeddingLength),
              (1...4096).contains(headCount),
              (1...4096).contains(headCountKV),
              (1...(1 << 16)).contains(keyLength),
              (1...(1 << 16)).contains(valueLength),
              (1...(1 << 24)).contains(vocabularySize)
        else { return false }
        if let trainedContextLength, !(1...(1 << 24)).contains(trainedContextLength) { return false }
        if let slidingWindow, !(1...(1 << 24)).contains(slidingWindow) { return false }
        return true
    }
}

public extension GGUFModelDimensions {

    /// Reads a model's shape out of the file, or `nil` if the header cannot be
    /// read or does not survive validation. `nil` is not a failure to report to
    /// anyone: it means the memory estimate falls back to a guess and says so.
    static func read(fromFileAt url: URL) -> GGUFModelDimensions? {
        guard let values = GGUFMetadata.values(forKeys: exactKeys, endingIn: suffixes, inFileAt: url) else { return nil }
        return make(from: values)
    }

    static func read(in data: Data) -> GGUFModelDimensions? {
        guard let values = GGUFMetadata.values(forKeys: exactKeys, endingIn: suffixes, in: data) else { return nil }
        return make(from: values)
    }

    private static var exactKeys: Set<String> { [GGUFMetadata.architectureKey, GGUFMetadata.tokensKey] }

    /// Everything under the architecture prefix, which is not known until the
    /// pass that reads these is already under way.
    private static var suffixes: Set<String> {
        [
            ".block_count",
            ".embedding_length",
            ".attention.head_count",
            ".attention.head_count_kv",
            ".attention.key_length",
            ".attention.value_length",
            ".vocab_size",
            ".context_length",
            ".attention.sliding_window"
        ]
    }

    private static func make(from values: [String: GGUFMetadata.Value]) -> GGUFModelDimensions? {
        guard case .string(let architecture)? = values[GGUFMetadata.architectureKey] else { return nil }

        func integer(_ suffix: String) -> Int? {
            guard case .integer(let number)? = values["\(architecture)\(suffix)"] else { return nil }
            return Int(exactly: number)
        }

        guard let blockCount = integer(".block_count"),
              let embeddingLength = integer(".embedding_length"),
              let headCount = integer(".attention.head_count"),
              headCount > 0
        else { return nil }

        // llama.cpp reads head_count_kv with head_count as its default: models
        // from before grouped-query attention simply do not write the key, and
        // treating that as zero would put their cache at nothing.
        let headCountKV = integer(".attention.head_count_kv") ?? headCount
        // Same rule, same place in llama.cpp: a model that does not split the
        // embedding unevenly across heads leaves these out and the width is
        // n_embd / n_head.
        let perHead = embeddingLength / headCount
        let keyLength = integer(".attention.key_length") ?? perHead
        let valueLength = integer(".attention.value_length") ?? perHead

        // The vocabulary is the one number a model may legitimately not
        // declare. Counting the token array is exact and, because the elements
        // are stepped over rather than decoded, costs nothing but the walk.
        var vocabularySize = integer(".vocab_size")
        if vocabularySize == nil, case .arrayCount(let count)? = values[GGUFMetadata.tokensKey] {
            vocabularySize = count
        }
        guard let vocabularySize else { return nil }

        let dimensions = GGUFModelDimensions(
            architecture: architecture,
            blockCount: blockCount,
            embeddingLength: embeddingLength,
            headCount: headCount,
            headCountKV: headCountKV,
            keyLength: keyLength,
            valueLength: valueLength,
            vocabularySize: vocabularySize,
            trainedContextLength: integer(".context_length"),
            slidingWindow: integer(".attention.sliding_window")
        )
        // A file that parsed cleanly can still be describing nonsense. Better
        // to fall back to the flat guess, which is at least honest about being
        // one, than to multiply out a number nobody can defend.
        return dimensions.isValid ? dimensions : nil
    }
}
