import Foundation

/// A deliberately narrower grammar than the *routing* vocabulary. A tool may
/// be useful on “how do I set a reminder?”; that sentence authorizes no write.
/// Only a direct, affirmative command is recognized, before seeing any model
/// arguments. Unknown phrasings/languages fail closed; titles may be in any script.
struct ModelWriteIntent: Sendable {
    typealias Change = SystemToolPolicy.Change
    let change: Change
    private let target: String

    init?(_ submitted: String) {
        var s = Self.fold(submitted).trimmingCharacters(in: .whitespacesAndNewlines)
        // A quoted command, pasted transcript, second sentence or condition is
        // not a single instruction. Do not remove punctuation from the front.
        while let last = s.last, ".!?".contains(last) { s.removeLast() }
        // A quoted name (“Do Not Disturb”) or the task in “remind me not to
        // call” does not negate the directive. Keep the original words for
        // matching the proposed title, including the word “not”.
        let directive = s.replacingOccurrences(of: #""[^"\n]+"|“[^”\n]+”|‘[^'\n]+'|(?<!\p{L})'[^'\n]+'(?!\p{L})"#, with: "title", options: .regularExpression)
            .replacingOccurrences(of: "remind me not to ", with: "remind me to ")
        guard !s.isEmpty, s.count <= 1_024, !s.contains(where: \.isNewline),
              !Self.matches(#"[;!?]|\.(?:\s|$)|\b(?:if|unless|instead|pretend|hypothetically|but|actually|don't|not|never|no longer|rather than|only when|just kidding|(?:as|in) an example|for example|just explain|how (?:do|would|can|should) (?:i|we)|without (?:saving|creating|adding|setting|making|marking)|and then|and (?:create|schedule|remind|tick|mark))\b"#, directive)
        else { return nil }
        func strip(_ pattern: String) -> Bool {
            guard let r = s.range(of: "^(?:" + pattern + #")(?:\s+|$)"#, options: .regularExpression) else { return false }
            s.removeSubrange(r); return true
        }
        _ = strip("please|kindly")
        _ = strip("(?:can|could|would|will) you|i would like you to|i'd like you to|i want you to")
        _ = strip("please|kindly")
        s = s.replacingOccurrences(of: #",?\s+(?:please|thanks|thank you)$"#, with: "", options: .regularExpression)
        if strip("remind me") {
            guard let task = Self.reminderTask(s) else { return nil }
            s = task
            change = .addReminder
        } else if strip("tick off|check off|mark off") {
            _ = strip("(?:the |my )?(?:reminder|task)(?: called| named)?"); change = .tickOff
        } else if strip("mark") {
            guard let done = s.range(of: #"\s+(?:as\s+)?(?:done|complete|completed)$"#, options: .regularExpression) else { return nil }
            s.removeSubrange(done); _ = strip("(?:the |my )?(?:reminder|task)(?: called| named)?"); change = .tickOff
        } else if strip("complete (?:the |my )?(?:reminder|task)(?: called| named)?") {
            change = .tickOff
        } else {
            let schedule = Self.matches(#"^(?:schedule|book)\s"#, s)
            guard strip("add|create|put|set up|set|schedule|book") else { return nil }
            if strip("(?:me )?(?:(?:a|an|the|my|new) )*(?:reminder|to-do|todo|task)(?: called| named)?") {
                guard !Self.matches(Self.artifactNoun, s) else { return nil }
                change = .addReminder
            } else if let list = s.range(of: #"\s+(?:to|on|in|into) (?:my |the )?(?:reminders(?: list)?|shopping list|grocery list|to-do list|task list)\b"#, options: .regularExpression) {
                s.removeSubrange(list); change = .addReminder
            } else if strip("(?:(?:a|an|the|my|new) )*(?:calendar event|event|appointment)(?: called| named)?") {
                guard !Self.matches(Self.artifactNoun, s) else { return nil }
                change = .addEvent
            } else if let cal = s.range(of: #"\s+(?:to|on|in|into) (?:my |the )?calendar\b"#, options: .regularExpression) {
                s.removeSubrange(cal); change = .addEvent
            } else {
                // “Add two numbers” / “set a timer” / “book a flight” are not
                // calendar authority. Preserve the diary requests the app offers.
                guard Self.matches(#"^(?:a |an |the )?(?:\d+[ -](?:minute|hour)[ -])?(?:lunch|dinner|breakfast|brunch|meeting|call|workout|appointment|class|practice|session|standup|review|interview)\b"#, s)
                        || (schedule && s.hasPrefix("time for ")) else { return nil }
                change = .addEvent
            }
        }
        guard !s.isEmpty, !Self.matches(#"^(?:how (?:do|to|can)|whether|an example of)\b"#, s) else { return nil }
        target = s
    }

    private static let artifactNoun = #"^(?:app|application|system|template|example|handler|listener|script|api|function|schema|tutorial|bot)\b"#

    // “Remind me” can mean “tell me again”. Require positive evidence of a
    // task, not an ever-growing list of ways to ask a recall question.
    private static func reminderTask(_ rest: String) -> String? {
        let rest = rest.hasPrefix("again ") ? String(rest.dropFirst("again ".count)) : rest
        if matches(#"^(?:not )?to\s+(?!(?:whom|which|what|whose)\b)\S"#, rest) { return rest }
        // Also support an explicit time before the task: “tomorrow at 9 to
        // buy milk”, or “in 20 minutes about the oven”. Don't interpret a
        // date somewhere inside a recollection as the requested trigger.
        guard matches(#"^(?:(?:at|on|in|by|every|next|this|today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b|\d)"#, rest),
              !matches(#"^(?:at|in|on|by) (?:what|which|whose|whom|who|where|when|how|whether)\b"#, rest),
              let link = rest.range(of: #"\s+(?:to|about)\s+\S"#, options: .regularExpression) else { return nil }
        switch MomentPhrase.resolve(String(rest[..<link.lowerBound])) {
        case .moment, .repeating: return rest
        case .recurring, .unresolved: return nil
        }
    }

    /// Route a recall question by its subject, not by the word “remind”.
    /// A question about an appointment can still read Calendar.
    static func recallSubject(_ text: String) -> String? {
        let s = fold(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opening = s.range(of: #"^(?:(?:please|kindly)\s+)?(?:(?:(?:can|could|would|will) you|i(?: would|'d) like you to|i want you to)\s+)?(?:(?:please|kindly)\s+)?remind me\b[\s,]*"#, options: .regularExpression) else { return nil }
        let rest = String(s[opening.upperBound...])
        return reminderTask(rest) == nil ? rest : nil
    }

    /// Account for the entire object of the command, not just one shared noun.
    /// Thus “Call Jun” cannot authorize “Call June”, an old title, or a time,
    /// day or recurrence invented by the model. Omitted *requested* times also
    /// fail; an undated reminder is a different change from a dated one.
    func covers(title: String?, when: String?, minutes: Int?) -> Bool {
        guard let title, title.count <= 1_024, (when?.count ?? 0) <= 1_024,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        func literal(_ text: String) -> String { NSRegularExpression.escapedPattern(for: Self.fold(text).trimmingCharacters(in: .whitespacesAndNewlines)) }
        let t = #"(?:["“‘']?"# + literal(title) + #"["”’']?)"#
        let object = #"(?:(?:for me to|to|for|about|called|named)\s+)?"# + (change == .addEvent ? #"(?:an?\s+)?"# : "") + t
        // Don't let the model move a requested deadline into an undated
        // title or split “tomorrow at 9” into a title ending “tomorrow” and
        // a bare “9”. Explicitly quoted titles can themselves name a day.
        if change != .tickOff, Self.matches(#"\b(?:today|tomorrow|tonight|every|daily|weekly|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week|at \d+|(?:before|after) (?:lunch|dinner|breakfast)|in (?:\d+|an?|one|two) (?:minutes?|hours?|days?))\b|\b\d{1,2}(?::\d{2}|am|pm)\b"#, Self.fold(title)),
           !Self.matches(#"["“‘']"# + literal(title) + #"["”’']"#, target) { return false }
        var body = target
        if change == .addEvent, EventLength.statesALength(body) {
            // The legacy parser deliberately lets the model provide a number
            // whenever it sees *any* length. Require that actual number here.
            guard let minutes, minutes > 0 else { return false }
            let numbers = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
            func amount(_ n: Int) -> String { numbers.indices.contains(n) ? "(?:\(n)|\(numbers[n]))" : "\(n)" }
            var units = [amount(minutes) + #" ?(?:minutes?|mins?|m)"#]
            if minutes.isMultiple(of: 60) { units.append(amount(minutes / 60) + #" ?(?:hours?|hrs?|h)"#) }
            if minutes == 60 { units.append("an hour") }; if minutes == 30 { units.append("half an hour") }
            let unit = units.joined(separator: "|")
            let pattern = #"(?:^|\s)(?:for\s+|(?:a|an)\s+)?(?:"# + unit + #")(?:\s+long)?(?=\s|$)"#
            // Adjectival “90-minute workout” is the same length as “90 minutes”.
            body = body.replacingOccurrences(of: #"(\d)-(minute|hour)\b"#, with: "$1 $2", options: .regularExpression)
            guard let range = body.range(of: pattern, options: .regularExpression) else { return false }
            body.removeSubrange(range); body = body.trimmingCharacters(in: .whitespaces)
        }
        let shapes: [String]
        if let when, !when.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let w = literal(when)
            guard change != .tickOff else { return false }
            shapes = [object + #"\s+(?:(?:at|on|by|for|due|due on|due at|starting)\s+)?"# + w,
                      #"(?:(?:at|on|for|by)\s+)?"# + w + #"\s+(?:to|for|about)\s+"# + t]
        } else {
            shapes = [object, object + #"\s+(?:without a due date|with no due date)"#]
        }
        return shapes.contains { Self.matches("^(?:" + $0 + ")$", body) }
    }

    private static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\b([ap])\.m\."#, with: "$1m", options: .regularExpression)
            .replacingOccurrences(of: #"[\t\p{Zs}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)\s+(am|pm)\b"#, with: "$1$2", options: .regularExpression)
    }
    private static func matches(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
}
