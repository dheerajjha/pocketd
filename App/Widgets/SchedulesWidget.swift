import SwiftUI
import WidgetKit

/// What a home screen is allowed to say about somebody's routines.
///
/// The whole widget answers one question — what will Pocketd do next, and is
/// anything waiting for me — and deliberately not the next one, which is what it
/// said. `SchedulePublication` carries no run text at all, so there is no
/// version of this view that could render a model's answer about a health
/// record; the type is the guard, and this file could not leak that if it
/// tried.
///
/// Still `Schedules…` in the code, and on purpose: the kind string below is how
/// iOS finds the widgets people have already placed, and renaming it would
/// quietly take them off home screens. What a person reads says "routine".
struct SchedulesEntry: TimelineEntry {
    let date: Date
    let publication: SchedulePublication?
}

struct SchedulesProvider: TimelineProvider {

    /// What the gallery previews with, and what the first frame draws.
    ///
    /// Plausible rather than empty, because a widget that previews as "nothing
    /// set up" is one nobody adds.
    static var sample: SchedulePublication {
        SchedulePublication(
            generatedAt: Date(),
            next: .init(title: "Morning brief",
                        firing: Date().addingTimeInterval(3_600),
                        needsModel: false),
            latest: nil,
            enabledCount: 1,
            waitingCount: 0
        )
    }

    func placeholder(in context: Context) -> SchedulesEntry {
        SchedulesEntry(date: Date(), publication: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SchedulesEntry) -> Void) {
        // The gallery asks for this too (`context.isPreview`): the real
        // routines when there are some, the sample when the gallery is asking
        // and there are none — the same rule as the Today widget.
        let publication = SchedulePublicationStore().read()
        completion(SchedulesEntry(date: Date(), publication: publication ?? (context.isPreview ? Self.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SchedulesEntry>) -> Void) {
        let now = Date()
        let publication = SchedulePublicationStore().read()
        let entry = SchedulesEntry(date: now, publication: publication)

        // One entry, and a reload asked for at the moment the answer changes.
        //
        // Nothing here counts down: the widget says when a routine runs — "7:30
        // AM", "Tomorrow 7:30 AM" — the way the routine's own card in the app
        // does, and a clock time is true until it happens. What DOES need a
        // reload is the firing itself — at 07:30 the next routine has to become
        // a result, or the one after. The app also reloads this explicitly
        // whenever it publishes, which covers every change a person makes; this
        // date covers the one nobody makes, where time simply passes.
        let policy: TimelineReloadPolicy
        if let firing = publication?.next?.firing, firing > now {
            policy = .after(min(firing, Self.nextMidnight(after: now)))
        } else {
            // No known next firing. An hour is a floor, not a promise — iOS
            // decides when widgets actually reload, and asking for sooner does
            // not make it happen.
            policy = .after(now.addingTimeInterval(3_600))
        }
        completion(Timeline(entries: [entry], policy: policy))
    }

    /// Midnight, because "Tomorrow 7:30 AM" becomes a plain "7:30 AM" then.
    static func nextMidnight(after instant: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: instant,
            matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) ?? instant.addingTimeInterval(86_400)
    }
}

struct SchedulesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SchedulesEntry

    private var publication: SchedulePublication? { entry.publication }

    var body: some View {
        content
            // The list of routines, pushed onto Today (`Navigator.follow`): a
            // widget about what Pocketd does on its own opens onto the screen
            // where those things are, not onto the brief.
            .widgetURL(URL(string: "pocketd://routines"))
            .containerBackground(for: .widget) { background }
    }

    /// The app's cream on the home screen; nothing on the lock screen, whose
    /// vibrant material turns any fill into a grey smudge behind the words.
    /// Every family declares one: a widget without it draws iOS's "adopt
    /// containerBackground" placeholder instead of itself.
    @ViewBuilder private var background: some View {
        switch family {
        case .accessoryInline, .accessoryRectangular: Color.clear
        default: WidgetPalette.background
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            lockScreen
        default:
            homeScreen
        }
    }

    // MARK: - Home screen

    @ViewBuilder private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ROUTINES")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(WidgetPalette.secondary)

