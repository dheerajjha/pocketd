import Foundation

// MARK: - The shape of a verdict

/// How a verdict should feel, without saying anything about colour.
///
/// The successor to `TodayTiles.Tone`, renamed to the words the design uses.
/// The view maps these onto its own palette; naming the feeling rather than the
/// colour is what lets one tile be right in light mode, dark mode and under an
/// accessibility palette nobody has designed yet.
///
/// `good` is kept for news that is genuinely good — all clear, a rested night,
/// ahead of your usual — and not spent on "nothing to report", or a grid that
/// is green every day stops meaning anything.
public enum VerdictTone: String, Sendable, Codable, Equatable, CaseIterable {
    case good, warning, neutral
}

/// One Today tile: a word first, then one plain sentence that carries the
/// number.
///
/// "Verdict before number": the status is what a glance takes in ("Rested",
/// "1 overdue", "Behind"), and the sentence is where the figure and its
/// comparison live ("6h 36m — 29 min under your usual."). Both are decided here,
/// from the snapshot alone, so the tile, its VoiceOver label and the tests read
/// the same words — and so none of them can come from a model.
public struct TileVerdict: Sendable, Equatable, Identifiable {

    public enum Tile: String, Sendable, Codable, Equatable, CaseIterable {
        case upNext, due, sleep, activity

        /// The small label above the status. Sentence case here; the view
        /// decides whether to set it in capitals.
        public var label: String {
            switch self {
            case .upNext: "Up next"
            case .due: "Due"
            case .sleep: "Sleep"
            case .activity: "Activity"
            }
        }
    }

    /// What a tap on the tile should do.
    ///
    /// Decided here rather than by the view, because it follows from the same
    /// availability that chose the words: a tile reading "Off" must open the
    /// one connect door, not a detail page with nothing in it, and a tile iOS
    /// refused must go to Settings, where the switch actually is.
    public enum Action: String, Sendable, Codable, Equatable {
        /// The source is readable: push its detail page.
        case openDetail
        /// The source is off: raise the iOS sheet through the one connect door.
        case connect
        /// iOS said no: only Settings can change that.
        case openSettings
        /// Nothing anybody can do on this device. The tile is not a button.
        case none
    }

    public var tile: Tile
    /// The verdict: an event title, "Free", "1 overdue", "Rested", "Off".
    public var status: String
    /// One sentence carrying the number, already punctuated where it is a
    /// sentence ("Nothing else today.") and left open where it is a line of
    /// facts ("In 3h 19m · Conference room B").
    public var sentence: String
    public var tone: VerdictTone
    public var action: Action

    public var id: Tile { tile }

    /// Whether the tile is standing in for a source that is not connected.
    public var isOff: Bool { action == .connect || action == .openSettings }

    /// The whole tile as one VoiceOver sentence: the label, the verdict, then
    /// the number.
    public var accessibilityLabel: String {
        let status = self.status.hasSuffix(".") ? self.status : self.status + "."
        return "\(tile.label): \(status) \(sentence)"
    }

    public init(tile: Tile, status: String, sentence: String, tone: VerdictTone, action: Action) {
        self.tile = tile
        self.status = status
        self.sentence = sentence
        self.tone = tone
        self.action = action
    }
}

// MARK: - Which reminders are late

/// The day's open reminders, split by the clock rather than by the reader.
///
/// The snapshot's own `overdue` pile is everything due before this morning's
/// midnight, which is right for a list read at breakfast and wrong by teatime:
/// "Call the plumber" due at 17:00 is still filed under "due today" at 18:00.
/// This split is the one every surface uses — the Due tile, the brief and the
/// Reminders page — so they cannot disagree about how many things slipped.
///
/// A reminder with a time is late once that time has passed; one with only a
/// date is late once that day has. A date is a whole day, and calling it
/// overdue at a minute past midnight would invent a deadline nobody set.
public struct DueSplit: Sendable, Equatable {
    /// Late, most overdue first.
    public var overdue: [BriefReminder]
    /// Due later today: timed ones in order, then the date-only ones.
    public var today: [BriefReminder]

    public init(overdue: [BriefReminder], today: [BriefReminder]) {
        self.overdue = overdue
        self.today = today
    }

    public static func of(_ snapshot: TodaySnapshot, now: Date, calendar: Calendar = .current) -> DueSplit {
        let startOfToday = calendar.startOfDay(for: now)
        var overdue = snapshot.overdue
        var today: [BriefReminder] = []
        for reminder in snapshot.dueToday {
            if isLate(reminder, now: now, startOfToday: startOfToday) {
                overdue.append(reminder)
            } else {
                today.append(reminder)
            }
        }
        return DueSplit(
            overdue: overdue.sorted(by: mostOverdueFirst),
            today: today.sorted(by: soonestFirst)
        )
    }

