import Foundation

/// One entry, with the repeat count folded in.
public struct DiagnosticNote: Sendable, Equatable {
    public var event: DiagnosticEvent
    public var first: Date
    public var last: Date
    /// How many times in a row this same event was recorded. See
    /// `DiagnosticLog.record` for why this exists rather than five hundred
    /// identical lines.
    public var count: Int

    public init(event: DiagnosticEvent, first: Date, last: Date, count: Int = 1) {
        self.event = event
        self.first = first
        self.last = last
        self.count = count
    }
}


/// The ring buffer and the fold, with no global state in sight.
///
/// Split out from `DiagnosticLog` because the interesting behaviour here —
/// what gets dropped when it is full, what collapses into what — is worth
/// testing, and testing it through a process-wide `static var` means every
/// such test fights every other one for the same buffer. Swift Testing runs a
/// suite's tests in parallel by default, so that is not a theoretical race: it
/// is three tests interleaving their writes and two of them failing.
public struct DiagnosticBuffer: Sendable, Equatable {
    public private(set) var notes: [DiagnosticNote] = []
    public var capacity: Int

    public init(capacity: Int = DiagnosticLog.capacity) {
        self.capacity = max(1, capacity)
    }

    /// Appends, folding into the previous note when the event is identical.
    ///
    /// Folds only against the LAST note, not against any earlier match. Two
    /// interleaved events staying two lines is the point: the order things
    /// happened in is most of what a log is for, and a fold that reached
    /// backwards would quietly reorder it.
    public mutating func record(_ event: DiagnosticEvent, at instant: Date) {
        if var last = notes.last, last.event == event {
            last.last = instant
            last.count += 1
            notes[notes.count - 1] = last
            return
        }
        notes.append(DiagnosticNote(event: event, first: instant, last: instant))
        if notes.count > capacity {
            notes.removeFirst(notes.count - capacity)
        }
    }

    public mutating func removeAll() { notes.removeAll() }
    public var isEmpty: Bool { notes.isEmpty }
}

/// A small, bounded, copyable record of what the app has been doing.
///
/// Sized against how it is actually used: the user copies it out of Settings
/// and pastes it into a conversation, so its cost is paid in somebody's context
/// window. Two things keep that cost down, and both are here rather than left
/// to the call sites.
///
/// The first is the cap. `capacity` entries, oldest dropped, and `export`
/// additionally refuses to emit more than `exportByteLimit` — an app that
/// somehow starts logging in a loop produces a big log, not an unpasteable one.
///
/// The second is the fold. A run of identical events collapses to one line with
/// a count. The failure this is for is real and specific: a tool the model
/// calls wrongly gets called wrongly again on the retry, and a scheduled task
/// that cannot reach its data fails on the same schedule forever. Unfolded,
/// either drowns the fifty lines that explain it — which is the exact way a
/// bounded log loses the information it was kept for.
///
/// Static and lock-guarded rather than an actor because the call sites are
/// tool bodies, error paths and `deinit`-adjacent cleanup, none of which can
/// `await` and all of which would simply not log if they had to.
public enum DiagnosticLog {

    /// Entries retained. Two hundred lines at roughly sixty characters is about
    /// twelve kilobytes — a few thousand tokens, which is a reasonable thing to
    /// paste and a poor thing to lose a conversation to.
    public static let capacity = 200

    /// A hard stop on the exported text regardless of entry count.
    public static let exportByteLimit = 16_384

    private static let lock = NSLock()
    nonisolated(unsafe) private static var buffer = DiagnosticBuffer()

    /// Records an event, folding it into the previous one when identical.
    ///
    /// Synchronous and never throwing: a diagnostic that can fail, block or
    /// need an `await` is a diagnostic that gets left out of the paths worth
    /// diagnosing.
    public static func record(_ event: DiagnosticEvent, at instant: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        buffer.record(event, at: instant)
    }

