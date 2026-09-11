import Foundation
import Testing
@testable import PocketdKit

/// Records what the Health store was asked to do, and what it was asked for.
///
/// The interesting assertion here is a negative one — that a network caller
/// causes *no* read — and a negative is only worth anything if something records
/// the attempt. Same shape as `PersonalDataToolTests`' spy, for the same reason:
/// a stub that returned nothing would pass a test that checks the output while
/// the phone read the user's heart rate and threw it away.
private actor HealthReadSpy {
    private(set) var calls = 0
    private(set) var lastFocus: HealthFocus?
    private(set) var lastWindow: DateInterval?
    private let readout: HealthReadout

    init(returning readout: HealthReadout = HealthReadout()) {
        self.readout = readout
    }

    func read(_ focus: HealthFocus, _ window: DateInterval) -> HealthReadout {
        calls += 1
        lastFocus = focus
        lastWindow = window
        return readout
    }
}

private enum Health {
    static let utc = TimeZone(identifier: "UTC")!
    /// A real locale rather than `en_US_POSIX`: POSIX deliberately has no
    /// grouping separator, and grouping is exactly the thing that makes a
    /// five-figure step count readable to a person.
    static let english = Locale(identifier: "en_US")

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.firstWeekday = 2
        return calendar
    }

    /// Thursday 11 September 2025, 10:00 UTC. Fixed so nothing here depends on
    /// the day the suite is run.
    static let now = calendar.date(from: DateComponents(year: 2025, month: 9, day: 11, hour: 10))!

    /// Daily samples ending the day before today, so every one of them is a
    /// completed day.
    static func samples(
        count: Int,
        unit: HealthUnit,
        endingDaysBack: Int = 1,
        value: (Int) -> Double
    ) -> [HealthSample] {
        let today = calendar.startOfDay(for: now)
        return (endingDaysBack...(endingDaysBack + count - 1)).reversed().map { back in
            HealthSample(
                value: value(back),
                unit: unit,
                date: calendar.date(byAdding: .day, value: -back, to: today)!
            )
        }
    }

    /// `asOf` is a parameter rather than a constant so that one series can be
    /// asked about twice. A summary that phrases a streak or a record in the
    /// present tense is only testable by holding the data still and moving the
    /// clock — asserting an absence at one instant proves nothing, because a
    /// test that expects nothing passes when the feature is deleted.
    static func payload(
        _ focus: HealthFocus,
        asOf: Date = Health.now,
        origin: RequestOrigin = .onDeviceChat,
        readout: HealthReadout
    ) async -> [String: any Sendable] {
        await HealthSummary.payload(
            focus: focus, now: asOf, calendar: calendar, locale: english, timeZone: utc, origin: origin,
            read: { _, _ in readout }
        )
    }

    /// Midday on 12 June 2025 — 91 days before `now`, which is what "the last
    /// time they wore the watch was in June" means in these tests.
    static let june = calendar.date(from: DateComponents(year: 2025, month: 6, day: 12, hour: 10))!

    /// `count` nights of `hours`, the last of them attributed to the morning of
    /// `endingOn`.
    static func nights(count: Int, hours: Double, endingOn day: Date) -> [SleepInterval] {
        let morning = calendar.startOfDay(for: day)
        return (0..<count).map { back in
            let end = calendar.date(byAdding: .day, value: -back, to: morning)!
            return SleepInterval(start: end.addingTimeInterval(-hours * 3600), end: end, asleep: true)
        }
    }
}

@Suite("Health summary: who may ask")
struct HealthSummaryOriginTests {

    @Test("a network caller cannot read health data, and cannot cause it to be read")
    func networkOriginIsRefusedBeforeTheStoreIsTouched() async {
        let spy = HealthReadSpy(returning: HealthReadout(
            samples: [.resting_heart_rate: Health.samples(count: 20, unit: .beatsPerMinute) { _ in 71 }]
        ))

        let payload = await HealthSummary.payload(
            focus: .heart, now: Health.now, calendar: Health.calendar, locale: Health.english,
            timeZone: Health.utc, origin: .network(host: "192.168.1.42", port: 55_000),
            read: { await spy.read($0, $1) }
        )

        // Two properties, and the second is the one that matters. A tool that
        // read Health and then declined to report it would still have woken the
        // Health daemon, still have raised a permission sheet, and still have put
        // the user's heart rate in this process's memory at the request of a
        // stranger on the LAN.
        #expect(payload["text"] as? String == ToolContext.refusal)
        #expect(payload["readings"] == nil)
        #expect(await spy.calls == 0)
    }

    @Test("loopback is refused exactly like anything else on the wire")
    func loopbackIsNotPrivileged() async {
        // The /chat page the phone serves reaches the engine over a socket, so it
        // arrives here as 127.0.0.1. Privileging that address would hand the
        // user's sleep and heart rate to every process on the phone.
        for host in ["127.0.0.1", "::1", "localhost"] {
            let spy = HealthReadSpy()
            let payload = await HealthSummary.payload(
                focus: .sleep, now: Health.now, calendar: Health.calendar, locale: Health.english,
                timeZone: Health.utc, origin: .network(host: host, port: 11_434),
                read: { await spy.read($0, $1) }
            )
            #expect(payload["text"] as? String == ToolContext.refusal, "host \(host)")
            #expect(await spy.calls == 0, "host \(host)")
        }
    }

    @Test("an unset origin is refused, because the default is the untrusted one")
    func defaultOriginFailsClosed() async {
        let spy = HealthReadSpy()
        let payload = await HealthSummary.payload(
            focus: .activity, now: Health.now, calendar: Health.calendar,
            read: { await spy.read($0, $1) }
        )
        #expect(payload["text"] as? String == ToolContext.refusal)
        #expect(await spy.calls == 0)
    }

    @Test("every focus is gated, not just the one somebody remembered")
    func everyFocusIsGated() async {
        for focus in HealthFocus.allCases {
            let spy = HealthReadSpy()
            let payload = await HealthSummary.payload(
                focus: focus, now: Health.now, calendar: Health.calendar, locale: Health.english,
                timeZone: Health.utc, origin: .network(host: "10.0.0.9", port: 1),
                read: { await spy.read($0, $1) }
            )
            #expect(payload.keys.sorted() == ["text"], "\(focus)")
            #expect(await spy.calls == 0, "\(focus)")
        }
    }

