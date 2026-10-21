import Foundation

/// Whether a brain can read your day, in the two words a list row has room for.
///
/// This is the one capability question a person choosing a brain needs
/// answered, and for a long time nothing on screen answered it: the Brain list
/// and the intro's options sheet labelled SmolLM2 "Quick · Fits well" and never
/// said it could not open the calendar, and its first answers were invented
/// agendas. Two cases, not three, because a row is not the place for "unknown":
/// a brain nobody has vetted is described by what it will reliably do, which is
/// chat.
public enum DayAccess: String, Sendable, Equatable, Codable {
    /// Calendar, reminders and health are handed to it, and it can use them.
    case readsYourDay
    /// It can talk, and anything it says about your day is a guess.
    case chatOnly

    /// The words for a list row.
    public var label: String {
        switch self {
        case .readsYourDay: "Reads your day"
        case .chatOnly: "Chat only"
        }
    }

    public var readsYourDay: Bool { self == .readsYourDay }
}

public extension ModelRecord {
    /// Whether this brain reads your day, as a list should describe it before
    /// it has been loaded.
    ///
    /// Only a vetted `.yes` counts. The curated catalogue wins on id, so a
    /// manifest written by an older build cannot promote or demote a catalogue
    /// brain; anything added through search is `.unknown` until somebody has
    /// watched it work, and an unvetted brain is described by what it will
    /// reliably do.
    ///
    /// Once a brain is resident the engine's own verdict is better evidence
    /// than either, because it has read the file: pass it as `resident` and it
    /// decides. Llama 3.2 3B is the case that needs it — `.unknown` in the
    /// catalogue, and handed the tools by the gate on the strength of its
    /// template.
    func dayAccess(resident gate: ToolGate.Decision? = nil) -> DayAccess {
        if let gate, gate != .noModelLoaded {
            return gate.registersTools ? .readsYourDay : .chatOnly
        }
        return ToolGate.declaredSupport(for: self).isYes ? .readsYourDay : .chatOnly
    }
}

/// The one brain Pocketd recommends on this phone.
///
/// Four screens used to answer this question four ways — the intro picked the
/// largest tool-capable brain, a replayed intro picked the next one down
/// because the first was installed, the Brain screen listed three spanning the
/// phone (two of which could not read anything), and the upgrade notice picked
/// the smallest. On the QA simulator that was Gemma 4 E2B, Qwen3 4B, Llama 3.2
/// 1B/3B and Qwen3 1.7B, for one person, in one afternoon. This is the single
/// rule they all ask now.
///
/// The rule, in order:
///
/// 1. **Only brains that can read your day.** A vetted `.yes`, no projector.
///    An assistant that cannot open the calendar answers "what's on tomorrow?"
///    fluently and from nothing, and a recommendation is a promise that it
///    will not.
/// 2. **Comfortable, and a few minutes to download.** The largest such brain
///    whose download is at most `preferredDownloadCeilingBytes`. Larger is
///    better — the download is paid once and the capability is used every day
///    — but only up to the size somebody will wait for during an intro.
/// 3. If no comfortable brain is that small, the smallest comfortable one: the
///    closest thing to "a few minutes" this catalogue has.
/// 4. If nothing is comfortable, the smallest that loads at all. A tight brain
///    that reads the day beats a comfortable one that cannot, and the smallest
///    tight one leaves the most room for the conversation.
/// 5. `nil` when nothing that reads your day fits this phone. Never a chat-only
///    brain as a consolation: the caller says the phone is too small instead.
///
/// Deliberately blind to what is installed. The recommendation is a fact about
/// the phone; whether to offer a download is a separate question with its own
/// function (`offer(for:installed:)`), and answering both in one place is how a
/// replayed intro came to recommend a different brain from the first run.
public enum BrainRecommendation {

    /// About 1.5 GB: four or five minutes on ordinary Wi-Fi, which is as long as
    /// an intro can ask somebody to wait. Decimal, like the sizes the download
    /// screens print.
    public static let preferredDownloadCeilingBytes: Int64 = 1_500_000_000

    /// Whether `model` may appear anywhere Pocketd recommends a brain.
    public static func isRecommendable(_ model: ModelRecord, for budget: DeviceBudget) -> Bool {
        model.dayAccess().readsYourDay
            && !model.declaredCapabilities.vision.isYes
            && budget.fit(for: model).isDownloadable
    }

