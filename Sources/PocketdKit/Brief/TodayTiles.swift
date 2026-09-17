import Foundation

/// Numbers as a person reads them, rather than as a model reads them.
///
/// A deliberate second spelling beside `HealthFormat`, and the split is the
/// point. `HealthFormat.number` strips digit grouping on purpose, because a
/// German phone renders 12000 as "12.000" and a 1.7B model reads that as twelve;
/// `HealthFormat.duration` writes "7 h 5 m" because a model handed "7.75 hours"
/// converts it and gets it wrong. Both are right for the prompt and both are
/// wrong for a 44-point tile, where a human reads the number and the space is
/// measured in characters.
///
/// So: grouped digits here, ungrouped there; "6h 36m" here, "6 h 36 m" there.
/// One function each, in one place each, so that neither drifts into the other's
/// job the next time somebody needs a number formatted.
public enum BriefFormat {

    /// `6h 36m`, and `7h 05m` — the minutes are padded so a column of these
    /// does not jitter as the width changes between 5 and 55.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let remainder = minutes % 60
        guard hours > 0 else { return "\(remainder)m" }
        return String(format: "%dh %02dm", hours, remainder)
    }

    /// `4,120`. Grouped, and localised, because this one is read by the person
    /// whose phone it is and not by a model.
    public static func count(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        return value.rounded().formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
}

/// The four numbers on the Today tab, as strings.
///
/// The whole of this file is here rather than in the view for one reason: every
/// one of these tiles has an "off", a "nothing", and a "we have no baseline"
/// state, and the interesting bugs all live in those rather than in the happy
/// path. A tile that says "0" when Health is switched off is a lie; one that
/// says "Free" when the calendar was never connected is a worse one. Testing
/// that in a `body` means booting a simulator, so it is not tested.
public enum TodayTiles {

    /// How a tile should feel, without saying anything about colour.
    ///
    /// The view maps these onto `Color.pd.*`. Naming the feeling rather than the
    /// colour is what lets the same tile be right in light mode, dark mode, and
    /// under an accessibility palette nobody has designed yet.
    public enum Tone: String, Sendable, Codable, Equatable, CaseIterable {
        case neutral, positive, caution
    }

    public struct Tile: Sendable, Equatable {
        /// The large figure or word.
        public var value: String
        /// The small word beside it, when there is one. Nil rather than an
        /// empty string so a view can leave the space out entirely.
        public var unit: String?
        /// The line underneath. Where every comparison and every explanation
        /// lives, so that `value` is always just the fact.
        public var footnote: String?
        public var tone: Tone

        public init(value: String, unit: String? = nil, footnote: String? = nil, tone: Tone = .neutral) {
            self.value = value
            self.unit = unit
            self.footnote = footnote
            self.tone = tone
        }
    }

    // MARK: - Up next

