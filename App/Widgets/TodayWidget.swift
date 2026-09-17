import AppIntents
import SwiftUI
import UIKit
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

// MARK: - Palette

/// The app's warm cream, redeclared here.
///
/// The widget extension does not compile the app's Design folder and has no
/// asset catalogue of its own — see project.yml, where `PocketdWidgets` takes
/// four named files and `App/Widgets` and nothing else. So the six colours are
/// literals in this file, which is a duplicate and is meant to be read as one:
/// if the app's cream moves, this moves with it by hand.
///
/// A `UIColor` dynamic provider rather than two `Color`s and a `colorScheme`
/// check, because the widget's rendering environment resolves the trait for us
/// in every place a widget is drawn — gallery, home screen, StandBy, the
/// Xcode preview — and a manual branch would have to be threaded into every
/// nested view that draws anything.
private enum TodayPalette {
    /// Computed rather than stored. These are cheap, and a stored global would
    /// be a global initialiser running a UIKit closure on whichever thread got
    /// there first.
    static var cream: Color { dynamic(light: 0xFFFEFB, dark: 0x1E1C19) }
    static var ink: Color { dynamic(light: 0x242424, dark: 0xF1EFEA) }
    /// The one colour that does not flip. It is legible on both backgrounds and
    /// a second value would be a second thing to keep in step for no gain.
    static var secondary: Color { solid(0x7B7B7B) }
    static var accent: Color { solid(0x39649E) }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light)
        })
    }

    private static func solid(_ rgb: UInt32) -> Color {
        Color(uiColor: uiColor(rgb))
    }

    private static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
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
    /// that the gallery shows the shape of the thing.
    static var sample: WidgetBrief {
        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 30
        return WidgetBrief(
            // No trailing stop, exactly as the app publishes it. The views add
            // one; a sample that carried its own would hide a bug in that.
            greetingLine: "Good morning, Sam",
            firstSentence: "Standup at 9:30 is next, and two reminders are due today.",
            nextEventTitle: "Standup",
            nextEventTime: Calendar.current.date(from: components) ?? now.addingTimeInterval(1_500),
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
        var entries = [TodayEntry(date: now, brief: brief)]

        // A second entry at the event itself, and it is not about the countdown.
        //
        // `Text(_:style:.relative)` is drawn by the system and ticks on its own
        // between reloads, so "in 25 min" needs no entries at all to reach "in 1
        // min" — an entry per minute would spend the whole refresh budget
        // redrawing a clock iOS is already drawing. What it cannot do is stop:
        // left alone it rolls straight past 09:30 and starts counting *up*,
        // so a meeting that started ten minutes ago reads "10 min" and looks
        // like one starting in ten. This entry is the flip to a wall-clock
        // time at the moment that would happen.
        if let firing = brief?.nextEventTime, firing > now {
            entries.append(TodayEntry(date: firing, brief: brief))
        }

        // The quarter hour, because the parts of this that are not self-ticking
        // — the stale label, the greeting crossing noon — move on the clock and
        // not on anything the app does. The app also reloads this explicitly
        // whenever it publishes a brief, which covers every change a person
        // makes; this covers the one nobody makes, where time simply passes.
        completion(Timeline(entries: entries, policy: .after(Self.nextQuarterHour(after: now))))
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
            // One destination for the whole widget. Every family lands on the
            // Today tab; the medium family's Ask button is the one exception and
            // it wins inside its own bounds.
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
        default: TodayPalette.cream
        }
    }

    // MARK: Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(copy.label)
            Spacer(minLength: 6)
            Text(copy.greeting)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TodayPalette.ink)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            if let title = copy.nextTitle, let time = copy.nextTime {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(TodayPalette.ink)
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
                    .foregroundStyle(TodayPalette.secondary)
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
            HStack(alignment: .firstTextBaseline) {
                fieldLabel(copy.label)
                Spacer(minLength: 8)
                askButton
            }
            Text(copy.greeting)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TodayPalette.ink)
                .lineLimit(1)
            Text(copy.sentence)
                .font(.system(size: 13))
                .foregroundStyle(TodayPalette.ink)
                .lineLimit(3)
            Spacer(minLength: 4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let title = copy.nextTitle, let time = copy.nextTime {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    fieldLabel("NEXT")
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(TodayPalette.ink)
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
                    Text("\(copy.dueCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TodayPalette.accent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The one interactive part of the widget.
    ///
    /// A `Button(intent:)` rather than a second `widgetURL` — a widget gets
    /// exactly one URL, and spending it on Ask would cost the tap-anywhere
    /// gesture that takes somebody to the brief this widget is showing them.
    /// The intent is the same one the Control Center button runs, so there is
    /// one definition of "open into Ask" and not two.
    private var askButton: some View {
        Button(intent: OpenAskIntent()) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TodayPalette.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Pocketd")
    }

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
            Label("\(copy.dueCount) due", systemImage: "checklist")
        } else {
            Label("Nothing due", systemImage: "checklist")
        }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .semibold))
            Text("\(copy.dueCount)")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
        }
        .accessibilityLabel(copy.dueCount == 1 ? "1 reminder due" : "\(copy.dueCount) reminders due")
    }

    // MARK: Pieces

    /// "NEXT", "DUE", "TODAY" — the same 11pt monospaced capitals everywhere, so
    /// that a label is recognisable as a label rather than as short text.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(TodayPalette.secondary)
    }

    private func monospacedTime(_ time: Date) -> some View {
        timePhrase(time)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(TodayPalette.accent)
    }

    /// "in 25 min" before it starts, "9:30 AM" after.
    ///
    /// Returns `Text` rather than `some View` so the inline family can
    /// concatenate it, and so `.relative` keeps its self-ticking behaviour —
    /// the system redraws that phrase between timeline reloads, which is the
    /// whole reason `WidgetBrief` publishes an instant and not a sentence.
    private func timePhrase(_ time: Date) -> Text {
        time > entry.date ? Text("in ") + Text(time, style: .relative) : Text(time, style: .time)
    }

    private var duePill: some View {
        Text("\(copy.dueCount) due")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(TodayPalette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(TodayPalette.accent.opacity(0.13)))
    }
}

// MARK: - Widget

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.pocketd.widget.today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Your brief, what is next, and how much is due.")
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
