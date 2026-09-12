import SwiftUI
import WidgetKit

/// What a home screen is allowed to say about somebody's schedule.
///
/// The whole widget answers one question — is something waiting for me — and
/// deliberately not the next one, which is what it says. `SchedulePublication`
/// carries no run text at all, so there is no version of this view that could
/// render a model's answer about a health record; the type is the guard, and
/// this file could not leak that if it tried.
struct SchedulesEntry: TimelineEntry {
    let date: Date
    let publication: SchedulePublication?
}

struct SchedulesProvider: TimelineProvider {

    func placeholder(in context: Context) -> SchedulesEntry {
        // Shown while the system renders a gallery preview and during the
        // first frame. Plausible rather than empty, because a widget that
        // previews as "nothing set up" is one nobody adds.
        SchedulesEntry(
            date: Date(),
            publication: SchedulePublication(
                generatedAt: Date(),
                next: .init(title: "Morning briefing",
                            firing: Date().addingTimeInterval(3_600),
                            needsModel: true),
                latest: nil,
                enabledCount: 1,
                waitingCount: 0
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SchedulesEntry) -> Void) {
        completion(SchedulesEntry(date: Date(), publication: SchedulePublicationStore().read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SchedulesEntry>) -> Void) {
        let now = Date()
        let publication = SchedulePublicationStore().read()
        let entry = SchedulesEntry(date: now, publication: publication)

        // One entry, and a reload asked for at the moment the answer changes.
        //
        // The countdown itself needs no entries: `Text(_:style:.relative)` is
        // rendered by the system and ticks between reloads, so generating an
        // entry per minute would spend the widget's whole refresh budget
        // redrawing a clock iOS is already drawing.
        //
        // What DOES need a reload is the firing itself — at 07:00 "in 2
        // minutes" has to become either a result or a promise. The app also
        // reloads this explicitly whenever it publishes, which covers every
        // change a user makes; this date covers the one change nobody makes,
        // where time simply passes.
        let policy: TimelineReloadPolicy
        if let firing = publication?.next?.firing, firing > now {
            policy = .after(firing)
        } else {
            // No known next firing. An hour is a floor, not a promise — iOS
            // decides when widgets actually reload, and asking for sooner does
            // not make it happen.
            policy = .after(now.addingTimeInterval(3_600))
        }
        completion(Timeline(entries: [entry], policy: policy))
    }
}

struct SchedulesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SchedulesEntry

    private var publication: SchedulePublication? { entry.publication }

    var body: some View {
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
            Label("Pocketd", systemImage: "clock.badge")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if let publication, publication.enabledCount > 0 || publication.latest != nil {
                content(publication)
            } else {
                // "Nothing set up" and "nothing due" are different sentences and
                // send a reader to different places. A widget that says "nothing
                // due" to somebody who has never made a task is a dead end.
                Text("No scheduled tasks")
                    .font(.subheadline.weight(.medium))
                Text("Set one up to see it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private func content(_ publication: SchedulePublication) -> some View {
        // Waiting first, because it is the only state on this widget that asks
        // the reader to do something: a prompt task came due while the app was
        // closed, and opening it is what collects the answer.
        if publication.waitingCount > 0 {
            Text(publication.waitingCount == 1 ? "1 task waiting" : "\(publication.waitingCount) tasks waiting")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Open Pocketd to run them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let next = publication.next {
            Text(next.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text(next.firing, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
            if next.needsModel {
                // The honesty requirement, on the surface most likely to be
                // read by somebody who never opened the Schedules screen. A
                // prompt task cannot think while the app is closed, and finding
                // that out at 09:00 from an absence is the failure this line
                // exists to prevent.
                Text("Needs the app open")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else if publication.enabledCount > 0 {
            Text("Nothing due")
                .font(.subheadline.weight(.medium))
            Text("Every task has run.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if family != .systemSmall, let latest = publication.latest {
            Divider().padding(.vertical, 1)
            HStack(spacing: 4) {
                Image(systemName: latest.standing.symbol)
                    .foregroundStyle(latest.standing.tint)
                Text(latest.title).lineLimit(1)
                Text(latest.ranAt, style: .relative)
                    .foregroundStyle(.tertiary)
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
            Label("\(publication.waitingCount) waiting", systemImage: "hourglass")
        } else if let next = publication?.next {
            // Title and countdown in one Text, because two would be two views.
            Label {
                Text("\(next.title) ") + Text(next.firing, style: .relative)
            } icon: {
                Image(systemName: "clock")
            }
        } else {
            Label("Nothing due", systemImage: "clock")
        }
    }

    @ViewBuilder private var lockScreen: some View {
        if let publication, publication.waitingCount > 0 {
            Label("\(publication.waitingCount) waiting", systemImage: "hourglass")
        } else if let next = publication?.next {
            // The title is included here: it is the user's own words, on their
            // own lock screen. Nothing read from a calendar, a reminder list or
            // a model reaches this view — `SchedulePublication` has no field
            // that could carry it.
            VStack(alignment: .leading, spacing: 2) {
                Label(next.title, systemImage: "clock")
                    .font(.headline)
                    .lineLimit(1)
                Text(next.firing, style: .relative)
                    .font(.caption)
            }
        } else {
            Label("Nothing due", systemImage: "clock")
        }
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

    var tint: Color {
        switch self {
        case .reported: .green
        case .nothingToReport, .waiting: .secondary
        case .trouble: .orange
        }
    }
}

struct SchedulesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.pocketd.widget.schedules", provider: SchedulesProvider()) { entry in
            SchedulesWidgetView(entry: entry)
        }
        .configurationDisplayName("Schedules")
        .description("What Pocketd will do next, and whether anything is waiting for you.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct PocketdWidgetBundle: WidgetBundle {
    var body: some Widget {
        SchedulesWidget()
        DownloadLiveActivity()
    }
}
