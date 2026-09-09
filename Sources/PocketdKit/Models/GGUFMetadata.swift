import Foundation

/// Reads one string out of a GGUF file's metadata header.
///
/// This exists for exactly one question: does this model's chat template render
/// tool schemas itself? LocalLLMClient answers it from
/// `llama_model_meta_val_str(model, "tokenizer.chat_template", …)` and then
/// `template.contains("tools")`, but it keeps both the `Model` and the
/// `Context` internal, and `LlamaClient._context` exists only in the library's
/// own DEBUG builds. There is no public accessor. Loading a second copy of the
/// weights to ask llama.cpp would cost gigabytes, so the header is parsed here
/// instead — the file is memory-mapped and only the pages the header occupies
/// are ever touched.
///
/// Deliberately total: every malformed, truncated or unexpected input returns
/// `nil` rather than trapping. The caller is a context-budget estimate, and an
/// estimate that crashes the app is worse than one that guesses.
public enum GGUFMetadata {

    /// llama.cpp's `LLM_KV_TOKENIZER_CHAT_TEMPLATE`.
    public static let chatTemplateKey = "tokenizer.chat_template"

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
        // Mapped, not read: a GGUF is measured in gigabytes and the header is
        // the first few hundred kilobytes of it.
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return string(forKey: key, in: data)
    }

    /// A key holding no value, or a value that is not a string, reads as `nil`.
    static func string(forKey key: String, in data: Data) -> String? {
        var reader = Reader(data)

        guard reader.bytes(4).map({ Array($0) }) == Array("GGUF".utf8),
              let version = reader.u32(),
              // v1 counted with 32-bit fields. Nothing has written one since
              // 2023 and llama.cpp itself no longer reads them, so rather than
              // carry a second layout, say so by refusing.
              version == 2 || version == 3,
              reader.u64() != nil,                 // tensor count, unused here
              let pairs = reader.u64(),
              pairs <= UInt64(reader.remaining)    // every pair is at least a byte
        else { return nil }

        for _ in 0..<pairs {
            guard let name = reader.string(), let type = reader.u32() else { return nil }
            if name == key {
                guard type == ValueType.string else { return nil }
                return reader.string()
            }
            guard reader.skipValue(ofType: type) else { return nil }
        }
        return nil
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
        mutating func string() -> String? {
            guard let raw = stringBytes() else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }

        mutating func stringBytes() -> Data? {
            // The length check is against what is left of the file, so a corrupt
            // length cannot ask for a gigabyte allocation.
            guard let length = u64(), length <= UInt64(remaining) else { return nil }
            return bytes(Int(length))
        }

        mutating func skipValue(ofType type: UInt32) -> Bool {
            if let width = ValueType.width(of: type) {
                return bytes(width) != nil
            }
            switch type {
            case ValueType.string:
                return stringBytes() != nil
            case ValueType.array:
                guard let element = u32(), let count = u64(), count <= UInt64(remaining) else { return false }
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
            default:
                return false
            }
        }
    }
}
