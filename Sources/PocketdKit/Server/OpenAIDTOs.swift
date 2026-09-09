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
    /// `content` is a plain string in most requests and an array of typed
    /// parts whenever an image is attached. Both are valid OpenAI, and a client
    /// that sends the array shape to a server expecting a string gets a decode
    /// failure for the whole request rather than a message about the image.
    struct MessageContent: Codable, Sendable {
        var text: String
        /// Raw bytes of every `image_url` part that carried a data: URI.
        var images: [Data]

        init(text: String, images: [Data] = []) {
            self.text = text
            self.images = images
        }

        private struct Part: Codable {
            struct ImageURL: Codable { var url: String }
            var type: String
            var text: String?
            var image_url: ImageURL?
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let plain = try? container.decode(String.self) {
                self.init(text: plain)
                return
            }
            let parts = (try? container.decode([Part].self)) ?? []
            var text = ""
            var images: [Data] = []
            for part in parts {
                switch part.type {
                case "text":
                    if let value = part.text {
                        text += text.isEmpty ? value : "\n" + value
                    }
                case "image_url":
                    if let url = part.image_url?.url, let data = MessageContent.decodeDataURI(url) {
                        images.append(data)
                    }
                default:
                    break
                }
            }
            self.init(text: text, images: images)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }

        /// Only data: URIs are accepted. Fetching an http: image would make the
        /// phone issue outbound requests on a caller's behalf, which is a
        /// request-forgery surface a local inference server has no business
        /// opening.
        static func decodeDataURI(_ url: String) -> Data? {
            guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
            let meta = url[url.startIndex..<comma]
            guard meta.contains(";base64") else { return nil }
            return Data(base64Encoded: String(url[url.index(after: comma)...]))
        }
    }

    struct Message: Codable, Sendable {
        var role: String
        /// Optional because a tool-call message may carry no text, and a
        /// decode failure on the whole request is a worse answer than an
        /// empty turn.
        var content: MessageContent?

        init(role: String, content: MessageContent?) {
            self.role = role
            self.content = content
        }

        init(role: String, content: String?) {
            self.role = role
            self.content = content.map { MessageContent(text: $0) }
        }
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
                    content: message.content?.text ?? "",
                    images: message.content?.images ?? []
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
        /// Not in OpenAI's schema, which has no field for this. Clients that
        /// do not know it ignore it; clients that want to know whether they
        /// can send an image have nowhere else to look.
        var capabilities: [String]?
        var context_length: Int?
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