    @Test("the origin is taken from the task local the engine binds")
    func readsTheBoundTaskLocal() async {
        let allowed = await ToolContext.$origin.withValue(.onDeviceChat) {
            await HealthSummary.payload(
                focus: .workouts, now: Health.now, calendar: Health.calendar, locale: Health.english,
                timeZone: Health.utc,
                read: { _, _ in HealthReadout(workouts: [WorkoutRow(activity: "Outdoor Run", start: Health.now, duration: 1_800)]) }
            )
        }
        #expect(allowed["workouts"] != nil)

        let refused = await ToolContext.$origin.withValue(.network(host: "h", port: 2)) {
            await HealthSummary.payload(
                focus: .workouts, now: Health.now, calendar: Health.calendar,
                read: { _, _ in HealthReadout(workouts: [WorkoutRow(activity: "Outdoor Run", start: Health.now, duration: 1_800)]) }
            )
        }
        #expect(refused["text"] as? String == ToolContext.refusal)
    }

    @Test("the phone's own chat does reach the store")
    func onDeviceChatIsAllowed() async {
        // The mirror of the refusal tests: a gate that refused everybody would
        // pass every single one of them.
        let spy = HealthReadSpy()
        _ = await HealthSummary.payload(
            focus: .heart, now: Health.now, calendar: Health.calendar, locale: Health.english,
            timeZone: Health.utc, origin: .onDeviceChat, read: { await spy.read($0, $1) }
        )
        #expect(await spy.calls == 1)
    }
}

@Suite("Health summary: denied and absent are the same thing")
struct HealthSummaryAmbiguityTests {

    @Test("an empty result never claims the user refused anything")
    func nothingClaimsADenial() async {
        // Apple is explicit: an app does not know whether someone granted or
        // denied permission to read data, and `authorizationStatus(for:)` reports
        // write access only. Any wording that picks one of the two is a guess
        // presented as a fact, and the model repeats it to the user verbatim.
        for focus in HealthFocus.allCases {
            let rendered = ToolResult.encode(await Health.payload(focus, readout: HealthReadout())).lowercased()
            for forbidden in ["denied", "denial", "refused", "you did not allow", "not granted", "rejected"] {
                #expect(!rendered.contains(forbidden), "\(focus) said \(forbidden)")
            }
        }
    }

    @Test("an empty result names both possibilities and the screen that settles it")
    func bothPossibilitiesAreNamed() async {
        let text = await Health.payload(.heart, readout: HealthReadout())["text"] as? String
        #expect(text?.contains("nothing has been recorded") == true)
        #expect(text?.contains("was not allowed to read it") == true)
        // "Permission problem" on its own sends people to the app's own page in
        // Settings, which does not have this switch.
        #expect(text?.contains("Settings > Privacy & Security > Health > Pocketd") == true)
    }

    @Test("one missing metric does not suppress the ones that came back")
    func partialDataStillAnswers() async {
        let readout = HealthReadout(samples: [
            .steps: Health.samples(count: 20, unit: .count) { _ in 9_000 }
        ])
        let payload = await Health.payload(.activity, readout: readout)

        let readings = payload["readings"] as? [String]
        #expect(readings?.count == 1)
        #expect(readings?.first?.hasPrefix("Steps") == true)
        // Named, so the model does not answer "you burned no energy".
        #expect((payload["no_data"] as? String)?.contains("Active energy") == true)
        #expect((payload["note"] as? String)?.contains("iOS deliberately does not tell an app which") == true)
    }

    @Test("the ambiguity note is written once, and only when something is missing")
    func theNoteIsNotRepeated() async {
        let complete = HealthReadout(samples: [
            .resting_heart_rate: Health.samples(count: 20, unit: .beatsPerMinute) { _ in 70 },
            .heart_rate_variability: Health.samples(count: 20, unit: .millisecond) { _ in 40 },
            .walking_heart_rate: Health.samples(count: 20, unit: .beatsPerMinute) { _ in 104 },
            .heart_rate: Health.samples(count: 20, unit: .beatsPerMinute) { _ in 68 },
            .blood_oxygen: Health.samples(count: 20, unit: .fractionOfOne) { _ in 0.97 }
        ])
        let payload = await Health.payload(.heart, readout: complete)
        // Three sentences on every answer that had nothing to explain is context
        // the user paid for and did not need.
        #expect(payload["note"] == nil)
        #expect(payload["no_data"] == nil)
    }

    @Test("a device with no Health store says so instead of blaming permissions")
    func unavailableIsItsOwnSentence() async {
        let payload = await Health.payload(.sleep, readout: HealthReadout(availability: .noHealthData))
        #expect(payload["text"] as? String == "Health data is not available on this device, so there is nothing to read.")
    }

    @Test("a failed authorization request reports its reason rather than throwing")
    func requestFailureIsText() async {
        // A throw from a tool body propagates out of the executor and ends the
        // generation: the user watches the stream stop mid-sentence.
        let payload = await Health.payload(.heart, readout: HealthReadout(availability: .requestFailed("the request was cancelled")))
        #expect((payload["text"] as? String)?.contains("the request was cancelled") == true)
        #expect(payload["readings"] == nil)
    }
}

@Suite("Health summary: what the model reads")
struct HealthSummaryPayloadTests {

    @Test("resting heart rate 71 against a usual 80 reads as 11% below")
    func theHeadlineArithmetic() async {
        // The sentence the whole feature exists for, and every number in it is a
        // mean and a division rather than anything the model was asked to do.
        // 28 whole days of baseline ending the day before the reading, so the
        // reading is not folded into the mean it is measured against.
        var samples = Health.samples(count: 28, unit: .beatsPerMinute, endingDaysBack: 2) { back in
            back % 2 == 0 ? 78 : 82   // mean 80, with a real spread
        }
        let yesterday = Health.calendar.date(
            byAdding: .day, value: -1, to: Health.calendar.startOfDay(for: Health.now)
        )!
        samples.append(HealthSample(value: 71, unit: .beatsPerMinute, date: yesterday))

        let payload = await Health.payload(.heart, readout: HealthReadout(samples: [.resting_heart_rate: samples]))
        let line = (payload["readings"] as? [String])?.first ?? ""

        #expect(line.contains("71 bpm"))
        #expect(line.contains("11% below"))
        #expect(line.contains("28-day average of 80 bpm"))
        #expect(line.contains("well below your usual range"))
    }

