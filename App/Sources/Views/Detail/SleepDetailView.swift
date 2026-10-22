import PocketdKit
import SwiftUI

/// Sleep: last night beside your usual, what the difference means, and the
/// week before it.
///
/// Behind the Sleep tile, and built by the same rule (`SleepDetail` takes its
/// verdict from `TodayVerdicts.sleep`), so the sentence under the two figures
/// is the tile's sentence and the page can never call a night short that the
/// tile called rested.
///
/// USUAL on the left in grey, LAST NIGHT on the right in ink: a figure with no
/// baseline is trivia, two side by side are a comparison anybody can make. The
/// list under them is the seven nights the usual is mostly made of, the
/// evening each began on the left and the length in mono on the right, with a
/// missing night shown as a dash rather than closed up.
struct SleepDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    @State private var detail: SleepDetail?
    private var reads = true

    init() {}

    /// A page with its nights already read, for previews.
    init(detail: SleepDetail) {
        _detail = State(initialValue: detail)
        reads = false
    }

    var body: some View {
        DetailPage(
            title: "Sleep",
            summary: detail?.summary,
            composer: PageQuestion.composer(detail?.suggestion, navigator: navigator, model: model)
        ) {
            if let detail {
                content(detail)
            }
        }
        .refreshable { await read() }
        .task(id: model.briefing.snapshot) { await read() }
        // Read and left: one useful answer for the review gate, when the page
        // showed something of the person's own. See `ReviewMoment`.
        .onDisappear { if detail?.reportsSomething == true { model.noteUsefulAnswer() } }
    }

    private func read() async {
        guard reads else { return }
        detail = await model.sleepDetail()
    }

    @ViewBuilder
    private func content(_ detail: SleepDetail) -> some View {
        if !detail.availability.isReadable {
            ConnectSourceLink(ability: .health, availability: detail.availability)
        } else {
            PDCard {
                ComparisonTiles(
                    usual: .init("Usual", value: detail.usualText),
                    current: .init("Last night", value: detail.lastNightText),
                    delta: detail.lastNight == nil ? nil : detail.deltaSentence
                )
            }
            if !detail.nights.isEmpty {
                PageSection("Last 7 nights") {
                    RowCard(detail.nights) { night in
                        DataRow(
                            title: night.label(relativeTo: DemoClock.now),
                            value: night.valueText,
                            valueTint: night.duration == nil ? .pd.inkSecondary : .pd.ink
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Sleep light") {
    NavigationStack {
        SleepDetailView(detail: DetailPreviewData.sleep)
    }
    .detailPreviewEnvironment()
}

#Preview("Sleep dark") {
    NavigationStack {
        SleepDetailView(detail: DetailPreviewData.sleep)
    }
    .detailPreviewEnvironment()
    .preferredColorScheme(.dark)
}

#Preview("Sleep AX") {
    NavigationStack {
        SleepDetailView(detail: DetailPreviewData.sleep)
    }
    .detailPreviewEnvironment()
    .dynamicTypeSize(.accessibility3)
}
