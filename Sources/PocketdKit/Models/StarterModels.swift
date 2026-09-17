import Foundation

/// Which model to put in front of someone who has never used the app.
///
/// A pure function of the catalogue and the device budget, in the Kit rather
/// than in the onboarding screen, because it is a rule about memory and
/// capability rather than a rule about layout — and because the version that
/// lived in the view could not be tested against a 4 GB phone without a 4 GB
/// phone.
///
/// The rule it replaces picked the middle of the list by download size. On the
/// primary test device — a 6 GB iPhone 14 — that middle was Llama 3.2 1B, whose
/// chat template has no notion of tools: the first thing the app recommends
/// could not work the calendar, the reminders or the health questions that are
/// the reason to install it. Size is the wrong axis to sort a first impression
/// by.
public enum StarterModels {

    /// Everything this phone could actually be offered: no vision models (the
    /// intro has no camera in it and the projector doubles the download), and
    /// nothing already on disk, so a replay from Settings does not offer to
    /// fetch what has been here for weeks.
    public static func candidates(
        in catalog: [ModelRecord] = ModelCatalog.all,
        budget: DeviceBudget,
        installed: Set<String> = []
    ) -> [ModelRecord] {
        catalog
            .filter { !$0.declaredCapabilities.vision.isYes }
            .filter { !installed.contains($0.id) }
            .filter { budget.fit(for: $0).isDownloadable }
            .sorted { ordered($0, $1) }
    }

    /// The one the intro should have selected when it opens.
    ///
    /// In order:
    ///
    /// 1. The **largest tool-capable model that fits comfortably**. Tool-capable
    ///    first because an assistant that cannot call a tool is a different,
    ///    smaller product than the one being introduced; largest second because
    ///    the download is paid once and the capability is used every day.
    /// 2. If nothing tool-capable is comfortable, the largest tool-capable model
    ///    that fits at all. A `.tight` Qwen3 1.7B is a better first model than a
    ///    comfortable 360M that can only chat — and the badge still says tight.
    /// 3. If the phone cannot hold anything tool-capable, the largest model that
    ///    fits, whatever it is. This is the only route by which SmolLM2 360M is
    ///    ever recommended, which is the point: it is what a phone gets when
    ///    nothing better will load, not a default.
    /// 4. `nil` when nothing fits at all, which the caller must handle — an
    ///    intro that offers a download it has already refused is worse than an
    ///    intro that says this phone is too small.
    ///
    /// `.unknown` tool support does not count as capable. It is the honest
    /// state for a model nobody has checked, the capability gate treats it as
    /// unusable, and recommending on the strength of a maybe is how someone
    /// concludes the feature is broken.
    public static func recommended(
        in catalog: [ModelRecord] = ModelCatalog.all,
        budget: DeviceBudget,
        installed: Set<String> = []
    ) -> ModelRecord? {
        let pool = candidates(in: catalog, budget: budget, installed: installed)
        let toolCapable = pool.filter { $0.toolSupport.isYes }

        if let best = toolCapable.last(where: { budget.fit(for: $0) == .comfortable }) { return best }
        if let best = toolCapable.last { return best }
        return pool.last
    }

    /// Up to `limit` models spanning what this phone can hold, the recommended
    /// one among them.
    ///
    /// Comfortable entries only, unless nothing is comfortable — on a small
    /// device an honest "tight" beats an empty screen with nothing to choose.
    /// Where there are more than `limit`, the smallest, the middle and the
    /// largest: the choice being offered is "how much of this phone do you want
    /// to spend", and three points make that legible where eight would not.
    ///
    /// The recommendation is always in the list. It is not always comfortable —
    /// on a 4 GB phone the only tool-capable model that loads is tight — and a
    /// list that excluded it would leave the intro selecting a row that is not
    /// on screen.
    public static func shortlist(
        in catalog: [ModelRecord] = ModelCatalog.all,
        budget: DeviceBudget,
        installed: Set<String> = [],
        limit: Int = 3
    ) -> [ModelRecord] {
        let pool = candidates(in: catalog, budget: budget, installed: installed)
        guard !pool.isEmpty, limit > 0 else { return [] }

        let comfortable = pool.filter { budget.fit(for: $0) == .comfortable }
        let span = comfortable.isEmpty ? pool : comfortable

        var chosen: [ModelRecord]
        if span.count <= limit {
            chosen = span
        } else if limit == 3 {
            chosen = [span[0], span[span.count / 2], span[span.count - 1]]
        } else {
            chosen = Array(span.prefix(limit))
        }

        if let pick = recommended(in: catalog, budget: budget, installed: installed),
           !chosen.contains(where: { $0.id == pick.id }) {
            // Replace the middle rather than append once the list is full: the
            // two ends are the two ends of what this phone can do, and dropping
            // either loses the range the list exists to show.
            if chosen.count >= limit {
                chosen[chosen.count / 2] = pick
            } else {
                chosen.append(pick)
            }
        }

        return chosen.sorted { ordered($0, $1) }
    }

    /// Smallest download first, id as the tie-break so the order is the same on
    /// every launch and every device.
    private static func ordered(_ lhs: ModelRecord, _ rhs: ModelRecord) -> Bool {
        lhs.totalDownloadBytes == rhs.totalDownloadBytes
            ? lhs.id < rhs.id
            : lhs.totalDownloadBytes < rhs.totalDownloadBytes
    }
}