    @Test("three days of history produce an honest answer, not a confident one")
    func sparseHistoryRefusesToQuoteABaseline() async {
        let samples = Health.samples(count: 3, unit: .count) { _ in 8_000 }
        let payload = await Health.payload(.activity, readout: HealthReadout(samples: [.steps: samples]))
        let line = (payload["readings"] as? [String])?.first ?? ""

        // The value is still reported — the user did walk — but nothing is
        // claimed about whether it was normal for them.
        #expect(line.contains("Steps 8000 on"))
        #expect(line.contains("a usual range needs 14"))
        #expect(!line.contains("%"))
        #expect(!line.contains("average"))
        #expect(!line.contains("usual range,"))
    }

    @Test("a user with two days gets a number and no percentage anywhere in the payload")
    func sparseHistoryNeverPrintsAPercentage() async {
        let readout = HealthReadout(samples: [
            .steps: Health.samples(count: 2, unit: .count) { _ in 8_000 },
            .active_energy: Health.samples(count: 2, unit: .kilocalorie) { _ in 400 },
            .exercise_minutes: Health.samples(count: 2, unit: .minute) { _ in 25 }
        ])
        let rendered = ToolResult.encode(await Health.payload(.activity, readout: readout))
        #expect(!rendered.contains("%"))
        #expect(rendered.contains("nothing to compare this against yet"))
    }

    @Test("every value survives JSONSerialization")
    func payloadIsSerialisable() async {
        // `ToolOutput` is handed straight to `JSONSerialization`, which throws on
        // a `Date` and on a non-finite `Double`. LocalLLMClient swallows that
        // throw and interpolates the dictionary instead, so the failure is not a
        // crash — it is the model quietly reading a UTC timestamp or `inf`.
        for focus in HealthFocus.allCases {
            let readout = HealthReadout(
                samples: [
                    .steps: Health.samples(count: 30, unit: .count) { Double(8_000 + $0) },
                    .active_energy: Health.samples(count: 30, unit: .kilocalorie) { Double(400 + $0) },
                    .exercise_minutes: Health.samples(count: 30, unit: .minute) { Double(20 + $0) },
                    .resting_heart_rate: Health.samples(count: 30, unit: .beatsPerMinute) { Double(60 + $0 % 3) },
                    .heart_rate_variability: Health.samples(count: 30, unit: .millisecond) { Double(40 + $0 % 5) }
                ],
                sleep: (1...30).map { back in
                    let day = Health.calendar.date(byAdding: .day, value: -back, to: Health.calendar.startOfDay(for: Health.now))!
                    return SleepInterval(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(7 * 3600), asleep: true)
                },
                workouts: [WorkoutRow(activity: "Outdoor Run", start: Health.now, duration: 2_520, energyKilocalories: 486)]
            )
            let payload = await Health.payload(focus, readout: readout)
            #expect(JSONSerialization.isValidJSONObject(payload), "\(focus)")
            #expect(ToolResult.encode(payload).hasPrefix("{"), "\(focus) fell back to key: value text")
        }
    }

    @Test("sleep is reported in hours and minutes, never as a decimal count of hours")
    func sleepReadsLikeAPersonSaysIt() async {
        // "7.75 hours" is a number nobody says out loud, and a model handed one
        // converts it in the answer and gets it wrong about as often as right.
        let today = Health.calendar.startOfDay(for: Health.now)
        let intervals = (0...25).map { back -> SleepInterval in
            let morning = Health.calendar.date(byAdding: .day, value: -back, to: today)!
            let hours: Double = back == 0 ? 7.75 : 7
            return SleepInterval(start: morning.addingTimeInterval(-hours * 3600), end: morning, asleep: true)
        }
        let line = ((await Health.payload(.sleep, readout: HealthReadout(sleep: intervals)))["readings"] as? [String])?.first ?? ""
        #expect(line.contains("7 h 45 m"))
        #expect(!line.contains("7.75"))
    }

