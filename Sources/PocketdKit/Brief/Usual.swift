import Foundation

/// What "usual" means for one person, computed from their own numbers.
///
/// The median rather than the mean, everywhere, and that is the whole of this
/// type. Sleep and step counts are not normally distributed: one night awake
/// with a baby, one transatlantic flight, one day the phone stayed on the
/// kitchen table. A mean over fourteen days moves visibly for a single outlier,
/// so the sentence "a little under your usual" ends up comparing last night
/// against a fortnight that contained one bad night — and the app tells somebody
/// they slept badly on a night they slept fine.
///
/// A median needs one outlier per side to move at all, which is exactly the
/// robustness a personal baseline wants.
public enum Usual {

    /// A night shorter than this is not a night.
    ///
    /// Two hours, because HealthKit hands back what the device recorded, and
    /// what it records includes a watch worn for a nap, a band that lost contact
    /// at 3am and reported ninety minutes, and the fragment of a night either
    /// side of a time-zone change. Folding those into a baseline drags "usual"
    /// down towards them and makes a genuinely short night look ordinary.
    ///
    /// Deliberately not applied to the night being *compared*: if the user
    /// really did sleep ninety minutes, that is the number they want to see.
    /// This bound is about what counts as evidence of a habit.
    public static let shortestRealNight: TimeInterval = 2 * 3600

    /// How many nights a baseline is drawn from.
    ///
    /// Two weeks: long enough that a weekend does not define it, short enough
    /// that it still tracks somebody whose life changed last month. It is also
    /// what the Health app itself shows as a short-term average, so the two do
    /// not visibly disagree on the same screen.
    public static let baselineNights = 14

    /// The middle value, or the mean of the middle two.
    ///
    /// `nil` for an empty input rather than zero, because zero is a legitimate
    /// step count and "we have no baseline" has to be distinguishable from "your
    /// usual is nothing". Non-finite values are dropped rather than propagated:
    /// a single NaN from a division somewhere upstream would otherwise make the
    /// whole comparison NaN, and every comparison against NaN is false, so the
    /// tile would silently report "usual" for every value forever.
    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// How long this person normally sleeps.
    ///
    /// - Parameter nights: Durations in seconds, oldest first — the order
    ///   HealthKit queries return and the order the caller keeps them in. The
    ///   filter runs *before* the window, so fourteen real nights are used even
    ///   when the last fortnight also contains three naps; taking the last
    ///   fourteen entries first would let a run of naps shrink the baseline to
    ///   the handful of nights that survived it.
    public static func typicalSleep(_ nights: [TimeInterval]) -> TimeInterval? {
        median(Array(nights.filter { $0.isFinite && $0 >= shortestRealNight }.suffix(baselineNights)))
    }
}

/// Where a number sits against its own baseline.
///
/// Three cases rather than a signed difference, because the only consumer is a
/// sentence and a tile tint, and both want the band and not the arithmetic.
/// Handing a view the raw delta invites it to invent its own threshold, and then
/// the tile and the brief disagree about whether last night was short.
public enum Comparison: String, Sendable, Codable, Equatable, CaseIterable {
    case above, below, usual

    /// The band either side of the baseline that still counts as ordinary.
    ///
    /// Ten percent, which on a seven-hour baseline is about forty minutes. Any
    /// tighter and the brief remarks on the normal variation between a Tuesday
    /// and a Wednesday, every single day, which is how a daily message becomes
    /// noise people switch off.
    public static let defaultTolerance = 0.1

    /// - Parameter tolerance: A fraction of `usual`, not an absolute amount, so
    ///   the same band means the same thing for a six-hour sleeper and an
    ///   eight-hour one.
    ///
    /// A baseline of zero or one that is not a finite number answers `.usual`.
    /// There is no proportion of nothing, and the honest response to "we have no
    /// baseline" is to say nothing rather than to declare every value remarkable.
    public static func compare(_ value: Double, usual: Double, tolerance: Double = defaultTolerance) -> Comparison {
        guard value.isFinite, usual.isFinite, usual > 0 else { return .usual }
        let band = abs(usual) * abs(tolerance)
        if value > usual + band { return .above }
        if value < usual - band { return .below }
        return .usual
    }
}
