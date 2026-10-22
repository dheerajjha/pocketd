import PocketdKit
import SwiftUI

/// Your day: what is on now, what is left today, and what tomorrow starts
/// with.
///
/// Behind the Up next tile. Read straight from EventKit (`AppModel.yourDay`)
/// and grouped and summarised by the Kit's `DayAgenda`, so this page says what
/// the tile said, in the same words, and none of it comes from a brain.
///
/// Two rows a group, then "Show N more": enough to see what is next without
/// the page turning into the Calendar app. Each row carries its own ways out —
/// Directions when the event has a place, Open in Calendar always — so acting
/// on an event needs no page in between.
struct DayDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var agenda: DayAgenda?
    @State private var expanded: Set<DayAgenda.Group> = []

    /// False only for a preview, which hands the page its day.
    private var reads = true

    init() {}

    /// A page with its day already read, for previews.
    init(agenda: DayAgenda) {
        _agenda = State(initialValue: agenda)
        reads = false
    }

    var body: some View {
        DetailPage(
            title: "Your day",
            summary: agenda?.summary,
            composer: PageQuestion.composer(agenda?.suggestion, navigator: navigator, model: model)
        ) {
            if let agenda {
                content(agenda)
            }
        }
        .refreshable { await read() }
        // Read on arrival, and again whenever Today's reading of the day
        // moves — a meeting moved in Calendar, the app back from the
        // background — so a page left open does not go on listing the old day.
        .task(id: model.briefing.snapshot) { await read() }
        // Read and left: one useful answer for the review gate, when the page
        // showed something of the person's own. See `ReviewMoment`.
        .onDisappear { if agenda?.reportsSomething == true { model.noteUsefulAnswer() } }
    }

    private func read() async {
        guard reads else { return }
        agenda = await model.yourDay()
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ agenda: DayAgenda) -> some View {
        if !agenda.availability.isReadable {
            ConnectSourceLink(ability: .calendar, availability: agenda.availability)
        } else {
            ForEach(agenda.sections) { section in
                PageSection(section.group.title) {
                    let isOpen = expanded.contains(section.group)
                    RowCard(isOpen ? section.events : section.visible()) { event in
                        row(event)
                    } footer: {
                        if section.hiddenCount() > 0 {
                            ShowMoreButton(hiddenCount: section.hiddenCount(), isExpanded: isOpen) {
                                toggle(section.group)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Title, place and length, the start time on the right.
    ///
    /// An all-day event has no time to put there, and "All day" is already
    /// its grey line: the column is for figures, and a word in it would be
    /// the same word twice.
    private func row(_ event: DayEvent) -> some View {
        DataRow(
            title: event.title,
            subtitle: event.detailText(),
            value: event.isAllDay ? nil : event.timeText(),
            links: links(for: event)
        )
        // The link chips are drawn 28pt tall inside 44pt targets, so the last
        // line of every row carries 8pt of invisible target under it. Letting
        // that overhang the gap below keeps a row's space under its chips the
        // same as the space over its title, instead of every row (and the
        // card's last) looking bottom-heavy.
        .padding(.bottom, -PDSpacing.xs)
    }

    private func links(for event: DayEvent) -> [DataRow.Link] {
        var links: [DataRow.Link] = []
        if let directions = event.directionsURL {
            links.append(.init("Directions") { openURL(directions) })
        }
        links.append(.init("Open in Calendar") { openURL(event.calendarURL) })
        return links
    }

    private func toggle(_ group: DayAgenda.Group) {
        withAnimation(reduceMotion ? nil : PDMotion.standard) {
            if expanded.contains(group) {
                expanded.remove(group)
            } else {
                expanded.insert(group)
            }
        }
    }
}

// MARK: - Previews

#Preview("Your day light") {
    NavigationStack {
        DayDetailView(agenda: DetailPreviewData.day)
    }
    .detailPreviewEnvironment()
}

#Preview("Your day dark") {
    NavigationStack {
        DayDetailView(agenda: DetailPreviewData.day)
    }
    .detailPreviewEnvironment()
    .preferredColorScheme(.dark)
}

#Preview("Your day AX") {
    NavigationStack {
        DayDetailView(agenda: DetailPreviewData.day)
    }
    .detailPreviewEnvironment()
    .dynamicTypeSize(.accessibility3)
}

#Preview("Your day calendar off") {
    NavigationStack {
        DayDetailView(agenda: DayAgenda.make(events: [], availability: .off, now: DetailPreviewData.now))
    }
    .detailPreviewEnvironment()
}
