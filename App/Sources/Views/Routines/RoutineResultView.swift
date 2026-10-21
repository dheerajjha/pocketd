import PocketdKit
import SwiftUI

/// What one routine has been saying, as a page.
///
/// The detail-page grammar (spec §3.2): the routine's name as the title, one
/// grey sentence saying when it last ran, what it said in full, and the runs
/// before that. Pushed — from a card's last line, from a notification tap
/// (`AppModel.takeRoutineTap()` answers `.result(id)`), or from a Today card —
/// onto whatever stack is showing, so it brings no `NavigationStack` and no
/// Done button of its own.
///
/// Read by id from the live list rather than handed a copy: a sweep can settle
/// a run while this page is open, and this page is the one place somebody is
/// looking at exactly that.
///
/// The run text is the person's own calendar and reminders read back to them,
/// so it is selectable — it is on their disk either way — and it comes through
/// `ScheduleWords.summary`, which sanitises on the way out.
struct RoutineResultView: View {
    @Environment(AppModel.self) private var model

    let taskID: UUID
    /// The "Ask anything else" composer, for a shell that has one. Nil draws
    /// the page without it.
    var composer: ContextComposer?

    private var task: ScheduledTask? { model.scheduledTasks.first { $0.id == taskID } }

    var body: some View {
        if let task {
            page(task)
                .onAppear { model.markRoutineResultsSeen() }
        } else {
            gone
        }
    }

    // MARK: - The page

    private func page(_ task: ScheduledTask) -> some View {
        let history = Self.history(of: task)
        let isWriting = model.isWritingRoutine(task)
        return DetailPage(title: task.title, summary: summary(task, latest: history.first, isWriting: isWriting), composer: composer) {
            if isWriting {
                writingCard
            } else if let latest = history.first {
                latestCard(latest, in: task)
            } else {
                nothingYetCard(task)
            }
            let earlier = isWriting ? history : Array(history.dropFirst())
            if !earlier.isEmpty {
                SectionLabel("Before that")
                PDCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(earlier.enumerated()), id: \.element.id) { index, run in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.pd.divider)
                                    .frame(height: 1)
                            }
                            row(run, in: task)
                                .padding(.top, index == 0 ? 0 : PDSpacing.s)
                                .padding(.bottom, index == earlier.count - 1 ? 0 : PDSpacing.s)
                        }
                    }
                }
            }
        }
    }

    /// Newest first, promises left out: a promise is not a run, and listing it
    /// beside the run that kept it would describe one firing twice.
    static func history(of task: ScheduledTask) -> [TaskRun] {
        task.runs.filter { !$0.isAwaitingForeground }.sorted { $0.ranAt > $1.ranAt }
    }

    private func summary(_ task: ScheduledTask, latest: TaskRun?, isWriting: Bool) -> String {
        if isWriting { return "Pocketd is writing this now." }
        if let latest { return ScheduleWords.ran(latest, of: task) }
        guard task.isEnabled else { return "It's switched off." }
        guard let next = task.dueness().next else { return "It won't run again." }
        return "It runs \(ScheduleWords.when(next))."
    }

    // MARK: - The last thing it said

    private func latestCard(_ run: TaskRun, in task: ScheduledTask) -> some View {
        let said = ScheduleWords.summary(of: run, in: task)
        return PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                Text(said.text)
                    .font(Font.pd.lead)
                    .foregroundStyle(said.isTrouble ? Color.pd.caution : Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(ScheduleWords.context(run.context))
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var writingCard: some View {
        PDCard {
            HStack(spacing: PDSpacing.s) {
                ProgressView()
                Text("Writing…")
                    .font(Font.pd.lead)
                    .foregroundStyle(Color.pd.inkSecondary)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func nothingYetCard(_ task: ScheduledTask) -> some View {
        PDCard {
            Text(task.body == .brief
                 ? "Your brief will be ready on Today at that time."
                 : "What it finds will be here.")
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Everything before that

    private func row(_ run: TaskRun, in task: ScheduledTask) -> some View {
        let said = ScheduleWords.summary(of: run, in: task)
        return VStack(alignment: .leading, spacing: PDSpacing.xxs) {
            Text(ScheduleWords.when(run.ranAt).capitalisedFirst)
                .font(Font.pd.footnote.weight(.medium))
                .foregroundStyle(Color.pd.inkSecondary)
            Text(said.text)
                .font(Font.pd.body)
                .foregroundStyle(said.isTrouble ? Color.pd.caution : Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Deleted underneath

    /// A routine deleted while its page was open, or before a notification
    /// for it was tapped. Said plainly rather than shown as an empty page.
    private var gone: some View {
        VStack(spacing: PDSpacing.s) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(.largeTitle))
                .foregroundStyle(Color.pd.inkTertiary)
                .accessibilityHidden(true)
            Text("This routine was deleted.")
                .font(Font.pd.headline)
                .foregroundStyle(Color.pd.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pdCanvas()
    }
}

#if DEBUG
#Preview("Result light") {
    NavigationStack {
        RoutineResultView(taskID: UUID())
    }
    .environment(AppModel())
}
#endif