    public static func snapshot() -> [DiagnosticNote] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.notes
    }

    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }

    public static var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.isEmpty
    }

    // MARK: - Export

    /// What the phone is, for the header.
    ///
    /// Passed in rather than read here because every one of these lives in
    /// UIKit or the app's bundle, and this package is built for macOS to run
    /// its tests. Nothing in it identifies a person: a build number, a hardware
    /// identifier shared by millions of phones, and an OS version.
    public struct Environment: Sendable, Equatable {
        public var appVersion: String
        public var build: String
        public var deviceModel: String
        public var systemVersion: String
        /// The resident model, if any. From the catalogue, so it is a slug.
        public var modelID: String?
        public var contextTokens: Int?

        public init(
            appVersion: String,
            build: String,
            deviceModel: String,
            systemVersion: String,
            modelID: String? = nil,
            contextTokens: Int? = nil
        ) {
            self.appVersion = appVersion
            self.build = build
            self.deviceModel = deviceModel
            self.systemVersion = systemVersion
            self.modelID = modelID
            self.contextTokens = contextTokens
        }
    }

    /// The whole log as one block of text, ready to paste.
    public static func export(
        environment: Environment,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        notes provided: [DiagnosticNote]? = nil
    ) -> String {
        let entries = provided ?? snapshot()
        var lines: [String] = [header(environment, now: now, timeZone: timeZone)]

        if entries.isEmpty {
            lines.append("")
            lines.append("(nothing recorded yet)")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        // Oldest first, which is the order somebody reads a log in when they
        // are looking for the thing that started it.
        for note in entries {
            lines.append(render(note, timeZone: timeZone))
        }

        var text = lines.joined(separator: "\n")
        if text.utf8.count > exportByteLimit {
            // Trim from the FRONT. The end is where the thing that just went
            // wrong is, and a log truncated the other way arrives having thrown
            // away the reason it was copied.
            text = trimmingFromFront(text, toBytes: exportByteLimit)
        }
        return text
    }

    static func header(_ environment: Environment, now: Date, timeZone: TimeZone) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "d MMM HH:mm"
        stamp.timeZone = timeZone
        stamp.locale = Locale(identifier: "en_US_POSIX")

        var parts = [
            "pocketd \(environment.appVersion) (\(environment.build))",
            environment.deviceModel,
            "iOS \(environment.systemVersion)",
            stamp.string(from: now)
        ]
        if let model = environment.modelID {
            let context = environment.contextTokens.map { " ctx \($0)" } ?? ""
            parts.append("model \(model)\(context)")
        } else {
            parts.append("no model loaded")
        }
        return parts.joined(separator: " · ")
    }

    static func render(_ note: DiagnosticNote, timeZone: TimeZone) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        clock.timeZone = timeZone
        clock.locale = Locale(identifier: "en_US_POSIX")

        var line = "\(clock.string(from: note.first))  \(describe(note.event))"
        if note.count > 1 {
            // The span, not just the count: five failures in a second is a
            // retry loop and five over an hour is a schedule.
            line += "  (x\(note.count) through \(clock.string(from: note.last)))"
        }
        return line
    }

    /// One event as one short line.
    ///
    /// Deliberately terse and machine-ish. Every value here comes from the
    /// closed vocabularies on `DiagnosticEvent`, an identifier the app minted,
    /// or a number — see that type's note on why there is nothing else.
    static func describe(_ event: DiagnosticEvent) -> String {
        switch event {
        case let .modelLoad(id, contextTokens, outcome, milliseconds):
            return "model.load \(id) ctx=\(contextTokens) \(outcome.rawValue) \(milliseconds)ms"
        case let .modelOffloaded(reason):
            return "model.offload \(reason.rawValue)"
        case let .toolGate(decision, modelID):
            return "tool.gate \(decision)\(modelID.map { " \($0)" } ?? "")"
        case let .toolPlan(admitted, dropped, tokens, ceiling, fit):
            let on = admitted.isEmpty ? "none" : admitted.joined(separator: ",")
            let off = dropped.isEmpty ? "" : " -\(dropped.joined(separator: ","))"
            return "tool.plan +\(on)\(off) \(tokens)/\(ceiling) \(fit)"
        case let .toolCall(name, outcome, milliseconds):
            return "tool.call \(name) \(outcome.rawValue) \(milliseconds)ms"
        case let .permission(entity, status):
            return "permission \(entity) \(status)"
        case let .generation(promptTokens, outputTokens, milliseconds, stop):
            return "gen p=\(promptTokens) o=\(outputTokens) \(milliseconds)ms \(stop.rawValue)"
        case let .scheduleRun(taskPrefix, outcome, milliseconds):
            return "schedule \(taskPrefix) \(outcome) \(milliseconds)ms"
        case let .serverStarted(port):
            return "server.start :\(port)"
        case .serverStopped:
            return "server.stop"
        case let .clientConnected(isOnDevice):
            return "client.connect \(isOnDevice ? "on-device" : "network")"
        case let .failure(area, code):
            return "FAIL \(area.rawValue) \(code)"
        case .memoryWarning:
            return "memory.warning"
        }
    }

    /// Drops whole leading lines until the text fits, then says so.
    static func trimmingFromFront(_ text: String, toBytes limit: Int) -> String {
        let marker = "(earlier entries trimmed)"
        var lines = text.components(separatedBy: "\n")
        // The header is line 0 and is worth more than any single entry, so it
        // is lifted out and never a candidate for trimming.
        let header = lines.isEmpty ? "" : lines.removeFirst()
        while !lines.isEmpty {
            let candidate = ([header, marker] + lines).joined(separator: "\n")
            if candidate.utf8.count <= limit { return candidate }
            lines.removeFirst()
        }
        return header
    }
}
