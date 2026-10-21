import Foundation

/// What a brief routine says when it fires.
///
/// A brief routine (`TaskBody.brief`) is Today's brief arriving at a time the
/// user chose. Its notification is the run: "Your morning brief is ready.",
/// plus one sentence about the day when a background refresh got to read it.
/// Tapping it opens Today, where the brief itself is written — by the brain if
/// there is one, by the template if not.
///
/// The sentence is not built here. It is `BriefPrompt.notificationSentence`,
/// the brief's own clauses with every title left out — the lock screen is read
/// by whoever holds the phone, and `NotificationCentre` already keeps event
/// titles and reminder names off it. One builder for the brief and its banner
/// means they cannot count a day differently.
public enum BriefRoutine {

    /// The banner's title: "Your morning brief is ready."
    ///
    /// The two templates have names people say, and the sentence uses them. A
    /// brief routine somebody named themselves is announced by that name, which
    /// is the one piece of text on the banner that is theirs.
    public static func headline(for task: ScheduledTask) -> String {
        switch RoutineTemplate.matching(task) {
        case .morningBrief: return "Your morning brief is ready."
        case .eveningWrapUp: return "Your evening wrap-up is ready."
        default:
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Your brief is ready." : "\(title) is ready."
        }
    }
}
