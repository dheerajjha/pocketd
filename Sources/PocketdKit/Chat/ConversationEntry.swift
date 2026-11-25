import Foundation

/// Stored as a string so that a new kind of page cannot make an older build
/// discard an otherwise readable conversation. No personal details in the key.
public struct ConversationTopic: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let day = Self(rawValue: "day")
    public static let reminders = Self(rawValue: "reminders")
    public static let sleep = Self(rawValue: "sleep")
    public static let activity = Self(rawValue: "activity")
    public static let shortcut = Self(rawValue: "shortcut")
    public static func routine(_ id: UUID) -> Self { Self(rawValue: "routine:\(id.uuidString)") }

    public var label: String {
        switch self {
        case .day: "Your day"
        case .reminders: "Reminders"
        case .sleep: "Sleep"
        case .activity: "Activity"
        case .shortcut: "Shortcut"
        default: rawValue.hasPrefix("routine:") ? "Routine" : "Conversation"
        }
    }
}

/// The same sheet can resume an explicitly chosen chat, ask about a page, or
/// accept one independent Shortcut invocation. Those are not the same intent.
public enum ConversationEntry: Equatable, Sendable {
    case main, current, page(ConversationTopic), shortcut(UUID)

    /// Only a keyboard/open request for the *already running* thread can be
    /// fulfilled before its answer ends. This leaves Stop available.
    public func canOpenDuringReply(keyboardOnly: Bool, current: UUID, topic: ConversationTopic?, main: UUID?) -> Bool {
        guard keyboardOnly else { return false }
        switch self {
        case .current: return true
        case .main: return main == current || (main == nil && topic == nil)
        case let .page(expected): return expected == topic
        case .shortcut: return false
        }
    }

    public func destination(current: Conversation, history: [Conversation], main: UUID?,
                            needsEmptyDraft: Bool, now: Date = Date()) -> Conversation {
        // Prefer live state to a debounced or checkpointed copy of the same ID.
        let others = history.filter { $0.id != current.id }
        func blank(_ topic: ConversationTopic? = nil, id: UUID = UUID()) -> Conversation {
            Conversation(id: id, createdAt: now, updatedAt: now, topic: topic)
        }
        switch self {
        case .current:
            return needsEmptyDraft && current.hasDraft ? blank(current.topic) : current
        case .main:
            let chosen: Conversation
            if let main {
                chosen = current.id == main ? current : others.first { $0.id == main } ?? blank(id: main)
            } else {
                chosen = current.topic == nil ? current : others.first { $0.topic == nil } ?? blank()
            }
            return needsEmptyDraft && chosen.hasDraft ? blank() : chosen
        case let .page(topic):
            // Never skip over a more recent draft to quietly resume an older
            // thread on the same subject. A supplied question gets a new one.
            let latest = current.topic == topic ? current : others.first { $0.topic == topic }
            if let latest, (!needsEmptyDraft || !latest.hasDraft),
               (latest.messages.isEmpty || latest.hasDraft || now.timeIntervalSince(latest.updatedAt) <= 30 * 60) {
                return latest
            }
            return blank(topic)
        case let .shortcut(id):
            // Re-presentation of *this* invocation may already have saved its
            // editable words during setup. Identical text is not identity.
            return current.id == id ? current : others.first { $0.id == id } ?? blank(.shortcut, id: id)
        }
    }
}
