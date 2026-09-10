import Foundation

/// A single turn in a conversation, in the shape both the OpenAI and Ollama
/// wire formats agree on.
public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable, CaseIterable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    /// Decoded image bytes attached to this turn. Kept as raw data rather than
    /// a platform image type so the wire layer, which has no UIKit, can carry
    /// them to the engine, which does.
    public var images: [Data]
    /// What the tools this turn ran actually found, drawn rather than narrated.
    ///
    /// Here rather than in a parallel array beside the transcript because a
    /// card belongs to the turn that produced it: reordering, deleting or
    /// reopening a conversation must not be able to leave a card attached to
    /// the wrong answer.
    ///
    /// Never reaches the model. `ContextGuard.estimateTokens` reads `content`
    /// alone, and it is right to — the payload these were built from was
    /// already charged to the prompt once, as the tool result, and charging it
    /// again would shrink the usable window for a rendering the model cannot
    /// see. Nor does it reach the wire: the OpenAI and Ollama routes serialise
    /// `OpenAI.Message` and `Ollama.Message`, which are separate types with
    /// their own fields, so nothing here can appear in an HTTP response.
    public var cards: [AnswerCard]

    public init(role: Role, content: String, images: [Data] = [], cards: [AnswerCard] = []) {
        self.role = role
        self.content = content
        self.images = images
        self.cards = cards
    }

    public static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
    public static func assistant(_ content: String) -> ChatMessage { .init(role: .assistant, content: content) }
}

extension ChatMessage {
    private enum CodingKeys: String, CodingKey {
        case role, content, images, cards
    }

    /// Written by hand only because a synthesised decoder throws on a key that
    /// is not there, and every conversation already on disk was written before
    /// `cards` existed. `ConversationStore.all()` skips a file it cannot
    /// decode, so the synthesised version would have made every transcript
    /// anyone has ever held disappear from the history list at the moment this
    /// field shipped. `images` is read the same way for the same reason.
    ///
    /// `cards` is written only when there are some. It is nearly always empty,
    /// and the store rewrites the whole conversation on every save.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        images = try container.decodeIfPresent([Data].self, forKey: .images) ?? []
        cards = try container.decodeIfPresent([AnswerCard].self, forKey: .cards) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(images, forKey: .images)
        if !cards.isEmpty {
            try container.encode(cards, forKey: .cards)
        }
    }
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
