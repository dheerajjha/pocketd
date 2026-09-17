import Foundation
import Testing
@testable import PocketdKit

/// The calibration is the part worth testing, because it is the part that is
/// deliberately optimistic. A ratchet that quietly forgets, or that lets a
/// failed load narrow the ceiling, would fail silently and look fine.
@Suite("Memory calibration")
struct MemoryCalibrationTests {

    /// Its own defaults domain per test. `MemoryCalibration.standard` writes to
    /// the shared suite, and a test suite that leaves numbers there would make
    /// every later run start from a different device.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "pocketd.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private let gigabyte: Int64 = 1024 * 1024 * 1024

    // MARK: The ratchet

    @Test("a successful load only ever widens the ceiling")
    func successRatchets() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)

            calibration.recordSuccessfulLoad(estimatedBytes: 2 * gigabyte)
            #expect(calibration.largestSuccessfulLoadBytes == 2 * gigabyte)

            calibration.recordSuccessfulLoad(estimatedBytes: 3 * gigabyte)
            #expect(calibration.largestSuccessfulLoadBytes == 3 * gigabyte)

            // The one that matters: a smaller model loading afterwards is not
            // evidence that the bigger one stopped fitting.
            calibration.recordSuccessfulLoad(estimatedBytes: gigabyte)
            #expect(calibration.largestSuccessfulLoadBytes == 3 * gigabyte)
        }
    }

    @Test("a clean-state reading only ever widens the ceiling")
    func readingRatchets() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)

            calibration.recordAvailableMemory(4 * gigabyte)
            calibration.recordAvailableMemory(2 * gigabyte)
            #expect(calibration.availableMemoryCeilingBytes == 4 * gigabyte,
                    "a reading taken under pressure is not a smaller device")

            calibration.recordAvailableMemory(5 * gigabyte)
            #expect(calibration.availableMemoryCeilingBytes == 5 * gigabyte)
        }
    }

    @Test("nothing is recorded from a reading that does not exist")
    func absentReadingIsNotZero() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)

            calibration.recordAvailableMemory(nil)
            #expect(calibration.availableMemoryCeilingBytes == nil)

            // `os_proc_available_memory()` documents 0 as "not an app, or
            // already over the limit". Storing it would tell the app this
            // device has no memory, permanently.
            calibration.recordAvailableMemory(0)
            #expect(calibration.availableMemoryCeilingBytes == nil)

            calibration.recordAvailableMemory(3 * gigabyte)
            calibration.recordAvailableMemory(0)
            #expect(calibration.availableMemoryCeilingBytes == 3 * gigabyte)
        }
    }

    @Test("survives the process that learned it")
    func persists() {
        withDefaults { defaults in
            MemoryCalibration(defaults: defaults).recordSuccessfulLoad(estimatedBytes: 3 * gigabyte)
            MemoryCalibration(defaults: defaults).recordAvailableMemory(6 * gigabyte)

            // A fresh instance over the same store is what the next launch gets.
            let relaunched = MemoryCalibration(defaults: defaults)
            #expect(relaunched.largestSuccessfulLoadBytes == 3 * gigabyte)
            #expect(relaunched.availableMemoryCeilingBytes == 6 * gigabyte)
        }
    }

    // Was "holds a reserve back from an observed ceiling but not from a proven
    // load", asserting a single `ceilingBytes` that merged the two. That merge
    // is the bug: it let one small successful load define the whole device's
    // ceiling. The reserve still exists, as the pressure threshold, and the two
    // signals are now readable only one at a time.
    @Test("the proof and the snapshot stay separate signals")
    func signalsDoNotMerge() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)

            calibration.recordAvailableMemory(4 * gigabyte)
            #expect(calibration.availableMemoryCeilingBytes == 4 * gigabyte)
            #expect(calibration.largestSuccessfulLoadBytes == nil,
                    "a reading is not a load; nothing has been proven yet")

            calibration.recordSuccessfulLoad(estimatedBytes: 2 * gigabyte)
            #expect(calibration.largestSuccessfulLoadBytes == 2 * gigabyte)
            #expect(calibration.availableMemoryCeilingBytes == 4 * gigabyte,
                    "proving a load says nothing about how much was free")
        }
    }

    // MARK: What the budget does with it

    @Test("a cold start with nothing learned still answers, from the fraction")
    func coldStart() throws {
        try withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            #expect(calibration.hasProvenLoad == false, "nothing has been learned yet")

            let budget = DeviceBudget(
                physicalMemoryBytes: 6 * gigabyte,
                hasIncreasedMemoryLimit: false,
                provenLoadBytes: calibration.largestSuccessfulLoadBytes
            )
            #expect(budget.isProven == false)
            #expect(budget.usableBytes == Int64(Double(6 * gigabyte) * 0.45))

            // And the fallback has to be usable, not merely non-crashing: the
            // first launch is where every model in the catalogue gets its badge.
            let model = try #require(ModelCatalog.model(withID: "llama-3.2-1b"))
            #expect(budget.fit(for: model) == .comfortable)
        }
    }

    // Was "the calibrated ceiling wins even when it is lower than the guess",
    // which is the bug written down as a requirement. A model loading here is
    // evidence about the floor and none at all about the ceiling: SmolLM2 360M
    // loading proves this phone holds 684 MB, not that it holds no more than
    // 684 MB. Believing the latter is what made every row on the Models screen
    // read "Too large" after one small download.
    @Test("a proven load widens the budget and can never narrow it")
    func proofIsAFloor() {
        let fraction = Int64(Double(6 * gigabyte) * 0.58)

        let small = DeviceBudget(
            physicalMemoryBytes: 6 * gigabyte,
            hasIncreasedMemoryLimit: true,
            provenLoadBytes: 683_826_592
        )
        #expect(small.isProven)
        #expect(small.usableBytes == fraction,
                "the size of the last model loaded is not this phone's ceiling")

        let big = DeviceBudget(
            physicalMemoryBytes: 6 * gigabyte,
            hasIncreasedMemoryLimit: true,
            provenLoadBytes: fraction + gigabyte
        )
        #expect(big.usableBytes == fraction + gigabyte,
                "a load that actually happened outranks the fraction that said it could not")
    }

    @Test("no proof can invent memory the machine does not have")
    func cappedAtPhysicalMemory() {
        // What an overstated catalogue size looks like once it has been
        // recorded as a proof: this project has shipped one out by 1.3 GB.
        let budget = DeviceBudget(
            physicalMemoryBytes: 6 * gigabyte,
            hasIncreasedMemoryLimit: true,
            provenLoadBytes: 40 * gigabyte
        )
        #expect(budget.usableBytes == 6 * gigabyte)
    }

    @Test("recording a successful load widens what the device will accept")
    func recordingChangesTheVerdict() throws {
        try withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            let model = try #require(ModelCatalog.model(withID: "qwen3-4b"))

            // An unentitled 6 GB phone by the fraction: refused outright.
            var budget = DeviceBudget(
                physicalMemoryBytes: 6 * gigabyte,
                hasIncreasedMemoryLimit: false
            )
            #expect(budget.fit(for: model) == .willNotFit)

            // This is the call the app layer makes on the success path of a
            // load, and it is the whole point of the exercise: the device has
            // now demonstrated it can hold this, so refusing it is a lie.
            budget.recordSuccessfulLoad(of: model, calibration: calibration)

            #expect(budget.isProven)
            #expect(budget.fit(for: model) != .willNotFit)
            #expect(calibration.largestSuccessfulLoadBytes != nil)
        }
    }

    // Was "a clean-state reading folds into the budget in place", which asserted
    // that `usableBytes` tracked `os_proc_available_memory()`. It is the bug:
    // the reading falls by the size of whatever is resident, so the budget fell
    // with it and the app refused models it was already running. The reading now
    // lands in `pressure`, where dropping is the entire point.
    @Test("a live reading moves the pressure signal and not the budget")
    func readingsDoNotMoveTheBudget() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            var budget = DeviceBudget(physicalMemoryBytes: 8 * gigabyte, hasIncreasedMemoryLimit: false)
            let fraction = budget.usableBytes
            #expect(budget.pressure == .unknown, "no reading yet")

            budget.recordCleanStateMemory(.fixed(5 * gigabyte), calibration: calibration)
            #expect(budget.usableBytes == fraction)
            #expect(budget.pressure == .easy)
            #expect(budget.headroomNowBytes == 5 * gigabyte)

            // The moment a model is resident. The whole screen used to move here.
            budget.refreshHeadroom(.fixed(120 * 1024 * 1024))
            #expect(budget.usableBytes == fraction)
            #expect(budget.pressure == .critical)
            #expect(budget.pressure.suggestsUnloading)
            #expect(budget.pressure.message != nil, "pressure has its own words")
        }
    }

    @Test("current() takes a launch reading and carries forward what was proven")
    func currentReadsAtLaunch() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            calibration.recordSuccessfulLoad(estimatedBytes: 2 * gigabyte)

            let budget = DeviceBudget.current(
                hasIncreasedMemoryLimit: false,
                calibration: calibration,
                available: .fixed(3 * gigabyte)
            )

            #expect(calibration.availableMemoryCeilingBytes == 3 * gigabyte,
                    "launch is the cleanest this process gets; the reading is worth keeping there")
            #expect(budget.isProven)
            #expect(budget.provenLoadBytes == 2 * gigabyte, "the proof, alone and unmixed")
            #expect(budget.headroomNowBytes == 3 * gigabyte, "the reading, alone and unmixed")
        }
    }

    @Test("a device that cannot answer still has a budget")
    func noReadingLeavesTheFallbackInPlace() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            let budget = DeviceBudget.current(
                hasIncreasedMemoryLimit: true,
                calibration: calibration,
                available: .unavailable
            )
            #expect(budget.isProven == false)
            #expect(budget.pressure == .unknown)
            #expect(budget.usableBytes == Int64(Double(budget.physicalMemoryBytes) * 0.58))
        }
    }

    #if os(macOS)
    @Test("os_proc_available_memory is not reachable off iOS, and says so with nil")
    func systemReadingIsAbsentOffDevice() {
        // The symbol is API_UNAVAILABLE(macos), so `AvailableMemory.system` is
        // compiled out here. If it ever starts returning 0 instead of nil, the
        // ratchet would silently stop learning rather than fall back, and every
        // test above would still pass.
        #expect(AvailableMemory.system.bytes == nil)
    }
    #endif

    @Test("forgetting resets the device to a cold start")
    func forget() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            calibration.recordSuccessfulLoad(estimatedBytes: 3 * gigabyte)
            calibration.recordAvailableMemory(4 * gigabyte)
            calibration.forget()
            #expect(calibration.largestSuccessfulLoadBytes == nil)
            #expect(calibration.availableMemoryCeilingBytes == nil)
        }
    }

    // MARK: The bug the audit found

    /// The whole point, stated once: loading a model must not change what the
    /// app says about any model, including that one.
    ///
    /// What was on screen: "Usable memory 15.46 GB, everything Fits" on a fresh
    /// launch, then "683.8 MB usable, everything Too large" after one model —
    /// including the model that was at that moment loaded and answering. 683.8
    /// MB is SmolLM2 360M's own estimate, which had been recorded as a proof
    /// and then read as a ceiling.
    @Test("loading a model changes no model's verdict, least of all its own")
    func loadingDoesNotMoveAnyVerdict() throws {
        try withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            var budget = DeviceBudget(
                physicalMemoryBytes: 6 * gigabyte,
                hasIncreasedMemoryLimit: false,
                environment: .device
            )
            let before = ModelCatalog.all.map { budget.fit(for: $0) }

            let loaded = try #require(ModelCatalog.model(withID: "smollm2-360m"))
            #expect(budget.fit(for: loaded) == .comfortable)
            budget.recordSuccessfulLoad(of: loaded, calibration: calibration)
            // And the phone is now genuinely short of memory, which is true and
            // is not a fact about whether any model fits.
            budget.refreshHeadroom(.fixed(180 * 1024 * 1024))

            #expect(ModelCatalog.all.map { budget.fit(for: $0) } == before,
                    "the resident model's own footprint must not count against itself, or anything else")
            #expect(budget.fit(for: loaded) == .comfortable)
            #expect(budget.pressure == .critical, "the pressure signal is where this belongs")
        }
    }
}