    static func isLate(_ reminder: BriefReminder, now: Date, startOfToday: Date) -> Bool {
        guard let due = reminder.due else { return false }
        return reminder.dueHasTime ? due < now : due < startOfToday
    }

    static func mostOverdueFirst(_ left: BriefReminder, _ right: BriefReminder) -> Bool {
        let l = left.due ?? .distantFuture
        let r = right.due ?? .distantFuture
        return l == r ? left.title < right.title : l < r
    }

    /// Timed first, because a time is a deadline and a date is not: "Call the
    /// plumber at 5:00 PM" is more urgent than "Water the plants" sometime
    /// today, even though the plants' midnight sorts first.
    static func soonestFirst(_ left: BriefReminder, _ right: BriefReminder) -> Bool {
        switch (left.dueHasTime, right.dueHasTime) {
        case (true, false): return true
        case (false, true): return false
        default: return mostOverdueFirst(left, right)
        }
    }
}

// MARK: - The rules

/// The four Today tiles, as verdicts.
///
/// Every rule lives here, is a pure function of the snapshot and the clock, and
/// is tested — because the bugs in a tile are never in its happy path. They are
/// in "Free" for a calendar that was never connected, "0" for Health that is
/// off, and amber on a step count at nine in the morning because a third of a
/// day is smaller than a whole one.
public enum TodayVerdicts {