            if let publication, publication.enabledCount > 0 || publication.latest != nil {
                routines(publication)
            } else {
                // "Nothing set up" and "nothing coming up" are different
                // sentences and send a reader to different places. A widget
                // that says "nothing due" to somebody who has never made a
                // routine is a dead end; this one is a door, and the tap lands
                // on the screen that sets one up.
                Text("No routines yet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WidgetPalette.ink)
                Text("Get your day every morning.")
                    .font(.caption)
                    .foregroundStyle(WidgetPalette.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func routines(_ publication: SchedulePublication) -> some View {
        // Waiting first, because it is the only state on this widget that asks
        // the reader to do something: a routine that needs Pocketd to think came
        // due while the app was closed, and opening it is what writes it.
        if publication.waitingCount > 0 {
            Text("\(Format.counted(publication.waitingCount, "routine")) waiting")
                .font(.headline)
                .foregroundStyle(WidgetPalette.caution)
            Text("Pocketd writes it when you open the app.")
                .font(.caption)
                .foregroundStyle(WidgetPalette.secondary)
        } else if let next = publication.next {
            Text(next.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(2)
            Text(when(next.firing))
                .font(.caption)
                .foregroundStyle(WidgetPalette.secondary)
            if next.needsModel {
                // The honesty requirement, on the surface most likely to be read
                // by somebody who never opened Routines. A routine that asks
                // Pocketd a question cannot think while the app is closed, and
                // finding that out at 09:00 from an absence is the failure this
                // line exists to prevent. Brief routines never say it: Today's
                // brief arrives without the app.
                Text("Written when you open Pocketd")
                    .font(.caption2)
                    .foregroundStyle(WidgetPalette.secondary)
            }
        } else if publication.enabledCount > 0 {
            Text("Nothing coming up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WidgetPalette.ink)
            Text("Every routine has run.")
                .font(.caption)
                .foregroundStyle(WidgetPalette.secondary)
        }

        if family != .systemSmall, let latest = publication.latest {
            Rectangle()
                .fill(WidgetPalette.divider)
                .frame(height: 1)
                .padding(.vertical, 1)
            HStack(spacing: 4) {
                Image(systemName: latest.standing.symbol)
                    .foregroundStyle(latest.standing.tint)
                Text(latest.title)
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
                Text(ran(latest.ranAt))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
            }
            .font(.caption2)
        }
    }

    // MARK: - Lock screen

    /// The inline family renders ONE `Text`, `Image` or `Label` and silently
    /// ignores anything else — no warning, no fallback, just a blank slot next
    /// to the clock. `ViewThatFits` was here and would have shipped as nothing,
    /// which is why this is its own branch rather than sharing the rectangular
    /// one below.
    @ViewBuilder private var inline: some View {
        if let publication, publication.waitingCount > 0 {
            Label("\(Format.count(publication.waitingCount)) waiting", systemImage: "hourglass")
        } else if let next = publication?.next {
            // Title and time in one Text, because two would be two views.
            Label("\(next.title) \(when(next.firing))", systemImage: "alarm")
        } else {
            Label("No routines due", systemImage: "alarm")
        }
    }

    @ViewBuilder private var lockScreen: some View {
        if let publication, publication.waitingCount > 0 {
            Label("\(Format.counted(publication.waitingCount, "routine")) waiting", systemImage: "hourglass")
        } else if let next = publication?.next {
            // The title is included here: it is the user's own words, on their
            // own lock screen. Nothing read from a calendar, a reminder list or
            // a model reaches this view — `SchedulePublication` has no field
            // that could carry it.
            VStack(alignment: .leading, spacing: 2) {
                Label(next.title, systemImage: "alarm")
                    .font(.headline)
                    .lineLimit(1)
                Text(when(next.firing))
                    .font(.caption)
            }
        } else {
            Label("No routines due", systemImage: "alarm")
        }
    }

    // MARK: - Words

    /// "7:30 AM" today, "Tomorrow 7:30 AM", "Monday 7:30 AM" — the time the
    /// routine's card in the app leads with, in the app's own formats.
    private func when(_ firing: Date) -> String {
        let time = Format.time(firing)
        guard Format.dayGap(from: entry.date, to: firing) != 0 else { return time }
        return "\(Format.day(firing, relativeTo: entry.date)) \(time)"
    }

    /// "9:00 AM" for a run today, "Yesterday" or a weekday before that.
    private func ran(_ instant: Date) -> String {
        Format.dayGap(from: instant, to: entry.date) == 0
            ? Format.time(instant)
            : Format.day(instant, relativeTo: entry.date)
    }
}

private extension SchedulePublication.Standing {
    var symbol: String {
        switch self {
        case .reported: "checkmark.circle.fill"
        case .nothingToReport: "minus.circle"
        case .waiting: "hourglass"
        case .trouble: "exclamationmark.triangle.fill"
        }
    }

    /// The app's meaning colours: green for a result, amber for your turn.
    var tint: Color {
        switch self {
        case .reported: WidgetPalette.positive
        case .nothingToReport, .waiting: WidgetPalette.secondary
        case .trouble: WidgetPalette.caution
        }
    }
}

struct SchedulesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.pocketd.widget.schedules", provider: SchedulesProvider()) { entry in
            SchedulesWidgetView(entry: entry)
        }
        .configurationDisplayName("Routines")
        .description("Your next routine, and anything waiting for you.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct PocketdWidgetBundle: WidgetBundle {
    var body: some Widget {
        SchedulesWidget()
        TodayWidget()
        DownloadLiveActivity()
        // Deployment target is iOS 18, so this needs no availability check.
        AskPocketdControl()
    }
}
