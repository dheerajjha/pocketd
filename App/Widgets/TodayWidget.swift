import SwiftUI
import WidgetKit

/// The brief, on a home screen and a lock screen.
///
/// The sibling of `SchedulesWidget`, and the one that carries words. That is
/// argued at length at the top of `WidgetBrief` and not repeated here; the short
/// version is that this widget's entire purpose is the first sentence of
/// somebody's own day, and the type it reads is the guard on how much of the day
/// crosses. One sentence, one event title, one count. No reminder titles, no
/// sleep, no steps — there is no field on `WidgetBrief` that could carry them,
/// so this file could not show them if it tried.
struct TodayEntry: TimelineEntry {
    let date: Date
    /// `nil` when the app has never published one — a first-run home screen, not
    /// an error. See `TodayCopy`, which turns that into a sentence rather than a
    /// blank rectangle.
    let brief: WidgetBrief?
}

// MARK: - Copy

/// Everything the views read, resolved once.
///
/// The three states this widget has — published, never published, published a
/// long time ago — differ only in their strings, so they are settled here
/// instead of being re-derived by five family branches that would each have to
/// remember the stale rule.
private struct TodayCopy {

    /// A brief older than this is shown anyway, under a different word.
    ///
    /// Twenty hours rather than twenty-four, because the failure being caught is
    /// "the app has not been opened since yesterday morning" and a brief
    /// generated at 08:00 is still under a day old at 07:00 the next morning —
    /// which is exactly the moment somebody glances at it and takes yesterday's
    /// standup for today's. Hiding it instead would be worse: the sentence is
    /// still true about a day that happened, and a widget that empties itself
    /// overnight looks broken.
    static let staleAfter: TimeInterval = 20 * 3_600

    /// "TODAY", or "YESTERDAY" when the brief has aged out.
    var label: String
    /// Already punctuated — `WidgetBrief.greetingLine` deliberately arrives
    /// without a full stop so that the layout gets to end it.
    var greeting: String
    var sentence: String
    var nextTitle: String?
    var nextTime: Date?
    var dueCount: Int

    init(entry: TodayEntry) {
        guard let brief = entry.brief else {
            // Nothing published yet. A greeting the widget works out itself,
            // with no name in it — the name lives in the brief, and inventing
            // one is the single fastest way to look like it is guessing.
            label = "TODAY"
            greeting = Self.punctuated(Self.greeting(at: entry.date))
            sentence = "Open Pocketd to get your first brief."
            nextTitle = nil
            nextTime = nil
            dueCount = 0
            return
        }
        let age = entry.date.timeIntervalSince(brief.generatedAt)
        label = age > Self.staleAfter ? "YESTERDAY" : "TODAY"
        greeting = Self.punctuated(brief.greetingLine)
        sentence = brief.firstSentence
        nextTitle = brief.nextEventTitle
        nextTime = brief.nextEventTime
        dueCount = brief.dueCount
    }

    /// "2 due" — digits through the app's own formatter, never a spelled-out
    /// number.
    var dueText: String { "\(Format.count(dueCount)) due" }

    /// Duplicated from `TimeOfDayKind`, and knowingly.
    ///
    /// That type lives in `BriefPrompt.swift`, which is PocketdKit, which this
    /// target does not link — the kit pulls in FlyingFox and an HTTP server has
    /// no business in a process with a ~30 MB ceiling. Ten lines here is the
    /// price of that, and the boundaries (05:00, 12:00, 18:00) must match it:
    /// morning starts at five so somebody awake at three is not told good
    /// morning.
    static func greeting(at instant: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: instant) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// Ends the greeting, unless whoever wrote it already did.
    static func punctuated(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}

// MARK: - Provider

struct TodayProvider: TimelineProvider {

