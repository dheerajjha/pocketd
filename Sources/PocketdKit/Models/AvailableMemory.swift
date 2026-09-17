import Foundation
#if canImport(os)
import os
#endif

/// What the kernel says is left for this process at this instant.
///
/// `os_proc_available_memory()` returns the bytes this process may still dirty
/// before jetsam kills it. It is the number iOS actually enforces, and it is
/// the answer to "is there room right now" — not to "does this model fit on
/// this phone". It drops by the size of whatever is resident, so a fit verdict
/// computed from it falls every time the app successfully loads something,
/// which is how a Models screen came to label the running model too large to
/// run. `DeviceBudget.pressure` is where this belongs; `DeviceBudget.fit(for:)`
/// deliberately cannot see it.
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
    /// `nil` on the simulator, by construction rather than by luck. A simulated
    /// process is a macOS process wearing the host's RAM and has no
    /// dirty-memory limit to have bytes remaining against, so whatever the
    /// symbol returns there describes a Mac under load and nothing else. It was
    /// believed once — 15.46 GB on a fresh launch, 683.8 MB after one model —
    /// and every badge on the Models screen moved with it. There is no jetsam
    /// in the simulator to protect anyone from, so there is nothing here to
    /// read.
    public static let system = AvailableMemory {
        #if targetEnvironment(simulator)
        return nil
        #elseif os(iOS) || os(tvOS) || os(watchOS)
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

/// What running here has actually taught the app, persisted across launches.
///
/// Two signals, and they are not the same kind of claim. Keeping them in one
/// number is what broke the fit badge, so they are kept apart here and consumed
/// separately by `DeviceBudget`:
///
/// - `largestSuccessfulLoadBytes` is a **proof**. A model of this estimated
///   size was loaded on this device and the kernel did not object. There is no
///   honest reason to ever lower it: the hardware, the OS and the entitlement
///   that made it possible have not changed. It is a *floor* under
///   `DeviceBudget.usableBytes` and never a ceiling on it — a phone that has
///   loaded a 700 MB model has not thereby proved it cannot load a 2 GB one,
///   and reading it that way is precisely how the Models screen came to say
///   "683.8 MB usable, everything too large" after a single small model.
/// - `availableMemoryCeilingBytes` is a **snapshot** of
///   `os_proc_available_memory()` taken in the clean state — at launch, and
///   after each context release. It is a diagnostic: the best this process has
///   ever had free. It decides no verdict. Anything that wants to know about
///   memory *right now* reads `DeviceBudget.pressure`, which is a live value
///   and does not pretend to be a property of the device.
///
/// Both only ever ratchet upward, which is PocketPal's rule
/// (`src/store/ModelStore.ts`).
///
/// ## Why ratchet rather than decay
///
/// The tempting objection is that a running maximum of a noisy snapshot is
/// biased high by construction and never corrects, and that this app cannot
/// afford optimism: a jetsam kill in a chat app is a relaunch the user watches
/// happen, whereas a jetsam kill here silently drops a laptop's connection
/// mid-answer while the phone sits in another room. That asymmetry is real.
///
/// It is also no longer load-bearing, because neither of these numbers can
/// narrow what the app is willing to attempt. The decay argument was really an
/// argument about a clean-state measurement being used to gate a load that will
/// not happen in a clean state — and the answer to that is not an exponential,
/// it is not gating on a live measurement at all. The gate is now arithmetic on
/// physical RAM, which is reproducible: the same model fits on Tuesday and on
/// Friday, and when it does not, something the user changed explains it.
// UserDefaults is thread-safe but not marked Sendable, so the conformance is
// unchecked rather than absent — the same trade `ServerConfigurationStore`
// makes, and for the same reason.
public struct MemoryCalibration: @unchecked Sendable {

    /// Held back from a live reading before any of it is called room.
    ///
    /// By the time a model is loaded, this process is also holding a
    /// conversation, the HTTP server's buffers and a request log, and
    /// llama.cpp's own peak during load runs above its steady state. Treating
    /// the last of a reading as spendable means arriving at the kill line
    /// exactly.
    ///
    /// 256 MB because that is the order of the drift — roughly one long
    /// conversation plus one compute buffer. It is the threshold
    /// `DeviceBudget.pressure` calls critical, and it is deliberately not
    /// subtracted from the fit budget: that budget is a fraction of physical
    /// RAM, the fraction is already the conservative allowance, and taking a
    /// further quarter-gigabyte off it would move rows in the README's table
    /// without making any phone safer.
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
    ///
    /// This is the one signal `DeviceBudget` reads, and it reads it as a floor.
    public var largestSuccessfulLoadBytes: Int64? { stored(successKey) }

    /// The most memory ever seen free in the clean state. `nil` on a device
    /// that has never produced a reading — every simulator, and every launch
    /// before the first one lands.
    ///
    /// A diagnostic. Nothing decides a fit verdict from it: it is a
    /// clean-state number, every load happens in a state that is not clean, and
    /// the two signals used to be averaged into one "ceiling" that a single
    /// small model could drag the whole Models screen down with.
    public var availableMemoryCeilingBytes: Int64? { stored(ceilingKey) }

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

    /// True once a model has loaded here.
    public var hasProvenLoad: Bool { largestSuccessfulLoadBytes != nil }

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
