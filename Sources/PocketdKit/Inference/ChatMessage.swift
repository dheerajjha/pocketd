import Foundation

/// A single turn in a conversation, in the shape both the OpenAI and Ollama
/// wire formats agree on.
public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable, CaseIterable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
    public static func assistant(_ content: String) -> ChatMessage { .init(role: .assistant, content: content) }
}

/// Sampling knobs. Every field is optional so that a caller can send only what
/// it cares about and the engine can fall back to the model's own defaults —
/// clamping an unset value to some invented default is how you get a model that
/// silently behaves differently through the API than it does in the chat tab.
public struct GenerationOptions: Sendable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var repeatPenalty: Double?
    public var maxTokens: Int?
    public var stopSequences: [String]
    public var seed: UInt64?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        repeatPenalty: Double? = nil,
        maxTokens: Int? = nil,
        stopSequences: [String] = [],
        seed: UInt64? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.seed = seed
    }

    public static let `default` = GenerationOptions()
}