    /// What the gallery previews with, and what the first frame draws.
    ///
    /// Invented and plausible rather than empty, for the reason `SchedulesProvider`
    /// gives: a widget that previews as "nothing here yet" is a widget nobody
    /// adds. Sam is not a user and the standup is not a meeting; both exist so
    /// that the gallery shows the shape of the thing — in the brief's own
    /// words, digits and all.
    static var sample: WidgetBrief {
        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 30
        let standup = Calendar.current.date(from: components) ?? now.addingTimeInterval(1_500)
        return WidgetBrief(
            // No trailing stop, exactly as the app publishes it. The views add
            // one; a sample that carried its own would hide a bug in that.
            greetingLine: "Good morning, Sam",
            firstSentence: "Standup at \(Format.time(standup)) is next. You have 2 reminders due today.",
            nextEventTitle: "Standup",
            nextEventTime: standup,
            dueCount: 2,
            generatedAt: now
        )
    }

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), brief: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        // The gallery asks for this too, and `context.isPreview` is how the
        // system says so. A real brief when there is one, the sample when the
        // gallery is asking and there is not.
        let brief = WidgetBriefStore().read()
        completion(TodayEntry(date: Date(), brief: brief ?? (context.isPreview ? Self.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let brief = WidgetBriefStore().read()
        let entries = Self.entryDates(from: now, event: brief?.nextEventTime)
            .map { TodayEntry(date: $0, brief: brief) }

        // The quarter hour, because the parts of this that are not covered by
        // the entries — the stale label, the greeting crossing noon — move on
        // the clock and not on anything the app does. The app also reloads
        // this explicitly whenever it publishes a brief, which covers every
        // change a person makes; this covers the one nobody makes, where time
        // simply passes.
        completion(Timeline(entries: entries, policy: .after(Self.nextQuarterHour(after: now))))
    }

    /// When the countdown needs redrawing: now, every minute boundary until the
    /// event or for the next hour, whichever comes first, and the event itself.
    ///
    /// Rendered entries rather than `Text(_:style: .relative)`, which ticks by
    /// itself but in the system's spelling — "2 hr, 10 min" — on a widget whose
    /// app says "in 2h 10m" (`Format.relative`), and which, left alone, rolls
    /// past the start and counts *up*, so a meeting that began ten minutes ago
    /// reads like one starting in ten. Entries are not reloads and cost no
    /// refresh budget; an hour of them outlasts the quarter-hour reload with
    /// room to spare, so a late reload still leaves the minutes right. The last
    /// one, at the event, is the flip to a wall-clock time.
    static func entryDates(from now: Date, event: Date?, horizon: TimeInterval = 3_600) -> [Date] {
        guard let event, event > now else { return [now] }
        var dates = [now]
        let minute: TimeInterval = 60
        var tick = (now.timeIntervalSinceReferenceDate / minute).rounded(.down) * minute + minute
        let end = min(event.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate + horizon)
        while tick < end {
            dates.append(Date(timeIntervalSinceReferenceDate: tick))
            tick += minute
        }
        if event.timeIntervalSinceReferenceDate <= now.timeIntervalSinceReferenceDate + horizon {
            dates.append(event)
        }
        return dates
    }

    /// The next :00, :15, :30 or :45.
    ///
    /// Arithmetic on the reference date rather than a `Calendar` search, and it
    /// is still correct locally: every time zone in use is offset from UTC by a
    /// whole number of quarter hours — including the awkward ones, Kathmandu's
    /// +05:45 and Kolkata's +05:30 — so a UTC quarter boundary *is* a local one.
    static func nextQuarterHour(after instant: Date) -> Date {
        let quarter: TimeInterval = 15 * 60
        let elapsed = instant.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (elapsed / quarter).rounded(.down) * quarter + quarter)
    }
}

// MARK: - View

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private var copy: TodayCopy { TodayCopy(entry: entry) }

