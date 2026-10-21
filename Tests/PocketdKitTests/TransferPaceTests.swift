import Foundation
import Testing
@testable import PocketdKit

@Suite("Download progress, throttled and smoothed")
struct TransferPaceTests {

    @Test("at most five reports a second, whatever URLSession sends")
    func throttles() {
        var throttle = ProgressThrottle()
        let start = ContinuousClock.now
        var admitted = 0
        // Fifty callbacks a second for two seconds.
        for tick in 0..<100 {
            if throttle.admits(written: Int64(tick) * 1_000, expected: 10_000_000, at: start + .milliseconds(tick * 20)) {
                admitted += 1
            }
        }
        #expect(admitted <= 11, "two seconds at five a second, plus the first")
        #expect(admitted >= 9)
    }

    @Test("the first report and the finishing one always go through")
    func firstAndLast() {
        var throttle = ProgressThrottle()
        let start = ContinuousClock.now
        let first = throttle.admits(written: 1, expected: 100, at: start)
        let middle = throttle.admits(written: 50, expected: 100, at: start + .milliseconds(10))
        let last = throttle.admits(written: 100, expected: 100, at: start + .milliseconds(20))
        #expect(first)
        #expect(!middle)
        #expect(last, "the end is never dropped")
    }

    @Test("no rate is quoted before there is one worth quoting")
    func warmUp() {
        var pace = TransferPace()
        let start = Date()
        pace.observe(bytes: 0, at: start)
        pace.observe(bytes: 5_000_000, at: start.addingTimeInterval(1))
        #expect(pace.bytesPerSecond == nil)
        #expect(pace.secondsRemaining(received: 5_000_000, total: 100_000_000) == nil)
        pace.observe(bytes: 10_000_000, at: start.addingTimeInterval(2))
        #expect(pace.bytesPerSecond != nil)
    }

    @Test("a steady transfer gives a steady time left")
    func steady() throws {
        var pace = TransferPace()
        let start = Date()
        for second in 0...20 {
            pace.observe(bytes: Int64(second) * 5_000_000, at: start.addingTimeInterval(Double(second)))
        }
        let rate = try #require(pace.bytesPerSecond)
        #expect(abs(rate - 5_000_000) < 1)
        let left = try #require(pace.secondsRemaining(received: 100_000_000, total: 1_100_000_000))
        #expect(abs(left - 200) < 1)
    }

    @Test("jittery callbacks do not make the time left jump about")
    func jitter() throws {
        // The walkthrough's complaint: "about 11 min", then "about 39 min".
        // Bursts and stalls around a true 5 MB/s must keep the estimate near
        // the truth, not swing with every callback.
        var pace = TransferPace()
        let start = Date()
        var bytes: Int64 = 0
        var estimates: [Double] = []
        for step in 0..<120 {
            let seconds = Double(step) * 0.25
            // Alternate a burst (4× the rate) with three quarters of a stall.
            bytes += step % 4 == 0 ? 5_000_000 : 0
            pace.observe(bytes: bytes, at: start.addingTimeInterval(seconds))
            if seconds >= 10, let left = pace.secondsRemaining(received: bytes, total: bytes + 600_000_000) {
                estimates.append(left)
            }
        }
        let low = try #require(estimates.min())
        let high = try #require(estimates.max())
        #expect(high / low < 1.6, "the minutes shown should not swing by multiples")
        #expect(abs(estimates.last! - 120) < 40, "and it should be near the true two minutes")
    }

    @Test("a change of network is followed within seconds")
    func followsChange() throws {
        var pace = TransferPace()
        let start = Date()
        var bytes: Int64 = 0
        for second in 0..<20 {
            bytes += 5_000_000
            pace.observe(bytes: bytes, at: start.addingTimeInterval(Double(second)))
        }
        for second in 20..<40 {
            bytes += 1_000_000
            pace.observe(bytes: bytes, at: start.addingTimeInterval(Double(second)))
        }
        let rate = try #require(pace.bytesPerSecond)
        #expect(rate < 1_200_000, "twenty seconds after the drop the rate has followed it")
    }

    @Test("a resumed download measures only what arrives now")
    func resumed() throws {
        var pace = TransferPace()
        let start = Date()
        // 900 MB were already on disk.
        for second in 0...10 {
            pace.observe(bytes: 900_000_000 + Int64(second) * 2_000_000, at: start.addingTimeInterval(Double(second)))
        }
        let rate = try #require(pace.bytesPerSecond)
        #expect(abs(rate - 2_000_000) < 1)
    }

    @Test("the pre-download estimate is the size at ordinary Wi-Fi speed")
    func expected() {
        #expect(TransferPace.expectedSeconds(forBytes: 1_107_409_472) > 200)
        #expect(TransferPace.expectedSeconds(forBytes: 1_107_409_472) < 240)
    }
}
