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

    @Test("holds a reserve back from an observed ceiling but not from a proven load")
    func reserveAppliesOnlyToTheSnapshot() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)

            calibration.recordAvailableMemory(4 * gigabyte)
            #expect(calibration.ceilingBytes == 4 * gigabyte - MemoryCalibration.loadReserveBytes)

            // A load that already happened needs no reserve: everything the
            // reserve is there to cover was resident at the time.
            calibration.recordSuccessfulLoad(estimatedBytes: 4 * gigabyte)
            #expect(calibration.ceilingBytes == 4 * gigabyte)
        }
    }

    // MARK: What the budget does with it

    @Test("a cold start with nothing learned still answers, from the fraction")
    func coldStart() throws {
        try withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            #expect(calibration.ceilingBytes == nil, "nothing has been learned yet")

            let budget = DeviceBudget(
                physicalMemoryBytes: 6 * gigabyte,
                hasIncreasedMemoryLimit: false,
                calibratedCeilingBytes: calibration.ceilingBytes
            )
            #expect(budget.isCalibrated == false)
            #expect(budget.usableBytes == Int64(Double(6 * gigabyte) * 0.45))

            // And the fallback has to be usable, not merely non-crashing: the
            // first launch is where every model in the catalogue gets its badge.
            let model = try #require(ModelCatalog.model(withID: "llama-3.2-1b"))
            #expect(budget.fit(for: model) == .comfortable)
        }
    }

    @Test("the calibrated ceiling wins even when it is lower than the guess")
    func calibrationBeatsTheFraction() {
        let fraction = Int64(Double(6 * gigabyte) * 0.58)
        let measured = fraction - gigabyte

        let budget = DeviceBudget(
            physicalMemoryBytes: 6 * gigabyte,
            hasIncreasedMemoryLimit: true,
            calibratedCeilingBytes: measured
        )
        #expect(budget.isCalibrated)
        #expect(budget.usableBytes == measured,
                "preferring whichever is larger would reinstate the guess on exactly the devices it was too generous for")
    }

    @Test("no calibration can invent memory the machine does not have")
    func cappedAtPhysicalMemory() {
        // What an overstated catalogue size looks like once it has been
        // recorded as a proof: this project has shipped one out by 1.3 GB.
        let budget = DeviceBudget(
            physicalMemoryBytes: 6 * gigabyte,
            hasIncreasedMemoryLimit: true,
            calibratedCeilingBytes: 40 * gigabyte
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

            #expect(budget.isCalibrated)
            #expect(budget.fit(for: model) != .willNotFit)
            #expect(calibration.largestSuccessfulLoadBytes != nil)
        }
    }

    @Test("a clean-state reading folds into the budget in place")
    func recordingAReading() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            var budget = DeviceBudget(physicalMemoryBytes: 8 * gigabyte, hasIncreasedMemoryLimit: false)
            #expect(budget.isCalibrated == false)

            budget.recordCleanStateMemory(.fixed(5 * gigabyte), calibration: calibration)
            #expect(budget.usableBytes == 5 * gigabyte - MemoryCalibration.loadReserveBytes)

            // A later, worse moment must not narrow it.
            budget.recordCleanStateMemory(.fixed(gigabyte), calibration: calibration)
            #expect(budget.usableBytes == 5 * gigabyte - MemoryCalibration.loadReserveBytes)
        }
    }

    @Test("current() takes a launch reading and carries forward what was learned")
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
                    "launch is the cleanest this process gets; the reading is worth taking there")
            #expect(budget.isCalibrated)
            // 3 GB observed minus the reserve is below the 2 GB proof, so the
            // proof is what the ceiling reports.
            #expect(budget.calibratedCeilingBytes == max(2 * gigabyte, 3 * gigabyte - MemoryCalibration.loadReserveBytes))
        }
    }

    @Test("a device that cannot answer produces no calibration at all")
    func noReadingLeavesTheFallbackInPlace() {
        withDefaults { defaults in
            let calibration = MemoryCalibration(defaults: defaults)
            let budget = DeviceBudget.current(
                hasIncreasedMemoryLimit: true,
                calibration: calibration,
                available: .unavailable
            )
            #expect(budget.isCalibrated == false)
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
            #expect(calibration.ceilingBytes == nil)
        }
    }
}