    var body: some View {
        content
            // One destination for the whole widget: Today, with nothing on top
            // of it (`Navigator.follow`). The medium family's Ask button is the
            // one exception and it wins inside its own bounds.
            .widgetURL(URL(string: "pocketd://today"))
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    /// Cream on the home screen; nothing on the lock screen.
    ///
    /// An accessory widget is rendered into the lock screen's own vibrant
    /// material, which tints and desaturates whatever it is given — a cream
    /// rectangle there comes out as a grey smudge behind the text rather than as
    /// a background. The circular family is the exception: it has a well, and
    /// `AccessoryWidgetBackground` is the system's own.
    @ViewBuilder private var background: some View {
        switch family {
        case .accessoryCircular: AccessoryWidgetBackground()
        case .accessoryInline, .accessoryRectangular: Color.clear
        default: WidgetPalette.background
        }
    }

    // MARK: Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(copy.label)
            Spacer(minLength: 6)
            Text(copy.greeting)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            if let title = copy.nextTitle, let time = copy.nextTime {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
                monospacedTime(time)
            } else {
                // No event, or a calendar this app cannot see — `WidgetBrief`
                // publishes nil for both, deliberately, so that "your day is
                // clear" and "I cannot read your day" are not rendered as the
                // same confident empty space. The sentence covers either, and
                // it is also what the first-run widget says.
                Text(copy.sentence)
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(3)
            }
            if copy.dueCount > 0 {
                Spacer(minLength: 6)
                duePill
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(copy.label)
            Text(copy.greeting)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(1)
                // Clear of the Ask button above it in the corner.
                .padding(.trailing, 64)
            Text(copy.sentence)
                .font(.system(size: 13))
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(3)
            Spacer(minLength: 4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) { askButton }
    }

    @ViewBuilder private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let title = copy.nextTitle, let time = copy.nextTime {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    fieldLabel("NEXT")
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                    monospacedTime(time)
                }
                .layoutPriority(1)
            }
            if copy.dueCount > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    fieldLabel("DUE")
                    // The number and never the titles. See `WidgetBrief`: a
                    // count discloses nothing, and "2" is the whole of what a
                    // glance wants.
                    Text(Format.count(copy.dueCount))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetPalette.accent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The one part of the widget that goes somewhere other than the brief.
    ///
    /// A `Link` to `pocketd://ask` rather than a second `widgetURL` — a widget
    /// gets exactly one of those, and spending it on Ask would cost the
    /// tap-anywhere gesture that takes somebody to the brief this widget is
    /// showing them. A medium widget may carry links of its own as well, and
    /// the shell's `Navigator.follow` opens the conversation for this one.
    ///
    /// Not `Button(intent: OpenAskIntent())`, which it used to be. That intent
    /// runs in this extension and leaves its "open Ask" marker in the App Group
    /// for the app to find; a link needs neither, so a tap opens the
    /// conversation even where the group is missing — which is every unsigned
    /// build — rather than opening nothing at all.
    ///
    /// A word and a 44pt target rather than a lone 13pt sparkle: the glyph on
    /// its own was a thumb's width smaller than anything Apple asks a finger to
    /// hit, and said nothing about what it did. Laid over the corner instead of
    /// into the first row, so the target can be the size of a finger without
    /// pushing the sentence below it off the widget.
    private var askButton: some View {
        Link(destination: Self.askURL) {
            Label("Ask", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WidgetPalette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(WidgetPalette.accent.opacity(0.13)))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        // The capsule's top on the label row's; the rest of the target spills
        // into the widget's margin, where nothing else can be tapped.
        .offset(x: 6, y: -12)
        .accessibilityLabel("Ask Pocketd")
    }

    /// `DeepLink.ask`'s spelling. A literal, so the unwrap cannot fail.
    private static let askURL = URL(string: "pocketd://ask")!

    // MARK: Lock screen

    /// Rendered into the lock screen's vibrant material, which ignores colour
    /// and keeps weight, so this family deliberately sets neither a palette nor
    /// a point size — the system's own text styles are what stay legible over an
    /// arbitrary wallpaper.
    @ViewBuilder private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = copy.nextTitle, let time = copy.nextTime {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                timePhrase(time)
                    .font(.caption)
            } else {
                Text(copy.sentence)
                    .font(.caption)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The inline family renders ONE `Text`, `Image` or `Label` and silently
    /// drops anything else — no warning, no fallback, just a blank slot next to
    /// the clock. That is why this is its own branch and why the title and the
    /// countdown are concatenated into a single `Text` rather than stacked.
    @ViewBuilder private var inline: some View {
        if let title = copy.nextTitle, let time = copy.nextTime {
            Label {
                Text("\(title) ") + timePhrase(time)
            } icon: {
                Image(systemName: "calendar")
            }
        } else if copy.dueCount > 0 {
            Label(copy.dueText, systemImage: "checklist")
        } else {
            Label("Nothing due", systemImage: "checklist")
        }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .semibold))
            Text(Format.count(copy.dueCount))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
        }
        .accessibilityLabel("\(Format.counted(copy.dueCount, "reminder")) due")
    }

    // MARK: Pieces

    /// "NEXT", "DUE", "TODAY" — the same 11pt monospaced capitals everywhere, so
    /// that a label is recognisable as a label rather than as short text.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(WidgetPalette.secondary)
    }

    private func monospacedTime(_ time: Date) -> some View {
        timePhrase(time)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(WidgetPalette.accent)
    }

    /// "in 25 min" before it starts, "9:30 AM" after — `Format`'s spellings,
    /// the ones the app's Up next tile uses.
    ///
    /// Worked out against the entry's date, not the clock: each entry is drawn
    /// for its own minute (see `TodayProvider.entryDates`). Returns `Text` so the
    /// inline family can concatenate it.
    private func timePhrase(_ time: Date) -> Text {
        Text(time > entry.date ? Format.relative(time, from: entry.date) : Format.time(time))
    }

    private var duePill: some View {
        Text(copy.dueText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(WidgetPalette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(WidgetPalette.accent.opacity(0.13)))
    }
}