    @Test("the long-memory lines are capped, because the fourth-best thing about a week is not interesting")
    func notableIsBounded() async {
        // Five lines offered, three taken. The fixture this replaced gave each
        // of the three activity metrics one superlative and no streak — three
        // lines against a cap of three — so `prefix(notableLimit)` never once
        // truncated anything: deleting it, or moving the limit to 1 or to 9,
        // left the whole suite green. The cap is what stops a health answer
        // spending unbounded prompt tokens on trivia, so it needs a fixture that
        // overflows it.
        //
        // Steps and exercise minutes each carry a record *and* a qualifying run;
        // active energy has no streak threshold and carries only a record.
        let today = Health.calendar.startOfDay(for: Health.now)
        var samples: [HealthMetric: [HealthSample]] = [:]
        for (metric, unit, ordinary, best, second, third) in [
            (HealthMetric.steps, HealthUnit.count, 6_000.0, 20_000.0, 15_000.0, 12_000.0),
            (.active_energy, .kilocalorie, 300.0, 900.0, 300.0, 300.0),
            (.exercise_minutes, .minute, 10.0, 60.0, 45.0, 35.0)
        ] {
            samples[metric] = (1...200).reversed().map { back in
                let value: Double
                switch back {
                case 1: value = best
                case 2: value = second
                case 3: value = third
                default: value = ordinary
                }
                return HealthSample(
                    value: value, unit: unit,
                    date: Health.calendar.date(byAdding: .day, value: -back, to: today)!
                )
            }
        }

        let notable = (await Health.payload(.activity, readout: HealthReadout(samples: samples)))["notable"] as? [String] ?? []

        #expect(notable.count == 3)
        // Which three, in the order the metrics are asked about. Naming them is
        // what makes a smaller cap fail as loudly as a larger one.
        #expect(notable == [
            "Highest steps in all 200 days of step data on this iPhone, which reach back 199 days.",
            "3 days in a row over 10000 steps.",
            "Highest active energy in all 200 days of active energy data on this iPhone, which reach back 199 days."
        ])
        // The two that were dropped were real lines, not absent ones.
        #expect(!notable.contains { $0.contains("exercise") })
        #expect(!notable.contains { $0.contains("30 minutes or more") })
    }

    @Test("two consecutive days is a coincidence and three is a streak")
    func theStreakMinimumIsExactlyThreeDays() async {
        // The stated rule had no test at all: the constant could be moved to 2 —
        // shipping a two-day run as a streak — or to 5, and the suite stayed
        // green either way, bounded only by an unrelated five-night fixture.
        func notable(nights: Int) async -> [String] {
            let readout = HealthReadout(sleep: Health.nights(count: nights, hours: 8.5, endingOn: Health.now))
            return (await Health.payload(.sleep, readout: readout))["notable"] as? [String] ?? []
        }

        #expect(await notable(nights: 2).isEmpty)
        #expect(await notable(nights: 3) == ["3 nights in a row over 8 hours."])
    }

    @Test("a superlative that reaches past what the phone holds says so")
    func superlativeIsHonestAboutReach() async {
        let today = Health.calendar.startOfDay(for: Health.now)
        var series = (2...100).reversed().map { back in
            HealthSample(value: 6_000, unit: .count, date: Health.calendar.date(byAdding: .day, value: -back, to: today)!)
        }
        series.append(HealthSample(value: 25_000, unit: .count, date: Health.calendar.date(byAdding: .day, value: -1, to: today)!))

        let notable = (await Health.payload(.activity, readout: HealthReadout(samples: [.steps: series])))["notable"] as? [String] ?? []
        // Not "your best ever". The series starts 99 days ago and cannot know
        // what happened before that.
        #expect(notable.contains { $0.contains("days of step data on this iPhone") })
        #expect(!notable.contains { $0.lowercased().contains("ever") })
    }

    @Test("the superlative names how much data it has, not how far that data reaches")
    func superlativeDoesNotQuoteItsReachAsItsEvidence() async {
        // A tracker worn once in August and again this week. The old sentence
        // read "Highest step in the 39 days of step data on this iPhone" — a
        // month of history asserted from two readings, with a singular noun on
        // top of it. Both numbers are true and they are not the same number.
        let today = Health.calendar.startOfDay(for: Health.now)
        let series = [
            HealthSample(value: 3_000, unit: .count, date: Health.calendar.date(byAdding: .day, value: -40, to: today)!),
            HealthSample(value: 9_000, unit: .count, date: Health.calendar.date(byAdding: .day, value: -1, to: today)!)
        ]

        let notable = (await Health.payload(.activity, readout: HealthReadout(samples: [.steps: series])))["notable"] as? [String] ?? []
        #expect(notable == [
            "Highest steps in all 2 days of step data on this iPhone, which reach back 39 days."
        ])
    }

    @Test("the superlative reads as a sentence rather than as a column heading")
    func superlativeUsesThePluralSubject() async {
        // `noun` is attributive and right where it is used that way — "step
        // data" — and wrong carrying a clause alone: "Highest step since August
        // 2025." is what the payload used to hand a 1.7B model, which repeats a
        // finished clause rather than repairing it.
        let today = Health.calendar.startOfDay(for: Health.now)
        var series = (2...200).reversed().map { back in
            HealthSample(
                value: back == 121 ? 9_000 : 6_000, unit: .count,
                date: Health.calendar.date(byAdding: .day, value: -back, to: today)!
            )
        }
        series.append(HealthSample(value: 8_500, unit: .count, date: Health.calendar.date(byAdding: .day, value: -1, to: today)!))

        let notable = (await Health.payload(.activity, readout: HealthReadout(samples: [.steps: series])))["notable"] as? [String] ?? []
        #expect(notable.contains { $0.hasPrefix("Highest steps since ") })
        #expect(!notable.contains { $0.hasPrefix("Highest step since ") })
        // The attributive form is still the attributive form.
        #expect((await Health.payload(.activity, readout: HealthReadout(samples: [.steps: Health.samples(count: 3, unit: .count) { _ in 8_000 }])))["readings"]
            .flatMap { $0 as? [String] }?
            .contains { $0.contains("carry step data") } == true)
    }

    @Test("five nights over eight hours in a row is reported as a streak")
    func streaksReadAsSentences() async {
        let today = Health.calendar.startOfDay(for: Health.now)
        let intervals = (0...40).map { back -> SleepInterval in
            let morning = Health.calendar.date(byAdding: .day, value: -back, to: today)!
            let hours: Double = back <= 4 ? 8.5 : 6
            return SleepInterval(start: morning.addingTimeInterval(-hours * 3600), end: morning, asleep: true)
        }
        let notable = (await Health.payload(.sleep, readout: HealthReadout(sleep: intervals)))["notable"] as? [String] ?? []
        #expect(notable.contains { $0 == "5 nights in a row over 8 hours." })
    }

    @Test("a first day with only today's steps is not reported as no data")
    func todayOnlyIsItsOwnState() async {
        // The same conflation the whole file is about, one level down: someone on
        // their first day has steps, but only today's, and today is still going
        // up. Filing that under "no data came back" tells a user with a working
        // phone that their phone is not working.
        let samples = [HealthSample(value: 2_400, unit: .count, date: Health.now)]
        let payload = await Health.payload(.activity, readout: HealthReadout(samples: [.steps: samples]))
        let readings = payload["readings"] as? [String] ?? []

        #expect(readings.contains { $0.contains("only today's figures exist so far") })
        #expect((payload["no_data"] as? String)?.contains("Steps") != true)
        #expect(payload["text"] == nil)
    }

    @Test("a vital with a normal band on both sides is never given a superlative")
    func respiratoryRateClaimsNoRecord() async {
        // "Lowest respiratory rate since May" is neither good news nor bad news,
        // and presenting it as either is a clinical claim this app is not
        // entitled to make. The number is still reported against its baseline.
        let today = Health.calendar.startOfDay(for: Health.now)
        var series = (2...200).reversed().map { back in
            HealthSample(value: 15, unit: .breathsPerMinute, date: Health.calendar.date(byAdding: .day, value: -back, to: today)!)
        }
        series.append(HealthSample(value: 11.4, unit: .breathsPerMinute, date: Health.calendar.date(byAdding: .day, value: -1, to: today)!))

        let payload = await Health.payload(.sleep, readout: HealthReadout(samples: [.respiratory_rate: series]))
        let readings = payload["readings"] as? [String] ?? []
        let notable = payload["notable"] as? [String] ?? []

        // One decimal, because a breathing rate moves between 13 and 17 and
        // whole breaths throw away most of the signal.
        #expect(readings.contains { $0.contains("11.4 breaths/min") })
        #expect(!notable.contains { $0.lowercased().contains("respiratory") })
    }

    @Test("workouts are capped and the truncation is announced rather than hidden")
    func workoutRowsAreBounded() async {
        let rows = (0..<20).map { index in
            WorkoutRow(
                activity: "Outdoor Run",
                start: Health.now.addingTimeInterval(Double(-index) * 3600),
                duration: 1_800,
                energyKilocalories: 300
            )
        }
        let payload = await Health.payload(.workouts, readout: HealthReadout(workouts: rows))

        #expect((payload["workouts"] as? [String])?.count == HealthSummary.rowLimit)
        #expect((payload["note"] as? String)?.contains("there are more") == true)
    }

    @Test("a workout logged with no energy does not report burning nothing")
    func missingEnergyIsOmitted() async {
        let payload = await Health.payload(.workouts, readout: HealthReadout(
            workouts: [WorkoutRow(activity: "Yoga", start: Health.now, duration: 2_700)]
        ))
        let line = (payload["workouts"] as? [String])?.first ?? ""
        #expect(line.contains("45 m"))
        #expect(!line.contains("kcal"))
        #expect(!line.contains("0 kcal"))
    }

    @Test("workouts come back most recent first")
    func workoutsAreOrdered() async {
        let older = WorkoutRow(activity: "Yoga", start: Health.now.addingTimeInterval(-7_200), duration: 1_800)
        let newer = WorkoutRow(activity: "Outdoor Run", start: Health.now, duration: 1_800)
        let payload = await Health.payload(.workouts, readout: HealthReadout(workouts: [older, newer]))
        #expect((payload["workouts"] as? [String])?.first?.hasPrefix("Outdoor Run") == true)
    }
}

