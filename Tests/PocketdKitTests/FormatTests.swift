import Foundation
import Testing
@testable import PocketdKit

/// The one set of on-screen formats.
///
/// Each of these was spelled at least two ways somewhere in the app before it
/// existed, so each test pins the shape a person sees — and the edges where a
/// formatter written in a hurry goes wrong: a countdown that says "in 0m", a
/// lakh where a million was meant, a padded minute in the middle of a sentence.
@Suite("Formats")
struct FormatTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let us = Locale(identifier: "en_US")
    static let uk = Locale(identifier: "en_GB")
    static let india = Locale(identifier: "en_IN")

    static func date(_ hour: Int, _ minute: Int = 0, day: Int = 21) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// The narrow no-break space ICU puts before AM/PM, as a plain space, so
    /// the expectations read the way the screen does.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - Durations

    @Test("an hour or more is the compact pair; under an hour says min")
    func durations() {
        #expect(Format.duration(6 * 3600 + 36 * 60) == "6h 36m")
        #expect(Format.duration(7 * 3600 + 5 * 60) == "7h 5m")
        #expect(Format.duration(2 * 3600) == "2h")
        #expect(Format.duration(45 * 60) == "45 min")
        #expect(Format.duration(29 * 60) == "29 min")
    }

    @Test("a padded duration is only for a column")
    func paddedDurations() {
        #expect(Format.duration(7 * 3600 + 5 * 60, padded: true) == "7h 05m")
        #expect(Format.duration(6 * 3600 + 36 * 60, padded: true) == "6h 36m")
        // Under an hour there is no `h` to keep in line, so nothing changes.
        #expect(Format.duration(45 * 60, padded: true) == "45 min")
    }

    @Test("minutes round to the nearest, and nothing is ever negative or empty")
    func durationEdges() {
        #expect(Format.duration(6 * 3600 + 35 * 60 + 40) == "6h 36m")
        #expect(Format.duration(59 * 60 + 40) == "1h")
        #expect(Format.duration(20) == "0 min")
        #expect(Format.duration(0) == "0 min")
        #expect(Format.duration(-300) == "0 min")
        #expect(Format.duration(.nan) == "0 min")
        #expect(Format.duration(.infinity) == "0 min")
    }

    // MARK: - Times

    @Test("times follow the locale's own clock")
    func times() {
        let oneOClock = Self.date(13, 5)
        #expect(Self.plain(Format.time(oneOClock, calendar: Self.calendar, locale: Self.us)) == "1:05 PM")
        #expect(Format.time(oneOClock, calendar: Self.calendar, locale: Self.uk) == "13:05")
    }

    // MARK: - Counts

    @Test("counts are grouped the way the phone groups them")
    func counts() {
        #expect(Format.count(4_120.0, locale: Self.us) == "4,120")
        #expect(Format.count(4_120, locale: Self.us) == "4,120")
        #expect(Format.count(4_119.6, locale: Self.us) == "4,120")
        #expect(Format.count(.nan, locale: Self.us) == "—")
    }

    @Test("a counted noun uses digits and the right plural")
    func counted() {
        #expect(Format.counted(1, "event", locale: Self.us) == "1 event")
        #expect(Format.counted(3, "event", locale: Self.us) == "3 events")
        #expect(Format.counted(0, "reminder", locale: Self.us) == "0 reminders")
        #expect(Format.counted(2, "person", "people", locale: Self.us) == "2 people")
        #expect(Format.counted(4_120, "step", locale: Self.us) == "4,120 steps")
    }

    // MARK: - Relative

    @Test("a countdown rounds up and never says in 0")
    func relativeFuture() {
        let now = Self.date(9, 41)
        #expect(Format.relative(now.addingTimeInterval(2 * 3600 + 10 * 60), from: now) == "in 2h 10m")
        #expect(Format.relative(now.addingTimeInterval(3 * 3600 + 19 * 60), from: now) == "in 3h 19m")
        #expect(Format.relative(now.addingTimeInterval(5 * 60), from: now) == "in 5 min")
        // Twenty seconds out is a minute away, not "now" and not "in 0".
        #expect(Format.relative(now.addingTimeInterval(20), from: now) == "in 1 min")
        #expect(Format.relative(now.addingTimeInterval(4 * 60 + 1), from: now) == "in 5 min")
    }

    @Test("the past rounds down and the present is now")
    func relativePast() {
        let now = Self.date(9, 41)
        #expect(Format.relative(now, from: now) == "now")
        #expect(Format.relative(now.addingTimeInterval(-30), from: now) == "now")
        #expect(Format.relative(now.addingTimeInterval(-90), from: now) == "1 min ago")
        #expect(Format.relative(now.addingTimeInterval(-(2 * 3600 + 10 * 60)), from: now) == "2h 10m ago")
    }

    // MARK: - Compact

    @Test("compact figures use K, M and B, and never lakh")
    func compact() {
        #expect(Format.compact(950, locale: Self.us) == "950")
        #expect(Format.compact(1_200, locale: Self.us) == "1.2K")
        #expect(Format.compact(2_000, locale: Self.us) == "2K")
        #expect(Format.compact(64_000, locale: Self.us) == "64K")
        #expect(Format.compact(6_400_000, locale: Self.us) == "6.4M")
        #expect(Format.compact(1_100_000_000, locale: Self.us) == "1.1B")
        // The case this function exists for: English (India) asks for lakh
        // and crore, and a download count is not a newspaper.
        #expect(Format.compact(6_400_000, locale: Self.india) == "6.4M")
        #expect(Format.compact(64_000, locale: Self.india) == "64K")
        #expect(!Format.compact(6_400_000, locale: Self.india).contains("L"))
        #expect(!Format.compact(45_000_000, locale: Self.india).contains("Cr"))
    }

    @Test("a figure about to round up to the next unit moves up to it")
    func compactRollover() {
        #expect(Format.compact(999_950, locale: Self.us) == "1M")
        #expect(Format.compact(9_960, locale: Self.us) == "10K")
        #expect(Format.compact(-1_500, locale: Self.us) == "-1.5K")
    }

    // MARK: - Days

    @Test("days near today are named, further ones are dated")
    func days() {
        let now = Self.date(9)
        #expect(Format.day(Self.date(18, day: 21), relativeTo: now, calendar: Self.calendar, locale: Self.uk) == "Today")
        #expect(Format.day(Self.date(18, day: 20), relativeTo: now, calendar: Self.calendar, locale: Self.uk) == "Yesterday")
        #expect(Format.day(Self.date(8, day: 22), relativeTo: now, calendar: Self.calendar, locale: Self.uk) == "Tomorrow")
        // 19 Oct 2026 is a Monday.
        #expect(Format.day(Self.date(8, day: 19), relativeTo: now, calendar: Self.calendar, locale: Self.uk) == "Monday")
        #expect(Format.day(Self.date(8, day: 2), relativeTo: now, calendar: Self.calendar, locale: Self.uk) == "Fri 2 Oct")
    }

    @Test("a day inside a sentence is lower-case and takes on")
    func dayPhrases() {
        let now = Self.date(9)
        #expect(Format.dayPhrase(Self.date(18, day: 20), relativeTo: now, calendar: Self.calendar, locale: Self.uk) == "yesterday")
        #expect(Format.dayPhrase(Self.date(8, day: 19), relativeTo: now, calendar: Self.calendar, locale: Self.uk) == "on Monday")
        #expect(Format.dayPhrase(Self.date(8, day: 2), relativeTo: now, calendar: Self.calendar, locale: Self.uk) == "on Fri 2 Oct")
    }

    @Test("a day gap counts midnights, not seconds")
    func dayGap() {
        #expect(Format.dayGap(from: Self.date(23, 59), to: Self.date(0, 1, day: 22), calendar: Self.calendar) == 1)
        #expect(Format.dayGap(from: Self.date(0, 1), to: Self.date(23, 59), calendar: Self.calendar) == 0)
        #expect(Format.dayGap(from: Self.date(9), to: Self.date(9, day: 14), calendar: Self.calendar) == -7)
    }

    @Test("nothing on screen is spelled out in words")
    func neverSpelledOut() {
        // A sample of everything above, checked for the failure the walkthrough
        // photographed: a time in words on the home tab.
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "twenty", "fifty"]
        let samples = [
            Format.duration(6 * 3600 + 36 * 60),
            Format.relative(Self.date(13), from: Self.date(9, 41)),
            Self.plain(Format.time(Self.date(11, 57), calendar: Self.calendar, locale: Self.us)),
            Format.counted(2, "reminder", locale: Self.us),
            Format.compact(64_000, locale: Self.us),
        ]
        for sample in samples {
            for word in words {
                #expect(!sample.lowercased().contains(word), "\(sample) spells out \(word)")
            }
        }
    }
}
