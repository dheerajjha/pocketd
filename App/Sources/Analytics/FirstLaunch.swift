import Foundation

/// Whether this launch is the first one this install has ever had.
///
/// Ours rather than Mixpanel's `$ae_first_open`, which is the reason automatic
/// events are off in `MixpanelAnalytics`: that event fires on the first launch
/// after the SDK was *added*, not on the first launch of the install, so every
/// existing user updating into the build that introduced analytics would arrive
/// as a brand new one. The cold-start funnel would open with a spike made
/// entirely of people who have had the app for months, and nothing in the data
/// would say so.
///
/// Writing our own flag does not escape that problem by itself — the key is
/// missing for an upgrader too, and a missing key looks exactly like a fresh
/// install. `evidenceOfPriorUse` is how the caller closes the gap: it passes
/// something the previous build left behind, and the only honest reading of
/// such a trace is that this install has been used before.
enum FirstLaunch {
    /// Namespaced under analytics rather than filed with `AppModel.Keys`,
    /// because it is not app state: nothing outside this answer reads it, and
    /// a key that looks like a preference invites someone to clear it.
    private static let key = "pocketd.analytics.hasLaunchedBefore"

    /// Returns true at most once per install, and writes the flag that makes
    /// every later call false.
    ///
    /// Read and write in one call on purpose. Split into "ask" and "mark", the
    /// window between them is a launch that crashed before marking — and the
    /// next launch would then be counted as a first one too, which is the one
    /// way this number can be wrong that nobody would ever notice.
    ///
    /// The flag is consumed whether or not anything is transmitted, including
    /// in a build where the SDK is not linked at all. That is the right way
    /// round: an install that launched has launched, and making the count
    /// depend on which packages a particular build happened to include would
    /// make it a fact about the build rather than about the person.
    static func claim(evidenceOfPriorUse: Bool, defaults: UserDefaults = .standard) -> Bool {
        let launchedBefore = defaults.bool(forKey: key)
        defaults.set(true, forKey: key)
        return !launchedBefore && !evidenceOfPriorUse
    }
}
