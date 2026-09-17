import Foundation
import Testing
@testable import PocketdKit

/// What "your usual" is allowed to mean.
///
/// The tests that matter here are the ones about outliers, because the whole
/// reason this is a median and not a mean is one bad night. A baseline that
/// moves for a single transatlantic flight tells somebody they slept badly on a
/// night they slept fine, in a sentence they read before they are properly
/// awake, every morning for a fortnight afterwards.
@Suite("Usual and comparison")
struct UsualTests {

    func hours(_ value: Double) -> TimeInterval { value * 3600 }

    // MARK: - Median

    @Test("an odd count takes the middle and an even one splits the difference")
    func medianBasics() {
        #expect(Usual.median([3, 1, 2]) == 2)
        #expect(Usual.median([4, 1, 3, 2]) == 2.5)
        #expect(Usual.median([7]) == 7)
    }

    @Test("no numbers means no baseline, not a baseline of zero")
    func medianOfNothing() {
        // Zero is a legitimate step count. "We have no baseline" has to be
        // distinguishable from "your usual is nothing", or the first day with
        // Health connected reports every reading as extraordinary.
        #expect(Usual.median([]) == nil)
        #expect(Usual.median([0, 0, 0]) == 0)
    }

    @Test("one absurd value does not move the answer")
    func medianResistsOutliers() {
        let ordinary = [6.0, 7.0, 7.5, 7.0, 6.5]
        let withOneDisaster = ordinary + [0.5]
        // A mean would fall by nearly an hour. The median moves by a quarter of
        // one, which is the robustness a personal baseline wants.
        let before = Usual.median(ordinary)!
        let after = Usual.median(withOneDisaster)!
        #expect(abs(after - before) < 0.5)
    }

    @Test("a stray NaN is dropped rather than poisoning the result")
    func nonFiniteValuesAreIgnored() {
        // Every comparison against NaN is false, so a single one surviving into
        // the median would make `Comparison.compare` answer `.usual` for every
        // value, forever, with nothing on screen to say why.
        #expect(Usual.median([1, .nan, 3]) == 2)
        #expect(Usual.median([.nan, .infinity]) == nil)
    }

    // MARK: - Typical sleep

    @Test("naps are not nights")
    func shortRecordingsAreExcluded() {
        // A watch worn for an afternoon nap, or a band that lost contact at 3am,
        // drags "usual" down towards itself and makes a genuinely short night
        // look ordinary.
        let nights = [hours(7), hours(0.75), hours(7), hours(1.5), hours(7)]
        #expect(Usual.typicalSleep(nights) == hours(7))
    }

    @Test("the baseline is drawn from the last fourteen real nights")
    func windowIsFourteen() {
        // Twenty nights of five hours, then fourteen of eight. The old five-hour
        // fortnight has to be out of the window entirely.
        let nights = Array(repeating: hours(5), count: 20) + Array(repeating: hours(8), count: 14)
        #expect(Usual.typicalSleep(nights) == hours(8))
    }

    @Test("the window counts real nights, not entries")
    func napsDoNotConsumeTheWindow() {
        // Fourteen good nights followed by a week of naps. Taking the last
        // fourteen *entries* first would leave a baseline computed from seven
        // nights; filtering first keeps all fourteen.
        let nights = Array(repeating: hours(8), count: 14) + Array(repeating: hours(1), count: 7)
        #expect(Usual.typicalSleep(nights) == hours(8))
    }

    @Test("nothing usable means no usual")
    func noNightsMeansNil() {
        #expect(Usual.typicalSleep([]) == nil)
        #expect(Usual.typicalSleep([hours(0.5), hours(1.2)]) == nil)
    }

    // MARK: - Comparison

    @Test("ordinary variation is not worth remarking on")
    func toleranceBand() {
        let usual = hours(7)
        // Ten percent of seven hours is about forty minutes. Half an hour either
        // side is the difference between a Tuesday and a Wednesday, and an app
        // that mentions it daily is an app people mute.
        #expect(Comparison.compare(hours(7.4), usual: usual) == .usual)
        #expect(Comparison.compare(hours(6.6), usual: usual) == .usual)
        #expect(Comparison.compare(hours(5.5), usual: usual) == .below)
        #expect(Comparison.compare(hours(9), usual: usual) == .above)
    }

    @Test("the band is a proportion, so it means the same to every sleeper")
    func toleranceIsRelative() {
        // Forty minutes short of eight hours is ordinary; forty minutes short of
        // four is not. An absolute band cannot express both.
        #expect(Comparison.compare(hours(7.4), usual: hours(8)) == .usual)
        #expect(Comparison.compare(hours(3.4), usual: hours(4)) == .below)
    }

    @Test("a tighter tolerance can be asked for")
    func customTolerance() {
        #expect(Comparison.compare(105, usual: 100, tolerance: 0.1) == .usual)
        #expect(Comparison.compare(105, usual: 100, tolerance: 0.01) == .above)
    }

    @Test("with no baseline nothing is remarkable")
    func noBaselineIsNotAComparison() {
        // There is no proportion of nothing, and declaring every value
        // extraordinary is the worse of the two possible wrong answers.
        #expect(Comparison.compare(500, usual: 0) == .usual)
        #expect(Comparison.compare(500, usual: .nan) == .usual)
        #expect(Comparison.compare(.nan, usual: 100) == .usual)
    }
}