    /// The four, in grid order: Up next, Due, Sleep, Activity.
    public static func all(
        _ snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [TileVerdict] {
        [
            upNext(snapshot, now: now, calendar: calendar, locale: locale),
            due(snapshot, now: now, calendar: calendar, locale: locale),
            sleep(snapshot),
            activity(snapshot, calendar: calendar, locale: locale),
        ]
    }

    // MARK: Up next

    /// The next thing that has not started, today.
    ///
    /// Status is the event's title; the sentence says how long there is and
    /// where it is — or when, if it has no place — so the two lines answer
    /// "what" and "how soon" without a third. An event tomorrow is not "up
    /// next" on a tile about today: the afternoon is free, and saying so is the
    /// true answer and the good news.
    public static func upNext(
        _ snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> TileVerdict {
        guard snapshot.calendar.isReadable else {
            return unavailable(.upNext, snapshot.calendar)
        }
        guard let next = snapshot.nextEvent(now: now), calendar.isDate(next.start, inSameDayAs: now) else {
            // Nothing is next, but something is on: the day is not "Free"
            // while the person is sitting in the dentist's chair.
            if let current = snapshot.currentEvent(now: now) {
                return TileVerdict(
                    tile: .upNext,
                    status: BriefPrompt.clipped(current.title, limit: 40),
                    sentence: "On now · until \(Format.time(current.end, calendar: calendar, locale: locale))",
                    tone: .neutral,
                    action: .openDetail
                )
            }
            return TileVerdict(
                tile: .upNext,
                status: "Free",
                sentence: hasNothingToday(snapshot, now: now, calendar: calendar)
                    ? "Nothing on your calendar today."
                    : "Nothing else today.",
                tone: .neutral,
                action: .openDetail
            )
        }
        let countdown = capitalisingFirst(Format.relative(next.start, from: now))
        let place = next.location.map { BriefPrompt.clipped($0, limit: 32) }
        let detail = place ?? Format.time(next.start, calendar: calendar, locale: locale)
        return TileVerdict(
            tile: .upNext,
            status: BriefPrompt.clipped(next.title, limit: 40),
            sentence: "\(countdown) · \(detail)",
            tone: .neutral,
            action: .openDetail
        )
    }

    /// Whether today has nothing on it at all, as opposed to nothing *left*.
    ///
    /// Only answerable when the reader started at midnight; a snapshot read
    /// from `now` has already dropped the morning's standup, so it gets the
    /// cautious "Nothing else today." rather than a confident falsehood.
    static func hasNothingToday(_ snapshot: TodaySnapshot, now: Date, calendar: Calendar) -> Bool {
        guard snapshot.eventsCoverWholeDay else { return false }
        return !snapshot.events.contains { calendar.isDate($0.start, inSameDayAs: now) || ($0.start < now && $0.end > now) }
    }

    // MARK: Due

    /// "1 overdue", "3 today" or "All clear", and the one reminder that matters
    /// most, by name.
    ///
    /// Overdue outranks due: one thing that slipped is the fact the person
    /// needs before the three still to come, and the sentence names the one
    /// that slipped furthest. Today's are named soonest first, timed before
    /// date-only.
    public static func due(
        _ snapshot: TodaySnapshot,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> TileVerdict {
        guard snapshot.reminders.isReadable else {
            return unavailable(.due, snapshot.reminders)
        }
        let split = DueSplit.of(snapshot, now: now, calendar: calendar)
        if let first = split.overdue.first {
            return TileVerdict(
                tile: .due,
                status: "\(Format.count(split.overdue.count, locale: locale)) overdue",
                sentence: "\(BriefPrompt.clipped(first.title, limit: 32)) was due \(dueWords(first, now: now, calendar: calendar, locale: locale)).",
                tone: .warning,
                action: .openDetail
            )
        }
        if let first = split.today.first {
            return TileVerdict(
                tile: .due,
                status: "\(Format.count(split.today.count, locale: locale)) today",
                sentence: "\(BriefPrompt.clipped(first.title, limit: 32)) is due \(dueWords(first, now: now, calendar: calendar, locale: locale)).",
                tone: .neutral,
                action: .openDetail
            )
        }
        return TileVerdict(
            tile: .due,
            status: "All clear",
            sentence: "Nothing due today.",
            tone: .good,
            action: .openDetail
        )
    }

    /// `at 5:00 PM` for a time today, `today` for a date today, `yesterday`,
    /// `on Monday`, `on Fri 2 Oct` for anything further away.
    static func dueWords(_ reminder: BriefReminder, now: Date, calendar: Calendar, locale: Locale) -> String {
        guard let due = reminder.due else { return "today" }
        if reminder.dueHasTime, calendar.isDate(due, inSameDayAs: now) {
            return "at \(Format.time(due, calendar: calendar, locale: locale))"
        }
        return Format.dayPhrase(due, relativeTo: now, calendar: calendar, locale: locale)
    }

    // MARK: Sleep

    /// Short or long against this person's own usual; without one, against the
    /// broad band nearly every adult falls in.
    ///
    /// The usual is the median of the previous fortnight (`Usual`), and the
    /// band either side of it is `Comparison`'s ten percent — the same test the
    /// brief applies, so the tile and the paragraph above it cannot disagree
    /// about whether last night was short.
    ///
    /// Only a short night is a warning. A long one is a lie-in; a tile that
    /// warns somebody about a good night's sleep is a tile they learn to
    /// ignore.
    public static func sleep(_ snapshot: TodaySnapshot) -> TileVerdict {
        guard snapshot.health.isReadable else {
            return unavailable(.sleep, snapshot.health)
        }
        guard let slept = snapshot.sleepLastNight, slept > 0 else {
            return TileVerdict(
                tile: .sleep, status: "No data", sentence: "No sleep recorded last night.",
                tone: .neutral, action: .openDetail
            )
        }
        let band = sleepBand(slept, usual: snapshot.sleepUsual)
        return TileVerdict(
            tile: .sleep,
            status: band.word,
            sentence: sleepSentence(slept, usual: snapshot.sleepUsual),
            tone: band.tone,
            action: .openDetail
        )
    }

    /// The fallback when a first week with Health has a night and no usual:
    /// under six hours is short, over nine and a half is long. Broad on
    /// purpose — it only has to avoid calling four hours "Rested" until the
    /// person's own baseline exists, and it is never written as advice.
    static let shortNightWithoutUsual: TimeInterval = 6 * 3600
    static let longNightWithoutUsual: TimeInterval = 9.5 * 3600

    static func sleepBand(_ slept: TimeInterval, usual: TimeInterval?) -> (word: String, tone: VerdictTone) {
        let comparison: Comparison
        if let usual, usual > 0 {
            comparison = Comparison.compare(slept, usual: usual)
        } else if slept < shortNightWithoutUsual {
            comparison = .below
        } else if slept > longNightWithoutUsual {
            comparison = .above
        } else {
            comparison = .usual
        }
        switch comparison {
        case .below: return ("Short night", .warning)
        case .above: return ("Long night", .neutral)
        case .usual: return ("Rested", .good)
        }
    }

    /// `6h 36m — 29 min under your usual.`
    ///
    /// The difference is printed even inside the "about usual" band, because
    /// the verdict already carries the judgement and the sentence's job is
    /// the number. Under five minutes it is noise, and says so.
    public static func sleepSentence(_ slept: TimeInterval, usual: TimeInterval?) -> String {
        let figure = Format.duration(slept)
        guard let usual, usual > 0 else { return "\(figure) last night." }
        return "\(figure) — \(deltaPhrase(slept - usual)) your usual."
    }

    /// `29 min under`, `1h 5m over`, `about`. A phrase to finish with "your
    /// usual", shared by the tile, the brief and the Sleep page.
    public static func deltaPhrase(_ difference: TimeInterval) -> String {
        let minutes = Int((abs(difference) / 60).rounded())
        guard minutes >= 5 else { return "about" }
        let amount = Format.minutesText(minutes, padded: false)
        return difference < 0 ? "\(amount) under" : "\(amount) over"
    }

    // MARK: Activity

    /// Steps so far against where a usual day has got to by the same time.
    ///
    /// With an hour-by-hour history that is a like-for-like comparison and the
    /// sentence says "by now". Without one, the daily figure is all there is:
    /// the sentence says "a day", and the verdict compares against a share of it
    /// spread over a waking day — an estimate, so it gets a wider band.
    ///
    /// "Behind" is a warning only when the comparison is like for like. Judged
    /// against the estimate it stays neutral: nobody should be told off by an
    /// assumption about when they get up.
    public static func activity(
        _ snapshot: TodaySnapshot,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> TileVerdict {
        guard snapshot.health.isReadable else {
            return unavailable(.activity, snapshot.health)
        }
        guard let today = snapshot.stepsToday else {
            return TileVerdict(
                tile: .activity, status: "No data", sentence: "No steps recorded today.",
                tone: .neutral, action: .openDetail
            )
        }
        let steps = Format.counted(Int(today.rounded()), "step", locale: locale)

        if let byNow = snapshot.stepsUsualByNow, byNow > 0 {
            let pace = Comparison.compare(today, usual: byNow)
            return TileVerdict(
                tile: .activity,
                status: pace.activityWord,
                sentence: "\(steps) — you're usually at \(Format.count(byNow, locale: locale)) by now.",
                tone: pace == .above ? .good : (pace == .below ? .warning : .neutral),
                action: .openDetail
            )
        }

        if let daily = snapshot.stepsUsual, daily > 0 {
            let expected = daily * expectedShare(at: snapshot.generatedAt, calendar: calendar)
            let pace: Comparison = today >= daily
                ? .above
                : Comparison.compare(today, usual: expected, tolerance: estimateTolerance)
            return TileVerdict(
                tile: .activity,
                status: pace.activityWord,
                sentence: "\(steps) — usually \(Format.count(daily, locale: locale)) a day.",
                tone: pace == .above ? .good : .neutral,
                action: .openDetail
            )
        }

        return TileVerdict(
            tile: .activity,
            status: "So far",
            sentence: "\(steps) today.",
            tone: .neutral,
            action: .openDetail
        )
    }

    /// The band either side of an *estimated* pace. Twice `Comparison`'s,
    /// because the estimate is a straight line across a waking day and real
    /// days are lumpy: a walk to work at 8:30 should not read as "Ahead" and
    /// a morning at a desk as "Behind".
    static let estimateTolerance = 0.2

    /// How much of a usual day's walking is done by this time, when nothing
    /// better than a daily total is known.
    ///
    /// A straight line from 07:00 to 21:00. Not a claim about anybody's day —
    /// only a way of not comparing a morning with a whole day, which is the
    /// mistake the hour-by-hour figure exists to remove. Before seven the share
    /// is nothing, so nothing is behind; after nine in the evening the day is
    /// treated as done.
    public static func expectedShare(at date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        let start = 7.0 * 60
        let end = 21.0 * 60
        return min(1, max(0, (minutes - start) / (end - start)))
    }

    // MARK: Off, refused, absent

    /// The three ways a tile has nothing to show, each with its own remedy and
    /// its own action.
    ///
    /// One function, so the four tiles cannot drift into four wordings for one
    /// state — which is how a screen ends up telling somebody to turn on
    /// something they already turned on.
    static func unavailable(_ tile: TileVerdict.Tile, _ availability: TodaySnapshot.Availability) -> TileVerdict {
        switch availability {
        case .connected:
            // Unreachable from the callers above, which all guard on
            // `isReadable` first. Stated rather than trapped.
            return TileVerdict(tile: tile, status: "—", sentence: "", tone: .neutral, action: .openDetail)
        case .off:
            return TileVerdict(tile: tile, status: "Off", sentence: "Turn on to see \(tile.payoff).", tone: .neutral, action: .connect)
        case .refused:
            return TileVerdict(tile: tile, status: "Off", sentence: "Turn on in Settings to see \(tile.payoff).", tone: .warning, action: .openSettings)
        case .unavailable:
            return TileVerdict(tile: tile, status: "Not here", sentence: "This iPhone has no \(tile.source).", tone: .neutral, action: .none)
        }
    }

    static func capitalisingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}

extension TileVerdict.Tile {
    /// What turning the source on would show, finishing "Turn on to see …".
    var payoff: String {
        switch self {
        case .upNext: "what's next"
        case .due: "what's due"
        case .sleep: "how you slept"
        case .activity: "your steps"
        }
    }

    /// The source, for the one sentence where the device lacks it.
    var source: String {
        switch self {
        case .upNext: "Calendar"
        case .due: "Reminders"
        case .sleep, .activity: "Health data"
        }
    }
}

extension Comparison {
    /// The Activity tile's three words.
    var activityWord: String {
        switch self {
        case .above: "Ahead"
        case .usual: "On track"
        case .below: "Behind"
        }
    }
}
