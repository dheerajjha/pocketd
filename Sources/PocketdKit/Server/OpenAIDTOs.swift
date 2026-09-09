import Foundation

/// Accepts both `"stop": "###"` and `"stop": ["###", "\n\n"]`, because the
/// OpenAI API accepts both and clients in the wild send both.
struct StringOrArray: Codable, Sendable, Equatable {
    var values: [String]

    init(_ values: [String]) { self.values = values }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = [single]
        } else {
            values = (try? container.decode([String].self)) ?? []
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

enum OpenAI {
    struct Message: Codable, Sendable {
        var role: String
        /// Optional because a tool-call message may carry no text, and a
        /// decode failure on the whole request is a worse answer than an
        /// empty turn.
        var content: String?
    }

    /// `{"stream_options": {"include_usage": true}}` asks for token counts in a
    /// streamed response. LangChain and the OpenAI SDKs both send it, and a
    /// server that ignores it reports zero tokens for every streamed call.
    struct StreamOptions: Codable, Sendable {
        var include_usage: Bool?
    }

    struct ChatCompletionRequest: Codable, Sendable {
        var model: String
        var messages: [Message]
        var stream: Bool?
        var stream_options: StreamOptions?
        var temperature: Double?
        var top_p: Double?
        var max_tokens: Int?
        var max_completion_tokens: Int?
        var stop: StringOrArray?
        var seed: UInt64?

        var resolvedMaxTokens: Int? { max_completion_tokens ?? max_tokens }

        func generationOptions() -> GenerationOptions {
            GenerationOptions(
                temperature: temperature,
                topP: top_p,
                maxTokens: resolvedMaxTokens,
                stopSequences: stop?.values ?? [],
                seed: seed
            )
        }

        func chatMessages() -> [ChatMessage] {
            messages.map { message in
                ChatMessage(
                    role: ChatMessage.Role(rawValue: message.role) ?? .user,
                    content: message.content ?? ""
                )
            }
        }
    }

    struct CompletionRequest: Codable, Sendable {
        var model: String
        var prompt: String
        var stream: Bool?
        var temperature: Double?
        var top_p: Double?
        var max_tokens: Int?
        var stop: StringOrArray?
        var seed: UInt64?
    }

    struct Usage: Codable, Sendable {
        var prompt_tokens: Int
        var completion_tokens: Int
        var total_tokens: Int

        init(_ usage: TokenUsage) {
            prompt_tokens = usage.promptTokens
            completion_tokens = usage.completionTokens
            total_tokens = usage.totalTokens
        }
    }

    struct ChatChoice: Codable, Sendable {
        var index: Int
        var message: Message
        var finish_reason: String?
    }

    struct ChatCompletionResponse: Codable, Sendable {
        var id: String
        var object: String = "chat.completion"
        var created: Int
        var model: String
        var choices: [ChatChoice]
        var usage: Usage
        var system_fingerprint: String?
    }

    struct Delta: Codable, Sendable {
        var role: String?
        var content: String?
    }

    struct ChunkChoice: Codable, Sendable {
        var index: Int
        var delta: Delta
        var finish_reason: String?
    }

    struct ChatCompletionChunk: Codable, Sendable {
        var id: String
        var object: String = "chat.completion.chunk"
        var created: Int
        var model: String
        var choices: [ChunkChoice]
        /// Present only on the final chunk, and only when the client asked for
        /// it. The OpenAI spec requires `choices` to be empty on that chunk.
        var usage: Usage?
        var system_fingerprint: String?
    }

    struct Model: Codable, Sendable {
        var id: String
        var object: String = "model"
        var created: Int
        var owned_by: String
    }

    struct ModelList: Codable, Sendable {
        var object: String = "list"
        var data: [Model]
    }

    struct ErrorBody: Codable, Sendable {
        var message: String
        var type: String
        var code: String?
    }

    struct ErrorResponse: Codable, Sendable {
        var error: ErrorBody
    }
}
