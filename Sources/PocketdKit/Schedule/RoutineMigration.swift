import Foundation

/// Brings a routine written by an older build into the current model.
///
/// Two changes, both about names a person never chose:
///
/// 1. **The two template briefs become brief routines.** v2 (1.1.0) stored
///    "Morning brief" and "Evening wrap-up" as free-text prompts that needed a
///    tool-capable brain and the app open, and wrote their answer on Routines —
///    a second paragraph about the morning that disagreed with the one on
///    Today. A stored prompt that is *word for word* one of those two templates
///    is turned into `TaskBody.brief`. A prompt the user edited is their own
///    words and is left exactly as it is: it is now an "Ask Pocketd" routine,
///    which is what it always was.
///
///    The promises such a routine was still holding (`.awaitingForeground`,
///    "due, not written yet") are dropped rather than lapsed. They were
///    promises to write a paragraph that is now written on Today; carrying them
///    over would put a "Writing…" on a card for something that will never be
///    written there, and count it on the widget as waiting. Every run that
///    actually happened stays in the history.
///
/// 2. **"Overdue watcher" is called "Overdue nudge".** "Watcher" is a word from
///    the code that reached the screen (spec §8: never "watcher"). Renamed only
///    when the routine is still the template's own rule, so a task somebody
///    built themselves and happened to call that is not touched.
///
/// Applied at decode — see `ScheduledTask.init(from:)` — and idempotent, so it
/// needs no flag and no ordering between the app and a background refresh.
public enum RoutineMigration {

    /// The exact prompts v2 shipped for the two brief templates, before they
    /// became `.brief`. History has exactly one version of each
    /// (`RoutineTemplate.swift`, 5225f1e); onboarding's morning-brief step
    /// saved the same text. Written out rather than derived, because the
    /// templates no longer produce them and the migration must keep
    /// recognising what is on people's phones after that.
    static let legacyBriefPrompts: [String] = [
        """
        Write my brief for today in two or three sentences: what is next on my calendar, \
        what is due, and how I slept. Warm and plain. No lists and no headings. \
        Only mention things you actually found.
        """,
        """
        Look back over today and ahead to tomorrow. In two or three sentences: what was on \
        today, what is still open on my list, and what tomorrow starts with. \
        Warm and plain. No lists and no headings. Only mention things you actually found.
        """,
    ]

    /// Old template titles and what they are called now.
    static let renamedTitles: [(old: String, new: RoutineTemplate)] = [
        ("Overdue watcher", .overdueWatcher),
    ]

    /// Whether this text is one of the shipped brief prompts, ignoring the
    /// whitespace a text editor might have added or folded.
    static func isLegacyBriefPrompt(_ text: String) -> Bool {
        let normalised = normalise(text)
        return legacyBriefPrompts.contains { normalise($0) == normalised }
    }

    /// Runs every step. Safe to call any number of times.
    public static func apply(to task: inout ScheduledTask) {
        if case .prompt(let text) = task.body, isLegacyBriefPrompt(text) {
            task.body = .brief
            task.runs.removeAll(where: \.isAwaitingForeground)
        }
        for rename in renamedTitles
        where task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rename.old) == .orderedSame
            && task.body == rename.new.body {
            task.title = rename.new.title
        }
    }

    /// The value-returning spelling, for a caller that holds a `let`.
    public static func migrated(_ task: ScheduledTask) -> ScheduledTask {
        var copy = task
        apply(to: &copy)
        return copy
    }

    private static func normalise(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