@Suite("Health summary: when the reading is from")
struct HealthSummaryRecencyTests {

    @Test("five nights in a row is reported in June and is not reported in September")
    func aStreakIsNotAnnouncedOnceItHasStopped() async {
        // One readout, two clocks. The June call proves the line exists, so the
        // September call is asserting a suppression rather than an absence — an
        // empty `notable` on its own passes just as well when the whole feature
        // has been deleted.
        let readout = HealthReadout(sleep: Health.nights(count: 5, hours: 8.5, endingOn: Health.june))

        let inJune = (await Health.payload(.sleep, asOf: Health.june, readout: readout))["notable"] as? [String] ?? []
        #expect(inJune.contains { $0 == "5 nights in a row over 8 hours." })

        let inSeptember = await Health.payload(.sleep, readout: readout)
        #expect(inSeptember["notable"] == nil)
    }

    @Test("a record set in June is not read out in September as if it were last night")
    func aSuperlativeIsNotAnnouncedOnceItHasStopped() async {
        // The other half of the same sentence, and the one that is literally true
        // and still wrong: nothing higher *has* been recorded since, so "highest
        // sleep in the 199 days on this iPhone" survives any check for accuracy.
        // It is heard as a claim about last night, and it is three months old.
        let june = Health.calendar.startOfDay(for: Health.june)
        var series = (2...200).reversed().map { back in
            HealthSample(value: 6_000, unit: .count, date: Health.calendar.date(byAdding: .day, value: -back, to: june)!)
        }
        series.append(HealthSample(value: 25_000, unit: .count, date: Health.calendar.date(byAdding: .day, value: -1, to: june)!))
        let readout = HealthReadout(samples: [.steps: series])

        let inJune = (await Health.payload(.activity, asOf: Health.june, readout: readout))["notable"] as? [String] ?? []
        #expect(inJune.contains { $0.contains("days of step data on this iPhone") })

        let inSeptember = await Health.payload(.activity, readout: readout)
        #expect(inSeptember["notable"] == nil)
    }

    @Test("a months-old reading carries its year and says how old it is")
    func aStaleReadingIsDatedAndAged() async {
        // `PersonalDataFormat.day` prints no year, by design — for a reminder due
        // on Thursday that is right. Here it means a reading from last June and
        // one from the June before are the same eight characters, and both read
        // as this week to a model that is told nothing else.
        let readout = HealthReadout(sleep: Health.nights(count: 5, hours: 8.5, endingOn: Health.june))

        let inJune = (await Health.payload(.sleep, asOf: Health.june, readout: readout))["readings"] as? [String] ?? []
        let freshLine = inJune.first { $0.hasPrefix("Sleep") } ?? ""
        #expect(freshLine.contains("Jun 12"))
        #expect(!freshLine.contains("2025"))
        #expect(!freshLine.contains("days old"))

        let inSeptember = (await Health.payload(.sleep, readout: readout))["readings"] as? [String] ?? []
        let staleLine = inSeptember.first { $0.hasPrefix("Sleep") } ?? ""
        #expect(staleLine.contains("Jun 12"))
        #expect(staleLine.contains("2025"))
        #expect(staleLine.contains("91 days old"))
        #expect(staleLine.contains("does not describe today"))
    }

    @Test("a sleep record dated tomorrow does not become last night's reading")
    func futureDatedSleepIsNotTheReading() async {
        // The one on this list a user would actually notice. The sleep window
        // reaches tomorrow's midnight on purpose, so that a night ending this
        // morning is read whole; nothing validates the date a third-party app
        // writes on a sample; and thirteen hours is comfortably under the
        // plausibility cap. So a record running from this evening to tomorrow
        // morning comes back, keys on tomorrow, and — unbounded — becomes THE
        // reading: a night that has not happened, dated tomorrow, in the present
        // tense, with no staleness note, and this morning's real eight hours
        // never mentioned at all.
        let today = Health.calendar.startOfDay(for: Health.now)
        let tomorrow = Health.calendar.date(byAdding: .day, value: 1, to: today)!
        let intervals = Health.nights(count: 30, hours: 8, endingOn: Health.now) + [
            SleepInterval(
                start: today.addingTimeInterval(20 * 3600),
                end: tomorrow.addingTimeInterval(9 * 3600),
                asleep: true
            )
        ]

        let payload = await Health.payload(.sleep, readout: HealthReadout(sleep: intervals))
        let sleepLine = (payload["readings"] as? [String])?.first { $0.hasPrefix("Sleep") } ?? ""

        #expect(sleepLine.contains("Sleep 8 h on Thu, Sep 11"))
        #expect(!sleepLine.contains("13 h"))
        // Nowhere in the payload, not merely absent from the headline: a
        // superlative or a percentage built on the same night is the same lie
        // one clause further down.
        let rendered = ToolResult.encode(payload)
        #expect(!rendered.contains("Sep 12"))
        #expect(!rendered.contains("13 h"))
    }

