import Foundation

/// Ollama's wire format, reproduced closely enough that clients written for a
/// desktop Ollama work against a phone with only the host changed.
///
/// The duration fields are nanoseconds and several clients display them without
/// checking for zero, so they are always populated with something truthful.
enum Ollama {
    struct Message: Codable, Sendable {
        var role: String
        var content: String
    }

    struct Options: Codable, Sendable {
        var temperature: Double?
        var top_p: Double?
        var top_k: Int?
        var repeat_penalty: Double?
        var num_predict: Int?
        var stop: [String]?
        var seed: UInt64?

        func generationOptions() -> GenerationOptions {
            GenerationOptions(
                temperature: temperature,
                topP: top_p,
                topK: top_k,
                repeatPenalty: repeat_penalty,
                // Ollama uses -1 for "unlimited"; passing that through as a
                // token budget would truncate everything to nothing.
                maxTokens: (num_predict ?? -1) > 0 ? num_predict : nil,
                stopSequences: stop ?? [],
                seed: seed
            )
        }
    }

    struct ChatRequest: Codable, Sendable {
        var model: String
        var messages: [Message]
        var stream: Bool?
        var options: Options?
    }

    struct GenerateRequest: Codable, Sendable {
        var model: String
        var prompt: String
        var system: String?
        var stream: Bool?
        var options: Options?
    }

    struct ChatResponse: Codable, Sendable {
        var model: String
        var created_at: String
        var message: Message
        var done: Bool
        var done_reason: String?
        var total_duration: Int64?
        var load_duration: Int64?
        var prompt_eval_count: Int?
        var prompt_eval_duration: Int64?
        var eval_count: Int?
        var eval_duration: Int64?
    }

    struct GenerateResponse: Codable, Sendable {
        var model: String
        var created_at: String
        var response: String
        var done: Bool
        var done_reason: String?
        var total_duration: Int64?
        var load_duration: Int64?
        var prompt_eval_count: Int?
        var prompt_eval_duration: Int64?
        var eval_count: Int?
        var eval_duration: Int64?
    }

    /// `parent_model` and `families` carry no `omitempty` in Ollama's Go
    /// definition, so they are always on the wire and a strict client decodes
    /// them as required. Emitting them empty is what keeps those clients working.
    struct ModelDetails: Codable, Sendable {
        var parent_model: String = ""
        var format: String
        var family: String
        var families: [String]
        var parameter_size: String
        var quantization_level: String
        var context_length: Int?
    }

    struct TagEntry: Codable, Sendable {
        var name: String
        var model: String
        var modified_at: String
        var size: Int64
        var digest: String
        var details: ModelDetails
        /// Open WebUI reads this to decide which controls to offer. Claiming a
        /// capability we do not have is worse than claiming none.
        var capabilities: [String]
    }

    struct TagsResponse: Codable, Sendable {
        var models: [TagEntry]
    }

    struct VersionResponse: Codable, Sendable {
        var version: String
    }

    /// `/api/ps` — what is resident right now. On a phone this is zero or one
    /// model, never more.
    struct ProcessEntry: Codable, Sendable {
        var name: String
        var model: String
        var size: Int64
        var digest: String
        var details: ModelDetails
        var expires_at: String
        var size_vram: Int64
        var context_length: Int
    }

    struct ProcessResponse: Codable, Sendable {
        var models: [ProcessEntry]
    }

    struct ShowRequest: Codable, Sendable {
        var name: String?
        var model: String?

        var resolved: String { model ?? name ?? "" }
    }

    struct ShowResponse: Codable, Sendable {
        var license: String
        var details: ModelDetails
        var model_info: [String: Int]
    }

    struct ErrorResponse: Codable, Sendable {
        var error: String
    }

    /// Ollama timestamps are RFC 3339 with fractional seconds.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func tagEntry(for model: ModelRecord) -> TagEntry {
        TagEntry(
            name: model.id,
            model: model.id,
            modified_at: timestamp(),
            size: model.sizeBytes,
            // Clients use the digest only as a cache key, so a stable hash of
            // the identity we serve is both sufficient and honest.
            digest: String(format: "%016x", UInt64(bitPattern: Int64(model.id.hashValue))),
            details: details(for: model),
            capabilities: ["completion"]
        )
    }

    static func details(for model: ModelRecord) -> ModelDetails {
        let family = model.id.split(separator: "-").first.map(String.init) ?? model.id
        return ModelDetails(
            format: "gguf",
            family: family,
            families: [family],
            parameter_size: model.parameters,
            quantization_level: model.quantization,
            context_length: model.contextLength
        )
    }
}