// MARK: - Widget

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.pocketd.widget.today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Your brief, what's next, and how much is due.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCircular,
        ])
    }
}

// MARK: - Previews

// The only way to see these before a device: a widget cannot be added to a
// simulator home screen from a script. One preview per family, plus the two
// states that are otherwise unreachable without waiting a day or deleting a
// file.

private extension TodayEntry {
    static var sample: TodayEntry { TodayEntry(date: Date(), brief: TodayProvider.sample) }

    /// No brief has ever been published.
    static var empty: TodayEntry { TodayEntry(date: Date(), brief: nil) }

    /// Published twenty-two hours ago, which is what turns the label over.
    static var stale: TodayEntry {
        var brief = TodayProvider.sample
        brief.generatedAt = Date().addingTimeInterval(-22 * 3_600)
        brief.nextEventTitle = nil
        brief.nextEventTime = nil
        return TodayEntry(date: Date(), brief: brief)
    }
}

#Preview("Small", as: .systemSmall) {
    TodayWidget()
} timeline: {
    TodayEntry.sample
    TodayEntry.empty
    TodayEntry.stale
}

#Preview("Medium", as: .systemMedium) {
    TodayWidget()
} timeline: {
    TodayEntry.sample
    TodayEntry.empty
    TodayEntry.stale
}

#Preview("Rectangular", as: .accessoryRectangular) {
    TodayWidget()
} timeline: {
    TodayEntry.sample
    TodayEntry.empty
}

#Preview("Inline", as: .accessoryInline) {
    TodayWidget()
} timeline: {
    TodayEntry.sample
    TodayEntry.empty
}

#Preview("Circular", as: .accessoryCircular) {
    TodayWidget()
} timeline: {
    TodayEntry.sample
    TodayEntry.empty
}
