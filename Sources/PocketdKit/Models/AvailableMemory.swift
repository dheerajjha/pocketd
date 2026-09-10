import Foundation
#if canImport(os)
import os
#endif

/// What the kernel says is left, rather than what the device shipped with.
///
/// `os_proc_available_memory()` returns the bytes this process may still dirty
/// before jetsam kills it. It is the number iOS actually enforces.
/// `ProcessInfo.physicalMemory` is not that number and never was: it is the
/// machine's RAM, roughly double what one app is allowed to touch, and the
/// fraction `DeviceBudget` multiplies it by is a guess nobody on this project
/// has ever checked against a device.
///
/// Wrapped in a closure rather than called directly because the symbol does not
/// exist everywhere. It is `API_UNAVAILABLE(macos)`, and this package builds and
/// tests on macOS — a direct call would not compile the test suite.
public struct AvailableMemory: Sendable {
    private let reading: @Sendable () -> Int64?

    public init(reading: @escaping @Sendable () -> Int64?) {
        self.reading = reading
    }

    /// Bytes still allocatable, or `nil` when there is no answer to be had.
    ///
    /// The distinction matters more than it looks. `os_proc_available_memory()`
    /// documents 0 as "the calling process is not an app, **or** the calling
    /// process exceeds its memory limit" — neither of which means "you have no
    /// memory". Reading a 0 as a real ceiling would refuse every model in the
    /// simulator, and on a device it would refuse everything at exactly the
    /// moment the app is already over its limit and least able to explain why.
    public var bytes: Int64? { reading() }

    /// The live kernel reading.
    ///
    /// Returns `nil` on the simulator. Measured on an iPhone 17 running iOS
    /// 26.5: a real, installed, launched app bundle gets 0 back, because a
    /// simulated process has no dirty-memory limit to have bytes remaining
    /// against — the simulator is a macOS process wearing the host's 34 GB.
    /// So calibration only ever happens on hardware, and the simulator keeps
    /// falling back to the fraction. That is the correct outcome: there is no
    /// jetsam in the simulator to protect anyone from.
    public static let system = AvailableMemory {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let remaining = os_proc_available_memory()
        return remaining > 0 ? Int64(remaining) : nil
        #else
        return nil
        #endif
    }

    /// No reading at all — what every non-iOS build gets, and what a test uses
    /// to exercise the cold-start path deliberately.
    public static let unavailable = AvailableMemory { nil }

    /// A fixed reading, for tests that need the ratchet to see a known number.
    public static func fixed(_ bytes: Int64) -> AvailableMemory {
        AvailableMemory { bytes }
    }
}

/// The device's memory ceiling as learned from actually running here.
///
/// Two signals, persisted, and they are not the same kind of claim:
///
/// - `largestSuccessfulLoadBytes` is a **proof**. A model of this estimated
///   size was loaded on this device and the kernel did not object. There is no
///   honest reason to ever lower it: the hardware, the OS and the entitlement
///   that made it possible have not changed.
/// - `availableMemoryCeilingBytes` is a **snapshot** of
///   `os_proc_available_memory()` taken in the clean state — at launch, and
///   after each context release, when this process is holding the least it ever
///   holds and the reading is at its most favourable.
///
/// Both only ever ratchet upward, which is PocketPal's rule
/// (`src/store/ModelStore.ts`) and is deliberately optimistic.
///
/// ## Why ratchet rather than decay, in an app that is also a server
///
/// The tempting objection is that a running maximum of a noisy snapshot is
/// biased high by construction and never corrects, and that this app cannot
/// afford optimism: a jetsam kill in a chat app is a relaunch the user watches
/// happen, whereas a jetsam kill here silently drops a laptop's connection
/// mid-answer while the phone sits in another room. That asymmetry is real.
///
/// Decay is still the wrong fix, for two reasons.
///
/// The first is that decay solves a problem this does not have. The snapshot is
/// not sampled at random moments; it is sampled only in the clean state, so its
/// variance is bounded by how much of this app's own baseline happened to be
/// dirty at the time — a conversation buffer and a request log, tens of
/// megabytes against a multi-gigabyte model. The maximum of that is not runaway
/// optimism, it is the reading with our own baseline subtracted out, which is
/// closer to the truth than any single sample.
///
/// The second is that the actual danger is not staleness, it is that a clean
/// state measurement is being used to gate a load that will not happen in a
/// clean state. That is answered directly and deterministically by never
/// spending the last of the snapshot — see `loadReserveBytes` — not on average
/// by an exponential. And a decaying ceiling makes the gate irreproducible: the
/// same model fits on Tuesday and not on Friday, with nothing the user changed
/// to explain it. For something a laptop talks to unattended, an answer that is
/// slightly conservative every time beats one that is right on average.
///
/// So: ratchet the proof outright, ratchet the snapshot but hold a reserve back
/// from it, and let `DeviceBudget` cap the result at the machine's own RAM so a
/// corrupt stored value or an overstated catalogue size cannot invent memory
/// that does not exist.
// UserDefaults is thread-safe but not marked Sendable, so the conformance is
// unchecked rather than absent — the same trade `ServerConfigurationStore`
// makes, and for the same reason.
public struct MemoryCalibration: @unchecked Sendable {

