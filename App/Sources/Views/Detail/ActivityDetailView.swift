import PocketdKit
import SwiftUI

/// Activity: today's steps beside where a usual day has got to by now, and
/// the week before.
///
/// The Sleep page's shape, for steps, and the Activity tile's rule: the grey
/// figure is "usual by now" when there is an hour-by-hour history to compare
/// with, and "usual a day" when there is only the daily total — in which case
/// the page says so rather than judging a morning against a whole day.
struct ActivityDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    @State private var detail: ActivityDetail?
    private var reads = true

    init() {}

    /// A page with its days already read, for previews.
    init(detail: ActivityDetail) {
        _detail = State(initialValue: detail)
        reads = false
    }

    var body: some View {
        DetailPage(
            title: "Activity",
            summary: detail?.summary,
            composer: PageQuestion.composer(detail?.suggestion, navigator: navigator, model: model)
        ) {
            if let detail {
                content(detail)
            }
        }
        .refreshable { await read() }
        .task(id: model.briefing.snapshot) { await read() }
    }

    private func read() async {
        guard reads else { return }
        detail = await model.activityDetail()
    }

    @ViewBuilder
    private func content(_ detail: ActivityDetail) -> some View {
        if !detail.availability.isReadable {
            ConnectSourceLink(ability: .health, availability: detail.availability)
        } else {
            PDCard {
                ComparisonTiles(
                    usual: .init(detail.usualLabel, value: detail.usualText(), unit: "steps"),
                    current: .init("Today", value: detail.todayText(), unit: "steps"),
                    delta: detail.today == nil ? nil : detail.deltaSentence
                )
            }
            if !detail.days.isEmpty {
                PageSection("Last 7 days") {
                    RowCard(detail.days) { day in
                        DataRow(
                            title: day.label(relativeTo: DemoClock.now),
                            subtitle: day.isToday ? "So far" : nil,
                            value: day.valueText(),
                            valueTint: day.steps == nil ? .pd.inkSecondary : .pd.ink
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Activity light") {
    NavigationStack {
        ActivityDetailView(detail: DetailPreviewData.activity)
    }
    .detailPreviewEnvironment()
}

#Preview("Activity dark") {
    NavigationStack {
        ActivityDetailView(detail: DetailPreviewData.activity)
    }
    .detailPreviewEnvironment()
    .preferredColorScheme(.dark)
}