    /// THE recommended brain for this phone, or `nil` when nothing that reads
    /// your day fits it.
    public static func recommended(
        for budget: DeviceBudget,
        in catalog: [ModelRecord] = ModelCatalog.all
    ) -> ModelRecord? {
        let pool = catalog
            .filter { isRecommendable($0, for: budget) }
            .sorted(by: smallestFirst)
        let comfortable = pool.filter { budget.fit(for: $0) == .comfortable }

        if let best = comfortable.last(where: { $0.totalDownloadBytes <= preferredDownloadCeilingBytes }) {
            return best
        }
        if let nearest = comfortable.first { return nearest }
        return pool.first
    }

    /// Every brain worth recommending on this phone, smallest first, the
    /// recommendation among them.
    ///
    /// Comfortable ones only, plus the recommendation itself when it is tight —
    /// on a small phone that is the only brain that reads the day, and a list
    /// that left it out would leave the intro selecting a row that is not on
    /// screen. Tight brains are otherwise left to the full list: a
    /// recommendation that warns "it loads, but leaves little room" on every
    /// row is not a recommendation.
    public static func shortlist(
        for budget: DeviceBudget,
        in catalog: [ModelRecord] = ModelCatalog.all,
        excluding installed: Set<String> = []
    ) -> [ModelRecord] {
        let pick = recommended(for: budget, in: catalog)
        return catalog
            .filter { isRecommendable($0, for: budget) }
            .filter { budget.fit(for: $0) == .comfortable || $0.id == pick?.id }
            .filter { !installed.contains($0.id) }
            .sorted(by: smallestFirst)
    }

    /// Whether any of `installed` already reads your day, so there is nothing
    /// worth downloading.
    public static func alreadyReadsYourDay(_ installed: [ModelRecord]) -> Bool {
        installed.contains { $0.dayAccess().readsYourDay }
    }

    /// What to offer somebody who already has `installed`: the recommendation,
    /// or `nil` when there is nothing worth fetching.
    ///
    /// `nil` in two cases, and both are the point. The recommended brain is
    /// already here — a replayed intro must say "Ready", not download 1.1 GB a
    /// second time. Or another brain that reads your day is here — somebody
    /// who chose Qwen3 4B does not need Qwen3 1.7B as well, and offering it is
    /// how a replay came to suggest a fourth brain to a phone holding three.
    /// A phone holding only chat-only brains is offered the recommendation:
    /// that is the upgrade the "can't read your calendar" notice exists for.
    public static func offer(
        for budget: DeviceBudget,
        installed: [ModelRecord],
        in catalog: [ModelRecord] = ModelCatalog.all
    ) -> ModelRecord? {
        guard !alreadyReadsYourDay(installed),
              let pick = recommended(for: budget, in: catalog),
              !installed.contains(where: { $0.id == pick.id })
        else { return nil }
        return pick
    }

    /// The same question asked with ids, which is all some screens hold.
    ///
    /// An id the catalogue does not know — anything added through search — is
    /// counted as chat-only, the answer `dayAccess` gives anything nobody has
    /// checked. At worst that offers the recommendation to someone whose
    /// searched brain would have managed, which costs a dismissal; the other
    /// way round would hide the offer from someone who needs it.
    public static func offer(
        for budget: DeviceBudget,
        installedIDs: Set<String>,
        in catalog: [ModelRecord] = ModelCatalog.all
    ) -> ModelRecord? {
        let known = installedIDs.compactMap { id in
            catalog.first { $0.id == id } ?? ModelCatalog.model(withID: id)
        }
        guard !alreadyReadsYourDay(known),
              let pick = recommended(for: budget, in: catalog),
              !installedIDs.contains(pick.id)
        else { return nil }
        return pick
    }

    /// Smallest download first, id as the tie-break so the order is the same on
    /// every launch and every device.
    static func smallestFirst(_ lhs: ModelRecord, _ rhs: ModelRecord) -> Bool {
        lhs.totalDownloadBytes == rhs.totalDownloadBytes
            ? lhs.id < rhs.id
            : lhs.totalDownloadBytes < rhs.totalDownloadBytes
    }
}
