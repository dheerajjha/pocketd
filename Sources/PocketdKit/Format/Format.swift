import Foundation

/// Every number, time and length of time a person reads on screen, written one
/// way.
///
/// One set, because the walkthrough of this app found the same quantity spelled
/// four ways on four screens — "6h 36m", "6 h 12 m", "seven hours and ten
/// minutes", "18:00" beside "6:00 PM", and "64L downloads" on a phone set to
/// English (India) — and every one of those was a formatter written inline by
/// whoever needed a number that afternoon. A reader does not know they are
/// different screens; they only see an app that cannot decide how long an hour
/// is.
///
/// What this is **not** for: anything a model reads. `HealthFormat` and
/// `PersonalDataFormat` stay exactly as they are, because a 1.7B model reads
/// "12.000" as twelve and "6h 36m" back as "six thirty-six" — both of them are
/// deliberate, documented departures from what a person wants, and the two
/// audiences need two spellings. Speech is the other exception: a sentence read
/// aloud may spell a number out, a sentence on screen never does.
///
/// Every function takes its `Calendar` and `Locale` as parameters, defaulted to
/// the current ones, so a test can pin both and a screenshot can pin the clock.
public enum Format {

    // MARK: - Durations

    /// `6h 36m`, `7h 5m`, `2h`, `45 min`.
    ///
    /// Two shapes either side of an hour, and that is the readable choice rather
    /// than an inconsistent one. "45m" in a sentence reads as a typo for metres;
    /// "45 min" does not. Above an hour the compact pair is what every clock app
    /// and the Health app itself print, and "6 hr 36 min" is a line that wraps
    /// on a tile.
    ///
    /// Minutes are rounded to the nearest, so 6h 35m 40s is "6h 36m" — the
    /// figure the Health app shows for the same night. Anything under thirty
    /// seconds is "0 min", never an empty string and never a negative.
    ///
    /// - Parameter padded: `7h 05m` instead of `7h 5m`. For a right-aligned
    ///   monospaced column, where an unpadded minute makes the `h` jump a column
    ///   between rows. Never for prose.
    public static func duration(_ seconds: TimeInterval, padded: Bool = false) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let minutes = Int((seconds / 60).rounded())
        return minutesText(minutes, padded: padded)
    }

    /// The same shape, from a whole number of minutes. Shared so that a delta
    /// and a duration can never round differently.
    static func minutesText(_ minutes: Int, padded: Bool) -> String {
        guard minutes > 0 else { return "0 min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        guard hours > 0 else { return "\(remainder) min" }
        guard remainder > 0 else { return "\(hours)h" }
        return padded ? String(format: "%dh %02dm", hours, remainder) : "\(hours)h \(remainder)m"
    }

    // MARK: - Times

    /// `6:00 PM` or `18:00`, whichever this phone's locale says.
    ///
    /// `.shortened` rather than a `dateFormat` string, because a hardcoded
    /// `HH:mm` prints 18:00 to somebody whose phone has said 6 PM for ten years.
    /// The separator before AM/PM is whatever the locale uses — on current
    /// systems a narrow no-break space, which is also what stops "6:00" and "PM"
    /// landing on two lines of a tile.
    public static func time(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        )
    }

    // MARK: - Counts

    /// `4,120`. Grouped and localised: this is read by the person whose phone
    /// it is, not by a model.
    public static func count(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        return value.rounded().formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    public static func count(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    /// `1 event`, `3 events`, `4,120 steps`.
    ///
    /// The plural is passed rather than derived, because English plurals are
    /// not all an `s` and a derived one is how "1 overdues" happens. Digits,
    /// always: "one reminder" belongs to speech.
    public static func counted(_ value: Int, _ singular: String, _ plural: String? = nil, locale: Locale = .current) -> String {
        "\(count(value, locale: locale)) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    // MARK: - Relative

    /// `in 2h 10m`, `in 5 min`, `now`, `25 min ago`.
    ///
    /// Rendered rather than left to `Text(_:style: .relative)`, because "in 2
    /// hours" rounds away the ten minutes that decide whether somebody leaves
    /// now, and because these strings are also stored and read by a second
    /// process.
    ///
    /// The future rounds **up** and the past rounds down. A meeting 20 seconds
    /// away is "in 1 min", never "in 0 min" and never "now" before it has
    /// started; something that happened 90 seconds ago is "1 min ago", not
    /// "2 min ago".
    public static func relative(_ date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite else { return "now" }
        if seconds > 0 {
            return "in " + minutesText(Int((seconds / 60).rounded(.up)), padded: false)
        }
        let minutes = Int((-seconds / 60).rounded(.down))
        guard minutes > 0 else { return "now" }
        return minutesText(minutes, padded: false) + " ago"
    }

    // MARK: - Compact

    /// `950`, `1.2K`, `64K`, `6.4M`, `1.1B` — and never `64L`.
    ///
    /// Not `.notation(.compactName)`. That asks the locale for its own compact
    /// units, and English (India) answers in lakh and crore: 6,400,000 becomes
    /// "64L", which is right in a newspaper in Pune and unreadable on a model
    /// download count for everybody else holding the same phone. Thousands,
    /// millions and billions are the units every app store and every download
    /// counter uses, so they are the units here, with the locale's own decimal
    /// separator and at most one decimal place.
    public static func compact(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        let units: [(threshold: Double, suffix: String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (index, unit) in units.enumerated() where magnitude >= unit.threshold {
            let scaled = magnitude / unit.threshold
            // 999,950 would round to "1000K"; promote it to the next unit up so
            // the figure always has at most three digits before the suffix.
            if scaled.rounded(toPlaces: scaled < 10 ? 1 : 0) >= 1000, index > 0 {
                return sign + mantissa(scaled / 1000, locale: locale) + units[index - 1].suffix
            }
            return sign + mantissa(scaled, locale: locale) + unit.suffix
        }
        return sign + count(magnitude, locale: locale)
    }

    /// One decimal under ten (`1.2K`), none above (`64K`), and a trailing `.0`
    /// dropped (`2K`, not `2.0K`).
    static func mantissa(_ value: Double, locale: Locale) -> String {
        let digits = value < 10 ? 0...1 : 0...0
        return value.formatted(
            .number
                .precision(.fractionLength(digits))
                .grouping(.never)
                .locale(locale)
        )
    }

    // MARK: - Days

    /// `Today`, `Yesterday`, `Tomorrow`, then a weekday inside the coming or
    /// past week (`Monday`), then a date (`Tue 20 Oct`).
    ///
    /// For a reminder's due date and a row in a seven-night list. Capitalised
    /// as a label; a sentence lower-cases it with `lowercasedDay`.
    public static func day(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let gap = dayGap(from: now, to: date, calendar: calendar)
        switch gap {
        case 0: return "Today"
        case -1: return "Yesterday"
        case 1: return "Tomorrow"
        case -6 ... -2, 2...6:
            return date.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
            )
        default:
            return shortDate(date, calendar: calendar, locale: locale)
        }
    }

    /// `Tue 20 Oct` (or `Tue, Oct 20`, as the locale orders it). No year: every
    /// list this is used in spans a week or two.
    public static func shortDate(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated)
                .day()
                .month(.abbreviated)
        )
    }

    /// `Tue`. For a row label where the date is already obvious from the list.
    public static func weekday(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
        )
    }

    /// Whole calendar days from `from` to `to`: 1 is tomorrow, -1 yesterday.
    ///
    /// Counted between local midnights rather than by dividing seconds, so a
    /// day with a clock change in it is still one day.
    public static func dayGap(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    /// `today`, `yesterday`, `on Monday`, `on Tue 20 Oct` — the same choice as
    /// `day(_:relativeTo:)`, shaped to sit inside a sentence.
    public static func dayPhrase(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let gap = dayGap(from: now, to: date, calendar: calendar)
        switch gap {
        case 0: return "today"
        case -1: return "yesterday"
        case 1: return "tomorrow"
        default: return "on " + day(date, relativeTo: now, calendar: calendar, locale: locale)
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
