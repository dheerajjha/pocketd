import Foundation
import HealthKit
import PocketdKit

// The value types this file hands out — `HealthSample`, `SleepInterval`,
// `WorkoutRow`, `HealthReadout` — live in PocketdKit beside the arithmetic that
// turns them into what the model reads. Nothing about them needs HealthKit, and
// on this side of the seam they could not be tested: the package tests run on
// macOS, where there is no Health store to have.

/// The single owner of this app's `HKHealthStore`.
///
/// An actor rather than a `@MainActor` type because every read here waits on the
/// Health daemon across XPC, and three years of daily buckets is not a quick
/// wait. Doing that on the main actor drops frames in the Chat view the tool
/// call was made from.
///
/// One store, not one per call. `HKHealthStore` is documented as expensive to
/// create, and the authorization request is an instance method whose effect the
/// same instance has to observe.
actor HealthAccess {
    static let shared = HealthAccess()

    private let store = HKHealthStore()

    /// Which foci have already been put to the user in this process.
    ///
    /// HealthKit lets an app request authorization several times with different
    /// type sets, and that is used deliberately: asking for sleep the first time
    /// someone asks about sleep is a far more answerable question than a sheet
    /// with nine switches on it at launch. Cached per process rather than
    /// persisted — a fresh launch costs one silent round trip, and iOS never
    /// shows the sheet twice for the same type anyway.
    private var requested: Set<HealthFocus> = []

    /// Cap on raw sleep stage samples fetched in one go.
    ///
    /// A watch writes twenty to sixty stage samples a night, so six months is on
    /// the order of seven thousand. Ten thousand is the ceiling at which the
    /// marshalling cost is still measured in milliseconds; past it, the older
    /// samples are dropped rather than the query being slow inside a chat turn.
    /// Hitting the cap shortens the reach rather than corrupting it:
    /// `HealthSuperlative.bestInReach` reports the span it actually saw.
    private static let sleepSampleLimit = 10_000

    // MARK: - Availability

    /// `nonisolated` because it reads a process-wide flag with no I/O, so a view
    /// can call it in a body to decide whether to show the Health row at all.
    nonisolated static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Permission

    /// The curated read set for one focus.
    ///
    /// Nine types across all four foci, and every one of them is read by
    /// something the summary actually prints. Asking for a type we never query
    /// is asking a user to agree to a capability we do not use, which is the
    /// single thing that makes a Health sheet look like a data grab — and the
    /// sheet lists every type by name, so it is visible.
    ///
    /// - Steps, active energy and Apple exercise time are the three halves of
    ///   "how active have I been". Steps alone works with no watch at all, which
    ///   is most people; the other two only exist if there is one.
    /// - Resting heart rate is the best single "is today different" signal there
    ///   is, and HRV is the one that moves with recovery rather than with
    ///   effort. Walking heart rate average completes the pair: it is measured
    ///   under load, so together they separate a bad night from a fitness change.
    /// - Sleep analysis is the whole sleep focus.
    /// - Respiratory rate is recorded while asleep, and a rise against baseline
    ///   is the classic early sign of something coming on. It is read with sleep
    ///   because that is when it is measured.
    /// - Workouts, plus the active energy already requested, are what a workout
    ///   row is made of.
    ///
    /// Not requested, deliberately: blood oxygen, body mass, ECG, menstrual
    /// data, clinical records. Nothing here reads them, and several of them are
    /// the kinds of data that make a permission sheet a reason to close the app.
    static func readTypes(for focus: HealthFocus) -> Set<HKObjectType> {
        var types = Set<HKObjectType>(focus.metrics.compactMap(quantityType))
        if focus.metrics.contains(.sleep) {
            types.insert(HKCategoryType(.sleepAnalysis))
        }
        if focus == .workouts {
            types.insert(HKObjectType.workoutType())
            // A workout row quotes the energy it burned, and that comes from the
            // workout's own active-energy statistics rather than from the
            // workout object — so the quantity type has to be readable too.
            types.insert(HKQuantityType(.activeEnergyBurned))
        }
        return types
    }

    /// Asks for the types this focus needs, if they have not been asked for yet.
    ///
    /// The `Bool` HealthKit would give back is deliberately not consulted, and
    /// there is nothing else to consult either: an app cannot tell a granted read
    /// from a refused one. `authorizationStatus(for:)` answers about *writing*
    /// and is useless here, and a refused read returns exactly what a type
    /// nobody has ever recorded returns. So this reports only whether the
    /// question could be put at all, and the summary phrases the empty case to
    /// be true either way.
    func requestReadAccess(for focus: HealthFocus) async -> HealthAvailability {
        guard Self.isAvailable else { return .noHealthData }
        guard !requested.contains(focus) else { return .available }

        let types = Self.readTypes(for: focus)
        guard !types.isEmpty else { return .available }

        do {
            // An empty share set: these tools read and never write. A throw here
            // means the question could not be put to the user at all — no sheet,
            // no decision — which is a different thing from a decision we do not
            // like, and the only one of the two we are able to detect.
            try await store.requestAuthorization(toShare: [], read: types)
            requested.insert(focus)
            return .available
        } catch {
            return .requestFailed(error.localizedDescription)
        }
    }

    /// Asks for everything the tool can ever read, at a moment the user chose.
    ///
    /// Called from the Settings switch rather than from a tool body, and for the
    /// reason `AppModel` already gives about the calendar: iOS puts the sheet up
    /// as a modal, and first use is in the middle of a generation — the engine is
    /// holding its gate, the stream is open and producing nothing, and the user
    /// is being asked about their heart rate with no visible connection to the
    /// sentence they typed. Whatever they tap under those conditions is not
    /// really a decision.
    ///
    /// The per-focus path stays for the case this cannot cover: HealthKit allows
    /// several requests with different type sets, so a focus that has somehow
    /// never been asked for still asks rather than silently reading nothing.
    func requestAllReadAccess() async -> HealthAvailability {
        guard Self.isAvailable else { return .noHealthData }

        var types = Set<HKObjectType>()
        for focus in HealthFocus.allCases {
            types.formUnion(Self.readTypes(for: focus))
        }

        do {
            try await store.requestAuthorization(toShare: [], read: types)
            requested.formUnion(HealthFocus.allCases)
            return .available
        } catch {
            return .requestFailed(error.localizedDescription)
        }
    }

    // MARK: - Reads

    /// Everything one focus needs, in one pass. Never throws.
    ///
    /// A throw from here would propagate through the tool body and out of the
    /// inference library's executor, ending the generation: the user watches the
    /// stream stop mid-sentence. Every failure is a value — an absent metric
    /// reads exactly like a metric with nothing in it, which is also the only
    /// honest thing to say about it.
    func readout(for focus: HealthFocus, in window: DateInterval) async -> HealthReadout {
        let availability = await requestReadAccess(for: focus)
        guard availability == .available else { return HealthReadout(availability: availability) }

        var samples: [HealthMetric: [HealthSample]] = [:]
        for metric in focus.metrics where metric != .sleep {
            samples[metric] = await dailyBuckets(of: metric, in: window)
        }

        let sleep = focus.metrics.contains(.sleep) ? await sleepIntervals(in: window) : []
        let workouts = focus == .workouts ? await recentWorkouts(in: window) : []

        return HealthReadout(
            availability: .available,
            samples: samples,
            sleep: sleep,
            workouts: workouts,
            // One more than the cap is fetched so that "there are more" is a
            // fact rather than a guess.
            truncated: workouts.count > HealthSummary.rowLimit
        )
    }

    /// One value per calendar day, computed by HealthKit rather than by us.
    ///
    /// `HKStatisticsCollectionQueryDescriptor` aggregates inside the daemon and
    /// hands back one bucket per day, so three years of walking crosses the
    /// process boundary as about a thousand doubles instead of a hundred
    /// thousand sample objects. That is what makes the long memory affordable —
    /// and the long memory is the whole reason to do this on the device.
    ///
    /// The anchor is the window's start, which `HealthSummary.window` already
    /// put on a local midnight. Anchoring anywhere else silently shifts every
    /// bucket off the user's day boundary, and the error is invisible: the
    /// numbers still look like step counts.
    private func dailyBuckets(of metric: HealthMetric, in window: DateInterval) async -> [HealthSample] {
        guard let type = Self.quantityType(for: metric), let unit = Self.unit(for: metric) else { return [] }
        // The tag on every sample below is worked out from the unit the value is
        // about to be read with, never copied from `metric.unit`. Copying is
        // what made the mismatch check in `HealthArithmetic.daily` decorative:
        // both sides came off the same `switch`, so changing `unit(for:)` to
        // `.second()` for HRV would have rescaled every number by a thousand and
        // relabelled it in the same motion, and nothing downstream could see it.
        // Asking `HealthUnit` what HealthKit's own `unitString` means puts the
        // two derivations on opposite sides of the framework, which is the only
        // arrangement in which one can catch the other.
        guard let tag = HealthUnit.named(unit.unitString, preferring: metric.unit) else {
            // A unit this app has no name for. Reading it would produce numbers
            // that cannot be checked against anything, and the summary already
            // knows how to say "no data" without claiming a refusal.
            return []
        }

        let options: HKStatisticsOptions = metric.aggregation == .sum ? .cumulativeSum : .discreteAverage
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(
                type: type,
                predicate: HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: .strictStartDate)
            ),
            options: options,
            anchorDate: window.start,
            intervalComponents: DateComponents(day: 1)
        )

        guard let collection = try? await descriptor.result(for: store) else { return [] }

        return collection.statistics().compactMap { statistics -> HealthSample? in
            let quantity = metric.aggregation == .sum ? statistics.sumQuantity() : statistics.averageQuantity()
            // A bucket with no samples in it is `nil`, not zero, and the
            // difference matters: a zero is a day the user did not move, and a
            // nil is a day the phone was not with them. Reported as zero, a week
            // on holiday without a watch becomes a week of very bad numbers.
            guard let value = quantity?.doubleValue(for: unit), value.isFinite else { return nil }
            return HealthSample(value: value, unit: tag, date: statistics.startDate)
        }
    }

    /// Raw sleep stages, left raw on purpose.
    ///
    /// The bucketing into nights, the union of overlapping sources and the
    /// exclusion of in-bed-but-awake all happen in `HealthArithmetic`, where they
    /// can be tested against a spring-forward night on a machine with no Health
    /// store. Doing any of it here would put the part most likely to be wrong on
    /// the side of the seam that cannot be exercised.
    private func sleepIntervals(in window: DateInterval) async -> [SleepInterval] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [
                .categorySample(
                    type: HKCategoryType(.sleepAnalysis),
                    predicate: HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
                )
            ],
            // Newest first, so a cap drops the oldest nights rather than the ones
            // the baseline and the streak are built from.
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: Self.sleepSampleLimit
        )

        guard let samples = try? await descriptor.result(for: store) else { return [] }
        return samples.map { sample in
            SleepInterval(start: sample.startDate, end: sample.endDate, asleep: Self.isAsleep(sample.value))
        }
    }

    /// Whether a sleep category value means asleep rather than merely in bed.
    ///
    /// `inBed` and `awake` are not sleep. Counting them inflates every night by
    /// the better part of an hour, and the error is invisible because the result
    /// is still a plausible number of hours. `asleepUnspecified` is what a
    /// pre-iOS-16 sample and most third-party trackers write, so it has to be
    /// here or those users have no sleep at all.
    private nonisolated static func isAsleep(_ value: Int) -> Bool {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: true
        case .inBed, .awake: false
        // A stage a future iOS invents is not counted. Under-reporting sleep is
        // recoverable; over-reporting it is a number the user cannot check.
        default: false
        }
    }

    /// The most recent workouts, one more than will be shown.
    private func recentWorkouts(in window: DateInterval) async -> [WorkoutRow] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [
                .workout(HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: []))
            ],
            sortDescriptors: [SortDescriptor(\HKWorkout.startDate, order: .reverse)],
            // One past the cap: the summary needs to know whether there were
            // more, and counting is cheaper than a second query.
            limit: HealthSummary.rowLimit + 1
        )

        guard let workouts = try? await descriptor.result(for: store) else { return [] }
        let energyType = HKQuantityType(.activeEnergyBurned)

        return workouts.map { workout in
            // `totalEnergyBurned` was deprecated in iOS 18 in favour of this.
            // The old property is still there and still compiles, which is how a
            // workout ends up reporting energy from only one of its segments.
            let energy = workout.statistics(for: energyType)?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie())

            return WorkoutRow(
                activity: Self.name(of: workout.workoutActivityType),
                start: workout.startDate,
                duration: workout.duration,
                energyKilocalories: energy.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            )
        }
    }

    // MARK: - HealthKit's vocabulary, translated

    private nonisolated static func quantityType(for metric: HealthMetric) -> HKQuantityType? {
        switch metric {
        case .steps: HKQuantityType(.stepCount)
        case .active_energy: HKQuantityType(.activeEnergyBurned)
        case .exercise_minutes: HKQuantityType(.appleExerciseTime)
        case .resting_heart_rate: HKQuantityType(.restingHeartRate)
        case .heart_rate_variability: HKQuantityType(.heartRateVariabilitySDNN)
        case .walking_heart_rate: HKQuantityType(.walkingHeartRateAverage)
        case .respiratory_rate: HKQuantityType(.respiratoryRate)
        // Sleep is a category type, not a quantity, and there is no quantity
        // type for sleep duration anywhere in HealthKit.
        case .sleep: nil
        }
    }

    /// The unit each value is read in, and the reason `HealthSample` carries one.
    ///
    /// `HKQuantity.doubleValue(for:)` will happily answer in any compatible unit:
    /// asking for HRV in seconds instead of milliseconds is one character and
    /// produces a number a thousand times too small, with no error. Change a
    /// line here and `dailyBuckets` tags the samples from HealthKit's own
    /// `unitString` rather than from the metric, `HealthArithmetic.daily` sees
    /// `.second` where `.millisecond` was expected, and the day is dropped —
    /// the summary then says it has too little data, which is recoverable.
    /// Averaging the rescaled number in is not.
    private nonisolated static func unit(for metric: HealthMetric) -> HKUnit? {
        switch metric {
        case .steps: HKUnit.count()
        case .active_energy: HKUnit.kilocalorie()
        case .exercise_minutes: HKUnit.minute()
        case .resting_heart_rate, .walking_heart_rate: HKUnit.count().unitDivided(by: .minute())
        case .heart_rate_variability: HKUnit.secondUnit(with: .milli)
        case .respiratory_rate: HKUnit.count().unitDivided(by: .minute())
        case .sleep: nil
        }
    }

    /// A workout activity's name, in words.
    ///
    /// `HKWorkoutActivityType` is an integer enum with no display name of its
    /// own — there is no API that turns 37 into "Running" — so this is the list
    /// of what people actually record, and everything else says "Workout" rather
    /// than a number. A wrong name is worse than a general one: the model will
    /// build a sentence around whatever it is given.
    private nonisolated static func name(of activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running: "Run"
        case .walking: "Walk"
        case .cycling: "Cycle"
        case .swimming: "Swim"
        case .hiking: "Hike"
        case .yoga: "Yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: "Strength training"
        case .highIntensityIntervalTraining: "HIIT"
        case .elliptical: "Elliptical"
        case .rowing: "Rowing"
        case .stairClimbing, .stairs: "Stairs"
        case .coreTraining: "Core training"
        case .pilates: "Pilates"
        case .dance, .cardioDance, .socialDance: "Dance"
        case .tennis: "Tennis"
        case .soccer: "Football"
        case .basketball: "Basketball"
        case .golf: "Golf"
        case .climbing: "Climbing"
        case .mindAndBody: "Mind and body"
        case .cooldown: "Cooldown"
        default: "Workout"
        }
    }
}