    @Test("today's unfinished steps do not break a streak the finished days prove")
    func streaksAreJudgedOnFinishedDaysOnly() async {
        // A phone always has some steps for today, so before this the 10,000-step
        // and 30-minute streak lines could not fire at all in production: at nine
        // in the morning every streak is broken by a number that is still going
        // up. The reading line already knew this; the long memory did not.
        var series = Health.samples(count: 40, unit: .count) { _ in 12_000 }
        series.append(HealthSample(value: 1_200, unit: .count, date: Health.now))

        let payload = await Health.payload(.activity, readout: HealthReadout(samples: [.steps: series]))
        let notable = payload["notable"] as? [String] ?? []
        #expect(notable.contains { $0 == "40 days in a row over 10000 steps." })

        // And the figure beside it is still the last finished day, not today's.
        let readings = payload["readings"] as? [String] ?? []
        #expect(readings.contains { $0.hasPrefix("Steps 12000 on") })
        #expect(!readings.contains { $0.contains("1,200") })
    }

    @Test("a two-day-old reading says so in a zone whose clocks go forward at midnight")
    func stalenessSurvivesAZoneThatShiftsAtMidnight() async {
        // The staleness note and the whole long-memory currency gate are both
        // counted with `dayGap`, which came back one short for any span starting
        // on a day that has no 00:00 — Chile, Cuba, Lebanon, Brazil, Iran. So on
        // one day a year per zone a two-day-old figure was dated without its
        // year, carried no age note, and kept its streak line: exactly the "a
        // June streak read out in September" failure the rest of this suite
        // exists to close, reopened by an hour of arithmetic.
        let santiago = TimeZone(identifier: "America/Santiago")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = santiago
        calendar.firstWeekday = 2

        func at(_ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: hour))!
        }
        // The premise, stated rather than assumed.
        #expect(calendar.startOfDay(for: at(9, 7, 12)) == at(9, 7, 1))

        let lastMorning = calendar.startOfDay(for: at(9, 7, 12))
        let intervals = (0..<30).map { back -> SleepInterval in
            let morning = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -back, to: lastMorning)!)
            return SleepInterval(start: morning.addingTimeInterval(-8 * 3600), end: morning, asleep: true)
        }

        let payload = await HealthSummary.payload(
            focus: .sleep, now: at(9, 9, 10), calendar: calendar, locale: Health.english,
            timeZone: santiago, origin: .onDeviceChat,
            read: { _, _ in HealthReadout(sleep: intervals) }
        )
        let line = (payload["readings"] as? [String])?.first { $0.hasPrefix("Sleep") } ?? ""

        #expect(line.contains("Sun, Sep 7, 2025"))
        #expect(line.contains("That reading is 2 days old"))
        #expect(line.contains("does not describe today"))
        // And the run of thirty nights is not still being announced in the
        // present tense two days after the last one.
        #expect(payload["notable"] == nil)
    }

    @Test("today's unfinished steps do not swallow yesterday's record either")
    func superlativesAreJudgedOnFinishedDaysOnly() async {
        // The same truncation seen from the other side: judged against a morning's
        // worth of steps, yesterday's 25,000 is no longer the last day in the
        // series and the superlative silently stops being computed about it.
        let today = Health.calendar.startOfDay(for: Health.now)
        var series = Health.samples(count: 199, unit: .count, endingDaysBack: 2) { _ in 6_000 }
        series.append(HealthSample(value: 25_000, unit: .count, date: Health.calendar.date(byAdding: .day, value: -1, to: today)!))
        series.append(HealthSample(value: 1_200, unit: .count, date: Health.now))

        let notable = (await Health.payload(.activity, readout: HealthReadout(samples: [.steps: series])))["notable"] as? [String] ?? []
        #expect(notable.contains { $0.contains("days of step data on this iPhone") })
    }
}

@Suite("Health summary: the window handed to the store")
struct HealthSummaryWindowTests {

    @Test("the focus reaches the store, along with the window it names")
    func focusAndWindowReachTheStore() async {
        for focus in HealthFocus.allCases {
            let spy = HealthReadSpy()
            _ = await HealthSummary.payload(
                focus: focus, now: Health.now, calendar: Health.calendar, locale: Health.english,
                timeZone: Health.utc, origin: .onDeviceChat, read: { await spy.read($0, $1) }
            )
            #expect(await spy.lastFocus == focus)
            #expect(await spy.lastWindow == HealthSummary.window(for: focus, now: Health.now, calendar: Health.calendar))
        }
    }

    @Test("the window is counted in calendar days, not in multiples of 86,400")
    func windowIsCalendarArithmetic() {
        // Six months back from September in London starts in GMT and ends in
        // BST, so the window is an hour short of 181 flat days. Multiplying
        // instead of asking the calendar puts the oldest bucket boundary an hour
        // into the day before it, which drops that day's samples entirely.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2025, month: 9, day: 11, hour: 10))!
        let today = calendar.startOfDay(for: now)

        let window = HealthSummary.window(for: .sleep, now: now, calendar: calendar)
        #expect(window.start == calendar.date(byAdding: .day, value: -HealthFocus.sleep.historyDays, to: today))
        #expect(window.duration == Double(HealthFocus.sleep.historyDays + 1) * 86_400 - 3_600)

        // Three years lands on the same side of the clock change, so the flat
        // multiplication happens to agree — which is exactly why the shorter
        // window is the one worth asserting on. The date is still checked.
        let long = HealthSummary.window(for: .activity, now: now, calendar: calendar)
        #expect(long.start == calendar.date(byAdding: .day, value: -HealthFocus.activity.historyDays, to: today))
    }

