import Foundation
import PocketdKit

// The two decisions Today makes about itself — which cards sit under the tiles,
// and which one question sits above the composer — as plain functions of what
// the screen already holds, so they can be read in one place and do not drift
// into `body`.

// MARK: - Feed cards

/// Today's feed: at most two cards, each one sentence and one link, and only
/// when there is something to say.
///
/// A feed that is always full stops being read. So every card here is about
/// something that changed or something only the person can do, and the order
/// is the order of what costs them most to miss:
///
/// 1. **No brain can answer** — every question asked from this screen would
///    wait forever. "Choose how Pocketd thinks", never the word "brain" (that
///    lives on the Brain page).
/// 2. **A routine said something** nobody has read — news, and it is gone the
///    moment its page is opened.
/// 3. **iOS refused a source** the person switched on — the one problem only
///    the Settings app can fix, so the card says where.
/// 4. **No morning brief yet** — an offer, so it comes last, and only once
///    there is a day connected for it to be about.
///
/// The offers can be put away and stay away (`dismissed…`); the problems
/// cannot, except the refused source, which is the person's own decision as
/// often as it is a mistake.
enum TodayFeed {

    enum Card: Identifiable, Equatable {
        case chooseBrain
        case brainFailed
        case routineResult(taskID: UUID, title: String, text: String, isTrouble: Bool)
        case refused([Ability])
        case morningBrief

        var id: String {
            switch self {
            case .chooseBrain: "chooseBrain"
            case .brainFailed: "brainFailed"
            case let .routineResult(taskID, _, _, _): "result-\(taskID.uuidString)"
            case .refused: "refused"
            case .morningBrief: "morningBrief"
            }
        }
    }

    /// The most a screen shows. Two, because the tiles are the screen and the
    /// feed is a margin note.
    static let limit = 2

    struct Inputs {
        var brain: BrainStatus
        /// The newest unread routine result, already in words.
        var latestResult: (taskID: UUID, title: String, text: String, isTrouble: Bool)?
        var snapshot: TodaySnapshot
        /// Nil until the routines on disk have been read this launch, so the
        /// offer does not flash on and off while they load.
        var hasMorningBrief: Bool?
        var dismissedMorningBrief: Bool
        var dismissedRefusals: Set<Ability>
    }

    static func cards(_ inputs: Inputs) -> [Card] {
        var cards: [Card] = []

        switch inputs.brain {
        case .none(hasDownloaded: false): cards.append(.chooseBrain)
        case .failed: cards.append(.brainFailed)
        case .none, .arriving, .loading, .ready, .cannotReadYourDay: break
        }

        if let result = inputs.latestResult {
            cards.append(.routineResult(
                taskID: result.taskID, title: result.title, text: result.text, isTrouble: result.isTrouble
            ))
        }

        let refused = refusedSources(inputs.snapshot).filter { !inputs.dismissedRefusals.contains($0) }
        if !refused.isEmpty {
            cards.append(.refused(refused))
        }

        if inputs.hasMorningBrief == false, !inputs.dismissedMorningBrief, inputs.snapshot.hasAnythingConnected {
            cards.append(.morningBrief)
        }

        return Array(cards.prefix(limit))
    }

    /// The sources switched on in Pocketd that iOS says no to, in the order
    /// the tiles show them.
    static func refusedSources(_ snapshot: TodaySnapshot) -> [Ability] {
        var sources: [Ability] = []
        if snapshot.calendar == .refused { sources.append(.calendar) }
        if snapshot.reminders == .refused { sources.append(.reminders) }
        if snapshot.health == .refused { sources.append(.health) }
        return sources
    }

    /// "Calendar is off in iOS Settings." / "Calendar and Reminders are off
    /// in iOS Settings."
    static func refusedSentence(_ sources: [Ability]) -> String {
        let names = sources.map(\.title)
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) is off in iOS Settings."
        default:
            let list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            return "\(list) are off in iOS Settings."
        }
    }
}

// MARK: - The one question

/// The question above Today's composer: one, and the one most worth asking at
/// this hour about this day — and never one about a source Pocketd cannot
/// read.
///
/// Evening is for tomorrow. Something overdue outranks the rest of the day,
/// because it is the thing the person is most likely to want handled. The
/// morning asks what today holds; the rest of the day offers "Remind me to…",
/// which is half a sentence the person finishes — the thing people most often
/// think of mid-afternoon — but only with Reminders connected: offered with
/// Reminders off, it was a chip that led straight to a refusal. Without
/// Reminders it is the calendar's question, without either Health's, and with
/// nothing connected there is no chip at all.
///
/// Morning and evening are the brief's own (`TimeOfDayKind`), so the chip and
/// the greeting above it never disagree about what time of day it is.
enum TodayQuestion {
    static let today = "What's on today?"
    static let tomorrow = "What's on tomorrow?"
    static let overdue = "Anything overdue?"
    static let remind = "Remind me to…"
    static let sleep = "How did I sleep?"

    static func pick(_ snapshot: TodaySnapshot, now: Date, calendar: Calendar = .current) -> String? {
        let time = TimeOfDayKind.from(now: now, calendar: calendar)
        if time == .evening, snapshot.calendar.isReadable {
            return tomorrow
        }
        if snapshot.reminders.isReadable, !DueSplit.of(snapshot, now: now, calendar: calendar).overdue.isEmpty {
            return overdue
        }
        if time == .morning, snapshot.calendar.isReadable {
            return today
        }
        if snapshot.reminders.isReadable { return remind }
        if snapshot.calendar.isReadable { return today }
        if snapshot.health.isReadable { return sleep }
        return nil
    }
}
