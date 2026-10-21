import Foundation

/// How often a download says how far it has got.
///
/// URLSession calls back for every chunk it writes — dozens of times a second
/// on Wi-Fi — and every callback used to travel all the way up: a new
/// `transfers` value, a re-render of the banner, the brief card and the intro,
/// and an ActivityKit update for the Live Activity, which iOS rate-limits and
/// then starts dropping. Nobody reads a percentage that changes forty times a
/// second. Five a second is smooth to watch and costs nothing.
///
/// The first report and the last always go through: the first is what turns
/// "Starting…" into a bar, and the last is the one a finished download is
/// judged by.
public struct ProgressThrottle: Sendable, Equatable {
    public static let defaultInterval: Duration = .milliseconds(200)

    public var minimumInterval: Duration
    private var lastReport: ContinuousClock.Instant?

    public init(minimumInterval: Duration = defaultInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Whether this callback should be passed on, recording it if so.
    public mutating func admits(written: Int64, expected: Int64, at now: ContinuousClock.Instant = .now) -> Bool {
        let finished = expected > 0 && written >= expected
        if let last = lastReport, !finished, now - last < minimumInterval {
            return false
        }
        lastReport = now
        return true
    }
}

/// A download's speed, smoothed so the time left can be read.
///
/// The instantaneous rate — bytes since the last callback over the time since
/// it — swings by an order of magnitude between callbacks, and a time left
/// computed from it flickers between "2 min" and "40 min". The walkthrough
/// watched one go from "about 11 min" to "about 39 min" and back. This is an
/// exponentially weighted average over roughly the last `timeConstant`
/// seconds: slow enough to read, quick enough to follow a real change of
/// network within a few seconds.
///
/// It also refuses to guess. Until a couple of seconds of transfer have been
/// seen there is no rate, and a caller shows the size instead of a time it
/// would have to take back.
public struct TransferPace: Sendable, Equatable {
    /// Roughly how far back the average looks.
    public var timeConstant: TimeInterval
    /// How much transfer has to be seen before a rate is quoted.
    public var warmUp: TimeInterval

    private var started: Date?
    private var startBytes: Int64 = 0
    private var lastAt: Date?
    private var lastBytes: Int64 = 0
    private var smoothed: Double?

    public init(timeConstant: TimeInterval = 6, warmUp: TimeInterval = 2) {
        self.timeConstant = timeConstant
        self.warmUp = warmUp
    }

    /// Records the cumulative byte count at `date`. A resumed download starts
    /// from whatever was already on disk; only what arrives from here counts.
    public mutating func observe(bytes: Int64, at date: Date) {
        guard let previous = lastAt, let started else {
            started = date
            startBytes = bytes
            lastAt = date
            lastBytes = bytes
            return
        }
        let elapsed = date.timeIntervalSince(previous)
        guard elapsed > 0 else { return }
        let sinceStart = date.timeIntervalSince(started)
        if sinceStart <= warmUp || smoothed == nil {
            // Seeded with the plain average over the first seconds rather than
            // with whichever callback happened to come first, which is either a
            // burst or a stall and nothing like the truth.
            smoothed = Double(max(0, bytes - startBytes)) / sinceStart
        } else {
            let instant = Double(max(0, bytes - lastBytes)) / elapsed
            // Weight by time, not by callback: ten callbacks in a burst count
            // for as long as they took, not ten times over.
            let weight = 1 - exp(-elapsed / timeConstant)
            smoothed = smoothed.map { $0 + weight * (instant - $0) }
        }
        lastAt = date
        lastBytes = bytes
    }

    /// Bytes per second, or `nil` until enough has been seen to say.
    public var bytesPerSecond: Double? {
        guard let started, let lastAt, lastAt.timeIntervalSince(started) >= warmUp,
              let smoothed, smoothed > 0
        else { return nil }
        return smoothed
    }

    /// Seconds left at the smoothed rate, or `nil` when there is no rate yet.
    public func secondsRemaining(received: Int64, total: Int64) -> TimeInterval? {
        guard total > received, let rate = bytesPerSecond else { return total > 0 && received >= total ? 0 : nil }
        return Double(total - received) / rate
    }

    /// A pre-download estimate: what "about 4 min on Wi-Fi" means. Five
    /// megabytes a second is ordinary home Wi-Fi rather than a good day on it,
    /// so the number errs long.
    public static let assumedWiFiBytesPerSecond: Double = 5_000_000

    public static func expectedSeconds(forBytes bytes: Int64, bytesPerSecond: Double = assumedWiFiBytesPerSecond) -> TimeInterval {
        Double(max(0, bytes)) / max(1, bytesPerSecond)
    }
}
