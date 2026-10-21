import SwiftUI

/// The page behind a tile, or a routine's result: what the shell pushes for
/// `Route.detail(kind)`.
///
/// One switch, so the shell does not have to know which pages exist. Every one
/// of them is a `DetailPage` underneath — title, one grey sentence, the data in
/// white cards, one question and "Ask anything else" at the bottom — and none
/// brings a `NavigationStack` of its own: it is pushed onto the one stack
/// rooted at Today, and a second stack inside it would be a second navigation
/// bar.
struct DetailView: View {
    let kind: DetailKind

    var body: some View {
        switch kind {
        case .day:
            DayDetailView()
        case .reminders:
            RemindersDetailView()
        case .sleep:
            SleepDetailView()
        case .activity:
            ActivityDetailView()
        case let .routineResult(id):
            RoutineResultDetail(taskID: id)
        }
    }
}