    public static func upNext(
        _ snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Tile {
        guard snapshot.calendar.isReadable else {
            return unavailable(snapshot.calendar, source: "calendar")
        }
        guard let next = snapshot.nextEvent(now: now) else {
            // "Free" and not "None". The tile is answering "what is next", and
            // the true answer to that on an empty afternoon is good news.
            return Tile(value: "Free", footnote: "Nothing more today", tone: .neutral)
        }
        return Tile(
            value: BriefPrompt.clipped(next.title, limit: 28),
            footnote: countdown(to: next.start, from: now, calendar: calendar, locale: locale),
            tone: .neutral
        )
    }

    /// `in 2h 10m`, `in 4m`, `now`.
    ///
    /// Rendered rather than left to `Text(_:style:.relative)` because this
    /// string is also mirrored into the widget file and read back by a second
    /// process — and because "in 2 hours" rounds away the ten minutes that
    /// decide whether somebody leaves now.
    ///
    /// An event more than a day out gets a weekday instead of a count. "in 27h
    /// 40m" is a number nobody converts in their head.
    static func countdown(to start: Date, from now: Date, calendar: Calendar, locale: Locale) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        guard seconds < 24 * 3600 else {
            let day = start.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                    .weekday(.abbreviated)
            )
            return "\(day) \(BriefPrompt.clock(start, calendar: calendar, locale: locale))"
        }
        return "in \(BriefFormat.duration(seconds))"
    }

    // MARK: - Due

    public static func due(_ snapshot: TodaySnapshot) -> Tile {
        guard snapshot.reminders.isReadable else {
            return unavailable(snapshot.reminders, source: "reminders")
        }
        let overdue = snapshot.overdue.count
        return Tile(
            value: "\(snapshot.dueToday.count)",
            unit: "due",
            // Only when there is something to say. "0 overdue" under a zero is
            // two zeroes describing the same nothing.
            footnote: overdue > 0 ? "\(overdue) overdue" : (snapshot.dueToday.isEmpty ? "All clear" : nil),
            tone: overdue > 0 ? .caution : (snapshot.dueToday.isEmpty ? .positive : .neutral)
        )
    }

    // MARK: - Sleep

    public static func sleep(_ snapshot: TodaySnapshot) -> Tile {
        guard snapshot.health.isReadable else {
            return unavailable(snapshot.health, source: "Health")
        }
        guard let slept = snapshot.sleepLastNight else {
            return Tile(value: "—", footnote: "No sleep recorded", tone: .neutral)
        }
        guard let usual = snapshot.sleepUsual else {
            // A first week with Health connected has a reading and no baseline,
            // and inventing one from a single night would make the second night
            // "above usual" by definition.
            return Tile(value: BriefFormat.duration(slept), footnote: "No usual yet", tone: .neutral)
        }
        let comparison = Comparison.compare(slept, usual: usual)
        return Tile(
            value: BriefFormat.duration(slept),
            footnote: "usual \(BriefFormat.duration(usual))",
            // Only short sleep is a caution. More than usual is a lie-in, and a
            // tile that warns somebody about a good night's sleep is a tile they
            // learn to ignore.
            tone: comparison == .below ? .caution : .positive
        )
    }

    // MARK: - Steps

    public static func steps(_ snapshot: TodaySnapshot, locale: Locale = .current) -> Tile {
        guard snapshot.health.isReadable else {
            return unavailable(snapshot.health, source: "Health")
        }
        guard let today = snapshot.stepsToday else {
            return Tile(value: "—", footnote: "No steps recorded", tone: .neutral)
        }
        return Tile(
            value: BriefFormat.count(today, locale: locale),
            footnote: snapshot.stepsUsual.map { "usual \(BriefFormat.count($0, locale: locale))" },
            // Always neutral, and this is the one tone decision here worth
            // arguing about. Steps-so-far is a partial day and `stepsUsual` is a
            // whole one, so tinting by `Usual.compare` would put a caution on
            // this tile every single morning and take it off again at teatime.
            // Sleep does not have that problem: a night is finished when it is
            // measured.
            tone: .neutral
        )
    }

    // MARK: - Off, refused, absent

    /// The three ways a tile has nothing to show, each with its own remedy.
    ///
    /// One function so that the four tiles cannot drift into four different
    /// wordings for the same state, which is how a settings screen ends up
    /// telling somebody to turn on something they already turned on.
    static func unavailable(_ availability: TodaySnapshot.Availability, source: String) -> Tile {
        switch availability {
        case .connected:
            // Unreachable from the callers above, which all guard on
            // `isReadable` first. Stated rather than trapped: a tile is not
            // worth a crash.
            return Tile(value: "—", tone: .neutral)
        case .off:
            return Tile(value: "Off", footnote: "Connect \(source)", tone: .neutral)
        case .refused:
            return Tile(value: "Off", footnote: "Allow \(source) in Settings", tone: .caution)
        case .unavailable:
            return Tile(value: "—", footnote: "Not on this iPhone", tone: .neutral)
        }
    }
}
