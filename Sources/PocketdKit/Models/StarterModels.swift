import Foundation

/// Which brain to put in front of someone who has never used the app.
///
/// Kept for the intro and the Brain screen, which call it by these names; the
/// rule itself lives in `BrainRecommendation`, and everything here is that one
/// rule seen from a screen that must not offer what is already installed.
///
/// History worth keeping: the first version picked the middle of the list by
/// download size, which on the 6 GB iPhone 14 this is developed against was
/// Llama 3.2 1B — a brain whose template has no notion of tools. The second
/// picked the *largest* tool-capable brain and fell back to a tight one, which
/// recommended a 3.1 GB Gemma 4 E2B on the simulator while the Brain screen
/// labelled the same file "Tight fit", and fell back to SmolLM2 on a small
/// phone — a chat-only brain that then printed its own instructions as the
/// brief. Neither can happen now: the recommendation reads your day, fits
/// comfortably where anything does, and is a few minutes to download.
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
    /// `limit` is honoured by keeping the smallest, which always includes the
    /// recommendation — it is chosen from the small end on purpose.
    public static func shortlist(
        in catalog: [ModelRecord] = ModelCatalog.all,
        budget: DeviceBudget,
        installed: Set<String> = [],
        limit: Int = 3
    ) -> [ModelRecord] {
        guard limit > 0 else { return [] }
        let list = BrainRecommendation.shortlist(for: budget, in: catalog, excluding: installed)
        guard list.count > limit else { return list }
        // The recommendation is the smallest comfortable brain under the
        // download ceiling or the largest below it, so it can sit anywhere in
        // the list; keep it, then fill from the small end.
        let pick = BrainRecommendation.recommended(for: budget, in: catalog)
        var kept = list.filter { $0.id == pick?.id }
        for model in list where kept.count < limit && !kept.contains(where: { $0.id == model.id }) {
            kept.append(model)
        }
        return kept.sorted(by: BrainRecommendation.smallestFirst)
    }
}