    /// Held back from the observed ceiling, never from a proven load.
    ///
    /// The snapshot is taken with nothing loaded. By the time a model is
    /// loaded, this process is also holding a conversation, the HTTP server's
    /// buffers and a request log, and llama.cpp's own peak during load runs
    /// above its steady state. Spending 100% of a clean-state reading means
    /// arriving at the kill line exactly, which is what `Fit.tight` would then
    /// be quietly promising.
    ///
    /// 256 MB because that is the order of the drift — roughly one long
    /// conversation plus one compute buffer — and because it is small against
    /// the multi-gigabyte models it gates. A proven load needs no such reserve:
    /// it already happened, with all of that already resident.
    public static let loadReserveBytes: Int64 = 256 * 1024 * 1024

    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "pocketd.memory") {
        self.defaults = defaults
        self.prefix = keyPrefix
    }

    public static let standard = MemoryCalibration()

    private var successKey: String { "\(prefix).largestSuccessfulLoad" }
    private var ceilingKey: String { "\(prefix).availableCeiling" }

    /// The biggest estimate that has actually loaded here. `nil` until one has.
    public var largestSuccessfulLoadBytes: Int64? { stored(successKey) }

    /// The most memory ever seen free in the clean state. `nil` on a device
    /// that has never produced a reading — every simulator, and every launch
    /// before the first one lands.
    public var availableMemoryCeilingBytes: Int64? { stored(ceilingKey) }

    /// What this device has been shown to be good for, or `nil` on a cold
    /// start with nothing learned yet — which is the signal `DeviceBudget`
    /// uses to fall back to its fraction.
    public var ceilingBytes: Int64? {
        let proven = largestSuccessfulLoadBytes
        let observed = availableMemoryCeilingBytes.map { max(0, $0 - Self.loadReserveBytes) }
        switch (proven, observed) {
        case let (proven?, observed?): return max(proven, observed)
        case let (proven?, nil): return proven
        case let (nil, observed?): return observed
        case (nil, nil): return nil
        }
    }

    /// Records that a model whose estimate was `estimatedBytes` loaded here.
    ///
    /// Only ever widens. A failure deliberately records nothing: a load can
    /// fail for a corrupt file, a missing projector or a llama.cpp refusal, and
    /// narrowing the ceiling on every one of those would let a bad GGUF
    /// permanently convince the app the phone is smaller than it is.
    @discardableResult
    public func recordSuccessfulLoad(estimatedBytes: Int64) -> Int64? {
        ratchet(successKey, to: estimatedBytes)
    }

    /// Records a clean-state reading. Call it where nothing is loaded — at
    /// launch and after a context release — because that is when the number is
    /// worth keeping. `nil` is a no-op, which is what every non-iOS build and
    /// every simulator passes.
    @discardableResult
    public func recordAvailableMemory(_ bytes: Int64?) -> Int64? {
        guard let bytes else { return availableMemoryCeilingBytes }
        return ratchet(ceilingKey, to: bytes)
    }

    /// Throws away everything learned. Exists for tests and for a Reset
    /// control; a ratchet with no way back is a ratchet you cannot debug.
    public func forget() {
        defaults.removeObject(forKey: successKey)
        defaults.removeObject(forKey: ceilingKey)
    }

    /// Reads as `NSNumber` rather than `Int` so a value written by a build that
    /// stored it differently still parses, and treats anything non-positive as
    /// absent — a stored zero is the shape a failed reading leaves behind, not
    /// a device with no memory.
    private func stored(_ key: String) -> Int64? {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
        let value = number.int64Value
        return value > 0 ? value : nil
    }

    @discardableResult
    private func ratchet(_ key: String, to candidate: Int64) -> Int64? {
        guard candidate > 0 else { return stored(key) }
        guard let existing = stored(key) else {
            defaults.set(candidate, forKey: key)
            return candidate
        }
        guard candidate > existing else { return existing }
        defaults.set(candidate, forKey: key)
        return candidate
    }
}
