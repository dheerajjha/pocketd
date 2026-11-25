import Foundation

/// Which brain to put in front of someone who has never used the app.
///
/// Kept for the intro and the Brain screen, which call it by these names; the
/// rule itself lives in `BrainRecommendation`, and everything here is that one
/// rule seen from a screen that must not offer what is already installed.
public enum StarterModels {

    /// Everything the intro could offer this phone: brains that read your day
    /// and fit, nothing already on disk.
    public static func candidates(
        in catalog: [ModelRecord] = ModelCatalog.all,
        budget: DeviceBudget,
        installed: Set<String> = []
    ) -> [ModelRecord] {
        catalog
            .filter { BrainRecommendation.isRecommendable($0, for: budget) }
            .filter { !installed.contains($0.id) }
            .sorted(by: BrainRecommendation.smallestFirst)
    }

    /// The brain the intro should have selected when it opens, or `nil` when
    /// there is nothing to download.
    ///
    /// `BrainRecommendation.offer` with the installed ids looked up in the
    /// catalogue: `nil` when the recommendation is already here, when another
    /// brain that reads your day is, and when nothing that reads your day fits
    /// this phone. The intro tells those apart by whether anything is
    /// installed.
    public static func recommended(
        in catalog: [ModelRecord] = ModelCatalog.all,
        budget: DeviceBudget,
        installed: Set<String> = []
    ) -> ModelRecord? {
        BrainRecommendation.offer(for: budget, installedIDs: installed, in: catalog)
    }

    /// The brains worth listing under "Recommended": every one reads your day.
    ///
    /// Keep the recommendation if it is not installed, then fill the remaining
    /// places with the smallest downloads. The measured starter need not be the smallest.
    public static func shortlist(
        in catalog: [ModelRecord] = ModelCatalog.all,
        budget: DeviceBudget,
        installed: Set<String> = [],
        limit: Int = 3
    ) -> [ModelRecord] {
        guard limit > 0 else { return [] }
        let list = BrainRecommendation.shortlist(for: budget, in: catalog, excluding: installed)
        guard list.count > limit else { return list }
        let pick = BrainRecommendation.recommended(for: budget, in: catalog)
        var kept = list.filter { $0.id == pick?.id }
        for model in list where kept.count < limit && !kept.contains(where: { $0.id == model.id }) {
            kept.append(model)
        }
        return kept.sorted(by: BrainRecommendation.smallestFirst)
    }
}