    @Test("the window closes at tomorrow's midnight so today's partial data is still read")
    func windowIncludesToday() {
        // Whether an unfinished day may be *reported* is decided per metric, and
        // truncating the query here would take that decision away.
        let window = HealthSummary.window(for: .sleep, now: Health.now, calendar: Health.calendar)
        #expect(window.end == Health.calendar.date(byAdding: .day, value: 1, to: Health.calendar.startOfDay(for: Health.now)))
        #expect(window.contains(Health.now))
    }

    @Test("sleep is asked for a shorter history than the quantity metrics")
    func sleepReachIsBoundedByVolume() {
        // Not policy: sleep arrives as raw stage samples, twenty to sixty a night,
        // and three years of those is tens of thousands of objects to marshal
        // inside a chat turn. The superlative reports which claim it is making.
        #expect(HealthFocus.sleep.historyDays < HealthFocus.activity.historyDays)
        #expect(HealthFocus.sleep.historyDays > HealthArithmetic.baselineWindowDays + HealthArithmetic.superlativeMinimumGapDays)
    }

    @Test("one tool covers every metric, so the schema is paid for once")
    func oneToolCoversEverything() {
        // Registering a tool injects its schema into every prompt — roughly 110
        // guard tokens, doubled on a tool-native template — against a usable
        // window of 4032. Five health tools would be most of a thousand tokens
        // spent before the user typed anything.
        let covered = Set(HealthFocus.allCases.flatMap(\.metrics))
        #expect(covered == Set(HealthMetric.allCases))
    }
}

@Suite("Health numbers read the same in every locale")
struct HealthNumberLocaleTests {
    @Test("a count never carries a grouping separator or a non-ASCII digit")
    func groupingNeverReachesTheModel() {
        // The payload is read by a 1.7B model, not by a person. German renders
        // 12000 as "12.000", which reads as twelve; French inserts U+202F
        // inside the digits; Arabic emits a different numeral system entirely.
        // One misread number here is a wrong answer about somebody's body.
        for identifier in ["en_US", "de_DE", "fr_FR", "ar_EG", "hi_IN"] {
            let rendered = HealthFormat.number(12000, digits: 0, locale: Locale(identifier: identifier))
            // Computed outside the macro: `allSatisfy` is rethrows, and the
            // expansion will not accept a possibly-throwing call.
            let isASCII = rendered.unicodeScalars.allSatisfy { $0.isASCII }
            #expect(rendered == "12000", "\(identifier) rendered \(rendered)")
            #expect(isASCII, "\(identifier) emitted non-ASCII digits")
        }
    }

    @Test("fractional precision still works")
    func precisionSurvives() {
        #expect(HealthFormat.number(72.46, digits: 1, locale: Locale(identifier: "de_DE")) == "72.5")
    }
}

@Suite("Health summary: the metrics added after the first eight")
struct HealthAddedMetricPayloadTests {

    @Test("each one computes a baseline and a delta of its own")
    func addedMetricsCompareAgainstTheirOwnBaseline() async {
        // The arithmetic is generic, so what is being checked here is the data:
        // a wrong unit drops every sample and produces no line at all, a wrong
        // aggregation produces a figure nobody has, and a wrong number of
        // decimals produces a comparison the user cannot check. Each row is
        // read in the metric's own declared unit, so the fixture cannot agree
        // with the code by accident.
        let cases: [(metric: HealthMetric, focus: HealthFocus, usual: Double, spread: Double, latest: Double, figure: String, mean: String, delta: String)] = [
            (.distance, .activity, 5, 0.5, 6, "6.0 km", "5.0 km", "20% above"),
            (.stand_hours, .activity, 10, 1, 12, "12", "10", "20% above"),
            (.heart_rate, .heart, 70, 3, 84, "84 bpm", "70 bpm", "20% above"),
            (.blood_oxygen, .heart, 0.96, 0.005, 0.98, "98.0%", "96.0%", "2% above"),
            (.mindful_minutes, .sleep, 600, 60, 900, "15 m", "10 m", "50% above"),
            (.body_mass, .body, 72, 0.5, 75.6, "75.6 kg", "72.0 kg", "5% above"),
            (.vo2_max, .body, 40, 1, 44, "44.0 mL/kg·min", "40.0 mL/kg·min", "10% above")
        ]

        let yesterday = Health.calendar.date(
            byAdding: .day, value: -1, to: Health.calendar.startOfDay(for: Health.now)
        )!

        for row in cases {
            // 28 whole days ending the day before the reading, so the reading is
            // not folded into the mean it is measured against.
            var samples = Health.samples(count: 28, unit: row.metric.unit, endingDaysBack: 2) { back in
                back % 2 == 0 ? row.usual - row.spread : row.usual + row.spread
            }
            samples.append(HealthSample(value: row.latest, unit: row.metric.unit, date: yesterday))

            let payload = await Health.payload(row.focus, readout: HealthReadout(samples: [row.metric: samples]))
            let line = (payload["readings"] as? [String])?.first { $0.hasPrefix(row.metric.label) } ?? ""

            #expect(line.contains("\(row.metric.label) \(row.figure) on"), "\(row.metric): \(line)")
            #expect(line.contains("\(row.delta) your 28-day average of \(row.mean)"), "\(row.metric): \(line)")
        }
    }

    @Test("at nine in the morning the distance reported is yesterday's whole day")
    func thisMorningsDistanceIsNotTheReading() async {
        // The partial-day bug, end to end and in the payload the model actually
        // reads. Without the accumulation rule this line is "Distance 0.4 km on
        // Thu, Sep 11 — 93% below your 28-day average", every morning, to
        // somebody who has simply not been out yet.
        let nineAm = Health.calendar.date(from: DateComponents(year: 2025, month: 9, day: 11, hour: 9))!
        var samples = Health.samples(count: 28, unit: .kilometer) { _ in 6 }
        samples.append(HealthSample(value: 0.4, unit: .kilometer, date: Health.calendar.startOfDay(for: nineAm)))

        let payload = await Health.payload(
            .activity, asOf: nineAm, readout: HealthReadout(samples: [.distance: samples])
        )
        let line = (payload["readings"] as? [String])?.first { $0.hasPrefix("Distance") } ?? ""

        #expect(line.contains("Distance 6.0 km on Wed, Sep 10"))
        #expect(!line.contains("0.4"))
        #expect(!line.contains("below"))
    }

