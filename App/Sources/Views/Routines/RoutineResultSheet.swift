import PocketdKit
import SwiftUI

/// What one routine has actually been saying.
///
/// The card on the list answers "is this working" in ninety characters; this
/// answers "what did it say", in full, and then shows the runs behind it. Both
/// and not one: a card that rendered the whole of this morning's brief would be
/// a list whose height is decided by somebody else's calendar, and a history
/// nobody can read the latest entry of is a log file.
///
/// The run text is the person's own calendar and reminders read back to them,
/// so it is selectable — it is on their disk either way — and it comes through
/// `ScheduleWords.summary`, which sanitises on the way out. A watcher's report
/// was sanitised on the way in; a brief written by the brain has not been, and
/// the bidi overrides `PromptSanitiser` removes are exactly what makes a block
/// of text show something other than what it holds.
struct RoutineResultSheet: View {
    @Environment(\.dismiss) private var dismiss

    let task: ScheduledTask

    /// Newest first, promises excluded.
    ///
    /// A promise is not a run — it is shown once, above, as the thing that is
    /// still owed. Listing it here as well would describe one firing twice,
    /// which is the mistake `ScheduledTask.settle` goes out of its way to avoid
    /// inside the record itself.
    private var history: [TaskRun] {
        task.runs.filter { !$0.isAwaitingForeground }.sorted { $0.ranAt > $1.ranAt }
    }

    private var latest: TaskRun? { history.first }
    private var earlier: [TaskRun] { Array(history.dropFirst()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                    scheduleLine

                    if let pending = task.pendingRun() {
                        Callout(
                            symbol: "hourglass",
                            text: "Due \(ScheduleWords.when(pending.firing)). Not written yet."
                        )
                    }

                    if let latest {
                        latestCard(latest)
                    } else {
                        nothingYetCard
                    }

                    if !earlier.isEmpty {
                        historySection
                    }
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.xs)
                .padding(.bottom, PDSpacing.xxl)
            }
            .scrollIndicators(.hidden)
            .pdCanvas()
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - The pattern, restated

    private var scheduleLine: some View {
        HStack(spacing: PDSpacing.xs) {
            MiniLabel(task.isEnabled ? "Runs" : "Paused", tint: task.isEnabled ? .pd.inkSecondary : .pd.inkTertiary)
            Text(ScheduleWords.recurrence(task.recurrence))
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The last thing it said

    private func latestCard(_ run: TaskRun) -> some View {
        let summary = ScheduleWords.summary(of: run, in: task)
        return PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
                    SectionLabel("Latest")
                    Spacer(minLength: PDSpacing.xs)
                    Text(ScheduleWords.when(run.ranAt).uppercased())
                        .font(Font.pd.label)
                        .tracking(1.2)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .accessibilityLabel(ScheduleWords.when(run.ranAt))
                }
                Text(summary.text)
                    .font(Font.pd.lead)
                    .foregroundStyle(summary.isTrouble ? Color.pd.caution : Color.pd.ink)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(ScheduleWords.context(run.context))
                    .font(Font.pd.caption)
                    .foregroundStyle(Color.pd.inkTertiary)
            }
        }
    }

    private var nothingYetCard: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                SectionLabel("Latest")
                Text("It has not run yet.")
                    .font(Font.pd.lead)
                    .foregroundStyle(Color.pd.ink)
                Text(nothingYetDetail)
                    .pdBody()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nothingYetDetail: String {
        guard task.isEnabled else {
            return "It is paused, so it keeps its schedule and produces nothing until you switch it back on."
        }
        guard let next = task.dueness().next else {
            return "Nothing further is scheduled for it."
        }
        return "The first result lands \(ScheduleWords.when(next))."
    }

    // MARK: - Everything before that

    private var historySection: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            SectionLabel("Before that")
            PDCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(earlier.enumerated()), id: \.element.id) { index, run in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.pd.divider)
                                .frame(height: 1)
                        }
                        row(for: run)
                            .padding(.top, index == 0 ? 0 : PDSpacing.s)
                            .padding(.bottom, index == earlier.count - 1 ? 0 : PDSpacing.s)
                    }
                }
            }
        }
    }

    private func row(for run: TaskRun) -> some View {
        let summary = ScheduleWords.summary(of: run, in: task)
        return VStack(alignment: .leading, spacing: PDSpacing.xxs) {
            Text(ScheduleWords.when(run.ranAt).uppercased())
                .font(Font.pd.miniLabel)
                .tracking(1.2)
                .foregroundStyle(Color.pd.inkSecondary)
                .accessibilityLabel(ScheduleWords.when(run.ranAt))
            Text(summary.text)
                .font(Font.pd.secondary)
                .foregroundStyle(summary.isTrouble ? Color.pd.caution : Color.pd.ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // The one line that makes the whole constraint legible without a
            // paragraph about Metal: a watcher's history reads "while Pocketd
            // was closed" every morning, a brief's reads "when you opened the
            // app", and the difference explains itself.
            Text(ScheduleWords.context(run.context))
                .font(Font.pd.caption)
                .foregroundStyle(Color.pd.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

/// A simulator cannot load a brain that writes one of these, so both previews
/// run on fabricated `TaskRun`s — see `RoutinePreviewData`.
#Preview("Result sheet light") {
    RoutineResultSheet(task: RoutinePreviewData.morningBrief)
}

#Preview("Result sheet dark") {
    RoutineResultSheet(task: RoutinePreviewData.morningBrief)
        .preferredColorScheme(.dark)
}

#Preview("Result sheet watcher light") {
    RoutineResultSheet(task: RoutinePreviewData.overdueWatcher)
}
