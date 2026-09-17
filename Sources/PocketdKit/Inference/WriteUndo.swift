import Foundation

/// One change this app made to the user's calendar or reminders, and the handle
/// that can take it back.
///
/// Recorded on the way out of the write, by the only code that ever holds both
/// halves at once: the store knows the identifier it just minted, and nothing
/// downstream does. The tool payload deliberately never carries it — an
/// identifier is opaque and costs prompt tokens to say nothing the model can
/// use — so if the write does not remember it here, the write is unundoable.
public struct PersonalDataWrite: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case reminder
        case event

        /// The tool whose card reports a write of this kind, so a reminder's
        /// Undo can never land on a calendar card that happens to quote the
        /// same words.
        public var toolName: String {
            switch self {
            case .reminder: PersonalDataToolNames.reminders
            case .event: PersonalDataToolNames.calendar
            }
        }
    }

    public let id: UUID
    public let kind: Kind
    /// EventKit's own handle. Opaque, and never shown or sent anywhere.
    public let identifier: String
    /// What the user asked it to be called, exactly as it was written. This is
    /// what ties the write to the card that reports it.
    public let title: String
    public let madeAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        identifier: String,
        title: String,
        madeAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.madeAt = madeAt
    }
}

/// Which write, if any, a card is reporting — and therefore where an Undo
/// belongs.
///
/// A card is drawn from a tool payload, and the payload for a write is one
/// sentence: `Reminder set: "Call the dentist" for 4:00 PM.` The identifier is
/// not in it and must not be, so the join is made on the one thing both halves
/// hold: the title, quoted, exactly as the write recorded it. That is not a
/// fuzzy match — `PersonalDataWrites.confirmation` puts the title in quotes
/// verbatim, and the ledger stores the same string the same call passed to
/// EventKit.
///
/// Deliberately conservative in three ways, because the button this decides to
/// show deletes something:
///
/// - A card with sections is a *reading* and never a write, whatever it quotes.
///   "Ticked off …" and a list of reminders are different shapes.
/// - The card's source tool has to match the write's kind, so an Undo for a
///   reminder cannot appear under a calendar card.
/// - The offer expires. Five minutes is long enough to notice a wrong time and
///   far too short to have built anything on top of the new item.
public enum WriteUndo {
    /// How long an Undo stays on a card.
    public static let window: TimeInterval = 5 * 60

    /// The most recent still-undoable write this card reports, or `nil`.
    public static func offer(
        for card: AnswerCard,
        from writes: [PersonalDataWrite],
        now: Date = Date()
    ) -> PersonalDataWrite? {
        // A write result is a sentence and nothing else. Anything with rows in
        // it came back from a read.
        guard card.sections.isEmpty, let lede = card.lede, !lede.isEmpty else { return nil }
        guard let source = card.source else { return nil }

        return writes
            .filter { write in
                write.kind.toolName == source
                    && !isExpired(write, now: now)
                    && !write.title.isEmpty
                    && lede.contains("\"\(write.title)\"")
            }
            // Newest first: the same title written twice in five minutes is
            // two cards, and the lower one is the later write.
            .max { $0.madeAt < $1.madeAt }
    }

    /// Whether this write is past the point where taking it back is a surprise
    /// rather than a correction.
    public static func isExpired(_ write: PersonalDataWrite, now: Date = Date()) -> Bool {
        now.timeIntervalSince(write.madeAt) >= window
    }

    /// What the card says once the write has been taken back.
    ///
    /// Past tense and specific. "Undone" alone leaves the reader checking their
    /// list to find out what just happened.
    public static func undoneSentence(for write: PersonalDataWrite) -> String {
        switch write.kind {
        case .reminder: "Removed the reminder \"\(write.title)\"."
        case .event: "Removed \"\(write.title)\" from your calendar."
        }
    }
}