    @Test("a weight higher than any on this phone is reported without being called a record")
    func weightIsNeverASuperlative() async {
        // Two hundred days of it, the last the highest there has ever been —
        // the exact shape that fires a superlative for any metric with a better
        // end. Nothing but `direction` stands between this payload and "highest
        // weight in all 201 days of weight data on this iPhone", which is a
        // judgement about somebody's body dressed as a milestone.
        let yesterday = Health.calendar.date(
            byAdding: .day, value: -1, to: Health.calendar.startOfDay(for: Health.now)
        )!

        func rising(unit: HealthUnit, usual: Double, spread: Double, peak: Double) -> [HealthSample] {
            var samples = Health.samples(count: 200, unit: unit, endingDaysBack: 2) { back in
                back % 2 == 0 ? usual - spread : usual + spread
            }
            samples.append(HealthSample(value: peak, unit: unit, date: yesterday))
            return samples
        }

        let weight = await Health.payload(.body, readout: HealthReadout(
            samples: [.body_mass: rising(unit: .kilogram, usual: 72, spread: 0.5, peak: 78)]
        ))
        #expect((weight["readings"] as? [String])?.contains { $0.contains("Weight 78.0 kg") } == true)
        #expect(weight["notable"] == nil)

        // The same shape through VO2 max, which does have a better end, so the
        // silence above is the direction and not the fixture.
        let vo2 = await Health.payload(.body, readout: HealthReadout(
            samples: [.vo2_max: rising(unit: .millilitersPerKilogramMinute, usual: 40, spread: 1, peak: 48)]
        ))
        #expect((vo2["notable"] as? [String])?.contains { $0.hasPrefix("Highest VO2 max") } == true)
    }

    @Test("blood oxygen reaches the model as a percentage and never as a fraction")
    func bloodOxygenIsNeverAFractionInThePayload() async {
        // 0.98 is a number a model will read as 0.98 percent, or as a ratio, or
        // narrate unchanged. The value is kept in HealthKit's own magnitude
        // everywhere the unit tag can still catch a mistake, and turned into a
        // percentage at the last possible moment — which means the last possible
        // moment has to be before the payload is encoded.
        var samples = Health.samples(count: 28, unit: .fractionOfOne, endingDaysBack: 2) { back in
            back % 2 == 0 ? 0.955 : 0.965
        }
        let yesterday = Health.calendar.date(
            byAdding: .day, value: -1, to: Health.calendar.startOfDay(for: Health.now)
        )!
        samples.append(HealthSample(value: 0.98, unit: .fractionOfOne, date: yesterday))

        let rendered = ToolResult.encode(
            await Health.payload(.heart, readout: HealthReadout(samples: [.blood_oxygen: samples]))
        )
        #expect(rendered.contains("Blood oxygen 98.0%"))
        #expect(rendered.contains("average of 96.0%"))
        #expect(!rendered.contains("0.9"))
    }
}

@Suite("Health permissions: what the sheet asks for")
struct HealthPermissionSheetTests {

    /// Counted against the app rather than against a fixture of it.
    ///
    /// `HealthAccess` cannot be imported here — it needs HealthKit, and these
    /// tests run on macOS with no Health store to have — but the read set it
    /// asks for is the one part of it a user sees, listed by name on a modal
    /// sheet. A type requested and never read is the single thing that makes
    /// that sheet look like a data grab, and a metric with no type behind it is
    /// a row of the answer that silently never arrives. So the source is read,
    /// the way `AnswerCardTests` reads the app's tool registrations.
    @Test("sixteen HealthKit types are named, one for every metric plus workouts")
    func theReadSetIsWhatItClaims() throws {
        let source = try String(contentsOf: healthAccessSource(), encoding: .utf8)
        let quantity = identifiers(matching: #"HKQuantityType\(\.(\w+)\)"#, in: source)
        let category = identifiers(matching: #"HKCategoryType\(\.(\w+)\)"#, in: source)

        #expect(quantity == [
            "stepCount", "activeEnergyBurned", "appleExerciseTime", "distanceWalkingRunning",
            "restingHeartRate", "heartRateVariabilitySDNN", "walkingHeartRateAverage", "heartRate",
            "oxygenSaturation", "respiratoryRate", "bodyMass", "vo2Max"
        ])
        // Three, and no more: sleep, a stand hour and a mindful session are the
        // only things this app reads that HealthKit does not keep as a quantity.
        #expect(category == ["sleepAnalysis", "appleStandHour", "mindfulSession"])
        #expect(source.contains("HKObjectType.workoutType()"))

        // One type per metric, plus the workouts that are not a metric at all.
        #expect(quantity.count + category.count == HealthMetric.allCases.count)
        #expect(quantity.count + category.count + 1 == 16)
    }

    @Test("nothing is asked for write access, because nothing writes")
    func theShareSetIsEmpty() throws {
        // Both authorization calls, counted rather than eyeballed. A non-empty
        // share set puts a second sheet in front of the user, listing types this
        // app would be allowed to change — for a capability it does not have.
        let source = try String(contentsOf: healthAccessSource(), encoding: .utf8)
        let shared = matches(of: #"requestAuthorization\(toShare: (\[[^\]]*\]), read:"#, in: source)

        #expect(shared == ["[]", "[]"])
        #expect(source.components(separatedBy: "requestAuthorization(").count - 1 == shared.count)
    }

    @Test("no sentence anywhere in the read path claims the user refused anything")
    func nothingClaimsADenial() throws {
        // iOS reports a refused read and a type nobody ever recorded
        // identically, so any word that picks one is a guess presented as a
        // fact. The rule is worth restating against the source because it is the
        // kind of thing a helpful sentence added later quietly breaks.
        let source = try String(contentsOf: healthAccessSource(), encoding: .utf8)
        for word in ["denied", "Denied", "refused access", "not authorized", "not authorised"] {
            #expect(!source.contains(word), "\(word) appears in HealthAccess.swift")
        }
    }
}

/// The app-side file these tests read, from this one.
private func healthAccessSource() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PocketdKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("App/Sources/Tools/HealthAccess.swift")
}

/// Every first capture group of `pattern`, in the order they appear.
private func matches(of pattern: String, in source: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
        Range(match.range(at: 1), in: source).map { String(source[$0]) }
    }
}

private func identifiers(matching pattern: String, in source: String) -> Set<String> {
    Set(matches(of: pattern, in: source))
}
