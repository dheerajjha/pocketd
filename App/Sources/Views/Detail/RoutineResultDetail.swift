import PocketdKit
import SwiftUI

/// A routine's result, as a detail page: B3's `RoutineResultView`, given the
/// composer every detail page ends in.
///
/// Only the question is decided here. The page itself — the name, when it
/// ran, what it said, the runs before — is B3's, and is not drawn twice.
struct RoutineResultDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    let taskID: UUID

    var body: some View {
        RoutineResultView(
            taskID: taskID,
            composer: PageQuestion.composer(question, navigator: navigator, model: model)
        )
    }

    /// The question that follows on from what this routine reports: a brief
    /// leads to the day it was about, the overdue nudge to the overdue list,
    /// the weekly review to the week ahead. A routine somebody wrote
    /// themselves could be about anything, so it gets the most useful
    /// question there is.
    private var question: String {
        guard let task = model.scheduledTasks.first(where: { $0.id == taskID }),
              let template = RoutineTemplate.matching(task)
        else { return TodayQuestion.today }
        switch template {
        case .morningBrief: return TodayQuestion.today
        case .eveningWrapUp: return TodayQuestion.tomorrow
        case .weeklyReview: return "What's on next week?"
        case .overdueWatcher: return TodayQuestion.overdue
        case .sleepWatcher: return TodayQuestion.sleep
        }
    }
}
