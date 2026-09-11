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
    /// with sixteen switches on it at launch. Cached per process rather than
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

    /// Cap on raw category samples fetched in one go, for the types that are not
    /// sleep.
    ///
    /// The same ceiling and the same trade. A stand hour is one marker per hour,
    /// so three years of them is about thirteen thousand rows; ten thousand
    /// stood hours is around eight hundred days of reach, which is further back
    /// than any claim the summary makes with them. Mindful sessions are nowhere
    /// near the cap for anybody.
    private static let categorySampleLimit = 10_000

    // MARK: - Availability

    /// `nonisolated` because it reads a process-wide flag with no I/O, so a view
    /// can call it in a body to decide whether to show the Health row at all.
    nonisolated static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Permission

    /// The curated read set for one focus.
    ///
    /// Sixteen types across all five foci, and every one of them is read by
    /// something the summary actually prints. Asking for a type we never query
    /// is asking a user to agree to a capability we do not use, which is the
    /// single thing that makes a Health sheet look like a data grab — and the
    /// sheet lists every type by name, so it is visible.
    ///
    /// - Steps, active energy, Apple exercise time, walking and running distance
    ///   and stand hours are "how active have I been". Steps and distance work
    ///   with no watch at all, which is most people; the other three only exist
    ///   if there is one.
    /// - Resting heart rate is the best single "is today different" signal there
    ///   is, and HRV is the one that moves with recovery rather than with
    ///   effort. Walking heart rate average completes the pair: it is measured
    ///   under load, so together they separate a bad night from a fitness change.
    ///   Heart rate is the series all three are derived from, and blood oxygen
    ///   is the other vital the same sensor records.
    /// - Sleep analysis is the whole sleep focus.
    /// - Respiratory rate is recorded while asleep, and a rise against baseline
    ///   is the classic early sign of something coming on. It is read with sleep
    ///   because that is when it is measured. Mindful sessions are read there for
    ///   the neighbouring reason: the question they answer is about rest.
    /// - Body mass and VO2 max move over months rather than over days, which is
    ///   the timescale a phone holding everything the user ever recorded can see
    ///   and a service keeping ninety days cannot.
    /// - Workouts, plus the active energy already requested, are what a workout
    ///   row is made of.
    ///
    /// Not requested, deliberately: ECG and heart rhythm, menstrual and
    /// reproductive data, blood glucose, medications, clinical records. Nothing
    /// here reads them, and several of them are the kinds of data that make a
    /// permission sheet a reason to close the app.
    static func readTypes(for focus: HealthFocus) -> Set<HKObjectType> {
        var types = Set<HKObjectType>(focus.metrics.compactMap(quantityType))
        // The three metrics HealthKit keeps as categories rather than as
        // quantities, each named on its own because `quantityType` cannot answer
        // for any of them.
        if focus.metrics.contains(.sleep) {
            types.insert(HKCategoryType(.sleepAnalysis))
        }
        if focus.metrics.contains(.stand_hours) {
            types.insert(HKCategoryType(.appleStandHour))
        }
        if focus.metrics.contains(.mindful_minutes) {
            types.insert(HKCategoryType(.mindfulSession))
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
        for metric in focus.metrics {
            switch metric {
            // Sleep is the one metric whose raw shape survives the crossing, so
            // that the night-to-morning attribution and the union of overlapping
            // sources happen where they can be tested.
            case .sleep: continue
            case .stand_hours: samples[metric] = await standHours(in: window)
            case .mindful_minutes: samples[metric] = await mindfulSessions(in: window)
            // A default rather than twelve more names, and it is safe in the one
            // direction that matters: a metric nothing here maps gets no
            // quantity type, reads as empty, and is reported as data that did
            // not arrive rather than as a number nobody measured.
            default: samples[metric] = await dailyBuckets(of: metric, in: window)
            }
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

    /// Stand hours, counted rather than measured.
    ///
    /// `appleStandHour` is a category type that writes one marker an hour, so a
    /// day's figure is how many of those markers say the user stood — which is
    /// the number on the watch's ring and the number the label claims.
    /// `appleStandTime` is the quantity alternative and would go through the
    /// statistics path for free, but it measures minutes spent on your feet: a
    /// real measurement of a different thing, and summing it under the word
    /// "hours" would be wrong by construction rather than by accident.
    ///
    /// The idle markers are excluded by the predicate rather than counted and
    /// then filtered, which fails closed the way `isAsleep` does: a value a later
    /// iOS invents is not a stood hour until somebody here says it is.
    private func standHours(in window: DateInterval) async -> [HealthSample] {
        let stood = HKQuery.predicateForCategorySamples(
            with: .equalTo, value: HKCategoryValueAppleStandHour.stood.rawValue
        )
        let samples = await categorySamples(of: HKCategoryType(.appleStandHour), matching: stood, in: window)
        return samples.map { HealthSample(value: 1, unit: .count, date: $0.startDate) }
    }

    /// Mindful sessions, as the durations they are.
    ///
    /// A mindful session carries no quantity at all — its value is
    /// `HKCategoryValue.notApplicable` and the measurement is the distance
    /// between its two dates — so there is no `HKUnit` to read it in and no
    /// statistics collection to ask for it. What crosses the seam is seconds,
    /// which is what `timeIntervalSince` means and is therefore the one unit
    /// here that cannot be got wrong. From there it is an ordinary summed
    /// metric, added up per day by the same code that adds up steps, rather than
    /// a second interval mechanism beside sleep's.
    ///
    /// A session is attributed to the day it began on. One running through
    /// midnight is the only case where that is arguable, and splitting it would
    /// be new machinery for a few seconds either way.
    private func mindfulSessions(in window: DateInterval) async -> [HealthSample] {
        let samples = await categorySamples(of: HKCategoryType(.mindfulSession), matching: nil, in: window)
        return samples.map {
            HealthSample(value: $0.endDate.timeIntervalSince($0.startDate), unit: .second, date: $0.startDate)
        }
    }

    /// The category samples of one type inside a window, newest first.
    ///
    /// Newest first for the reason the sleep read is: a cap that bites drops the
    /// oldest days rather than the ones the baseline and the streak are built
    /// from, so it shortens the reach instead of corrupting what is left.
    private func categorySamples(
        of type: HKCategoryType,
        matching predicate: NSPredicate?,
        in window: DateInterval
    ) async -> [HKCategorySample] {
        let inWindow = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [
                .categorySample(
                    type: type,
                    predicate: predicate.map {
                        NSCompoundPredicate(andPredicateWithSubpredicates: [inWindow, $0])
                    } ?? inWindow
                )
            ],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: Self.categorySampleLimit
        )
        return (try? await descriptor.result(for: store)) ?? []
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
        case .distance: HKQuantityType(.distanceWalkingRunning)
        case .resting_heart_rate: HKQuantityType(.restingHeartRate)
        case .heart_rate_variability: HKQuantityType(.heartRateVariabilitySDNN)
        case .walking_heart_rate: HKQuantityType(.walkingHeartRateAverage)
        case .heart_rate: HKQuantityType(.heartRate)
        case .blood_oxygen: HKQuantityType(.oxygenSaturation)
        case .respiratory_rate: HKQuantityType(.respiratoryRate)
        case .body_mass: HKQuantityType(.bodyMass)
        case .vo2_max: HKQuantityType(.vo2Max)
        // The three HealthKit keeps as categories. There is no quantity type for
        // sleep duration, for a stand hour or for a mindful session anywhere in
        // the framework, and each is read by a query of its own above.
        case .sleep, .stand_hours, .mindful_minutes: nil
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
        case .distance: HKUnit.meterUnit(with: .kilo)
        case .resting_heart_rate, .walking_heart_rate, .heart_rate: HKUnit.count().unitDivided(by: .minute())
        case .heart_rate_variability: HKUnit.secondUnit(with: .milli)
        // Between 0 and 1, which is what `HKUnit.percent()` measures and what a
        // saturation of 98% therefore arrives as. Reading it in the magnitude
        // HealthKit stores it in is what leaves the tag on the sample meaning
        // something; turning it into a percentage is `HealthFormat`'s job, and
        // doing it here instead would rescale the number and relabel it in one
        // motion, which is the mistake this whole arrangement exists to catch.
        case .blood_oxygen: HKUnit.percent()
        case .respiratory_rate: HKUnit.count().unitDivided(by: .minute())
        case .body_mass: HKUnit.gramUnit(with: .kilo)
        // Built rather than named: HealthKit has no constant for this one, and
        // it normalises whatever order the parts are assembled in to the single
        // string `mL/min·kg` — which is what `HealthUnit` has to match, and is
        // not the order anybody writes it in.
        case .vo2_max:
            HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .sleep, .stand_hours, .mindful_minutes: nil
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
