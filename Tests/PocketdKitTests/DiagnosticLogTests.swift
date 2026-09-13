import Foundation
import Testing
@testable import PocketdKit

/// The log is copied out of Settings and pasted into somebody else's chat
/// window, so these are not really tests about formatting.
@Suite("Diagnostic log")
struct DiagnosticLogTests {

    private func environment(model: String? = "qwen3-1.7b") -> DiagnosticLog.Environment {
        DiagnosticLog.Environment(
            appVersion: "1.0.0",
            build: "1789244768",
            deviceModel: "iPhone17,1",
            systemVersion: "26.5",
            modelID: model,
            contextTokens: model == nil ? nil : 4096
        )
    }

    private static let utc = TimeZone(identifier: "UTC")!
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_757_808_000 + seconds)
    }

    @Test("nothing the user wrote can reach the exported text")
    func personalContentNeverCrosses() {
        // The central invariant. This is not asserting that the call sites are
        // careful — it is asserting that the vocabulary has nowhere to put any
        // of this, which is a property of the type rather than of anyone's
        // discipline. Every case that exists is exercised below, populated as
        // richly as its own fields allow.
        let secrets = [
            "Oncology follow-up with Dr Achebe",
            "You have a biopsy result review at 14:00.",
            "Collect prescription from the pharmacy",
            "192.168.1.44",
            "/Users/someone/Library"
        ]
        let notes: [DiagnosticNote] = [
            .init(event: .modelLoad(id: "qwen3-1.7b", contextTokens: 4096, outcome: .ok, milliseconds: 3480), first: at(0), last: at(0)),
            .init(event: .modelOffloaded(reason: .background), first: at(1), last: at(1)),
            .init(event: .toolGate(decision: "declaredCapable", modelID: "qwen3-1.7b"), first: at(2), last: at(2)),
            .init(event: .toolPlan(admitted: ["reminders", "calendar"], dropped: ["get_health_summary"], tokens: 1109, ceiling: 1344, fit: "tight"), first: at(3), last: at(3)),
            .init(event: .toolCall(name: "reminders", outcome: .ok, milliseconds: 41), first: at(4), last: at(4)),
            .init(event: .permission(entity: "reminders", status: "granted"), first: at(5), last: at(5)),
            .init(event: .generation(promptTokens: 812, outputTokens: 96, milliseconds: 4210, stop: .completed), first: at(6), last: at(6)),
            .init(event: .scheduleRun(taskPrefix: "A1B2C3D4", outcome: "reported", milliseconds: 9100), first: at(7), last: at(7)),
            .init(event: .serverStarted(port: 8080), first: at(8), last: at(8)),
            .init(event: .serverStopped, first: at(9), last: at(9)),
            .init(event: .clientConnected(isOnDevice: false), first: at(10), last: at(10)),
            .init(event: .failure(area: .eventKit, code: "reminder_save_failed"), first: at(11), last: at(11)),
            .init(event: .memoryWarning, first: at(12), last: at(12))
        ]
        let text = DiagnosticLog.export(environment: environment(), now: at(13), timeZone: Self.utc, notes: notes)
        for secret in secrets {
            #expect(!text.contains(secret), "leaked: \(secret)")
        }
    }

    @Test("every case renders, so no case can be silently unreadable")
    func everyCaseRenders() {
        // A case added without a `describe` arm is a compile error, which is
        // the point of the switch being exhaustive. What this catches instead
        // is an arm that renders to nothing at all — a line of pure timestamp
        // in the middle of a log somebody is trying to read.
        let events: [DiagnosticEvent] = [
            .modelLoad(id: "m", contextTokens: 1, outcome: .failed, milliseconds: 0),
            .modelOffloaded(reason: .memoryPressure),
            .toolGate(decision: "tooSmall", modelID: nil),
            .toolPlan(admitted: [], dropped: [], tokens: 0, ceiling: 0, fit: "willNotFit"),
            .toolCall(name: "t", outcome: .badArguments, milliseconds: 0),
            .permission(entity: "calendar", status: "denied"),
            .generation(promptTokens: 0, outputTokens: 0, milliseconds: 0, stop: .contextExhausted),
            .scheduleRun(taskPrefix: "00000000", outcome: "trouble", milliseconds: 0),
            .serverStarted(port: 1),
            .serverStopped,
            .clientConnected(isOnDevice: true),
            .failure(area: .schedule, code: "x"),
            .memoryWarning
        ]
        for event in events {
            let rendered = DiagnosticLog.describe(event)
            #expect(!rendered.isEmpty, "\(event)")
            #expect(!rendered.contains("\n"), "one event is one line: \(event)")
        }
        // And no two render identically, which would make a log ambiguous.
        #expect(Set(events.map(DiagnosticLog.describe)).count == events.count)
    }

    @Test("a repeated event folds into one line with a span")
    func repeatsFold() {
        // The failure this is for: a tool called wrongly is called wrongly
        // again on the retry, and unfolded it buries the fifty lines that
        // explain why.
        var buffer = DiagnosticBuffer()
        for index in 0..<40 {
            buffer.record(.toolCall(name: "reminders", outcome: .badArguments, milliseconds: 2), at: at(TimeInterval(index)))
        }
        #expect(buffer.notes.count == 1)
        #expect(buffer.notes.first?.count == 40)
        let text = DiagnosticLog.export(environment: environment(), now: at(41), timeZone: Self.utc, notes: buffer.notes)
        #expect(text.contains("(x40 through"))
    }

    @Test("a different event breaks the fold, and the fold never reaches backwards")
    func foldStopsAtADifferentEvent() {
        // The order things happened in is most of what a log is for, so the
        // fold deliberately only looks at the previous note. The last
        // memory warning below stays its own line rather than joining the
        // first two across the server event that separates them.
        var buffer = DiagnosticBuffer()
        buffer.record(.memoryWarning, at: at(0))
        buffer.record(.memoryWarning, at: at(1))
        buffer.record(.serverStopped, at: at(2))
        buffer.record(.memoryWarning, at: at(3))
        #expect(buffer.notes.map(\.count) == [2, 1, 1])
    }

    @Test("the buffer is bounded and keeps the newest")
    func capacityHolds() {
        var buffer = DiagnosticBuffer(capacity: 20)
        // Distinct events, so the fold cannot do the bounding for it.
        for index in 0..<70 {
            buffer.record(.generation(promptTokens: index, outputTokens: 0, milliseconds: 0, stop: .completed), at: at(TimeInterval(index)))
        }
        #expect(buffer.notes.count == 20)
        // The oldest went, not the newest.
        #expect(buffer.notes.first?.event == .generation(promptTokens: 50, outputTokens: 0, milliseconds: 0, stop: .completed))
        #expect(buffer.notes.last?.event == .generation(promptTokens: 69, outputTokens: 0, milliseconds: 0, stop: .completed))
    }

    @Test("the process-wide log records through to a snapshot")
    func theGlobalIsWiredToTheBuffer() {
        // One test touches the global, because the convenience API is what
        // every call site actually uses and a wiring mistake between it and
        // the buffer would be invisible above. Kept to a single event so that
        // it cannot race a neighbour into a wrong count.
        DiagnosticLog.record(.failure(area: .storage, code: "wiring_probe"))
        #expect(DiagnosticLog.snapshot().contains { $0.event == .failure(area: .storage, code: "wiring_probe") })
    }

    @Test("an oversized export is trimmed from the front, never the end")
    func exportIsCappedFromTheFront() {
        // Which end gets cut is the whole decision. The reason somebody copied
        // the log is almost always the last thing in it.
        let notes = (0..<400).map { index in
            DiagnosticNote(
                event: .failure(area: .tools, code: "code_\(index)_padding_to_make_this_line_long_enough_to_matter"),
                first: at(TimeInterval(index)),
                last: at(TimeInterval(index))
            )
        }
        let text = DiagnosticLog.export(environment: environment(), now: at(500), timeZone: Self.utc, notes: notes)
        #expect(text.utf8.count <= DiagnosticLog.exportByteLimit)
        #expect(text.contains("code_399_"), "the newest entry must survive")
        #expect(!text.contains("code_0_"), "the oldest should have gone")
        #expect(text.contains("(earlier entries trimmed)"))
        // The header is worth more than any entry and is never a trim candidate.
        #expect(text.hasPrefix("pocketd 1.0.0"))
    }

    @Test("the header says what was running")
    func headerNamesTheBuildAndModel() {
        let text = DiagnosticLog.export(environment: environment(), now: at(0), timeZone: Self.utc, notes: [])
        #expect(text.contains("pocketd 1.0.0 (1789244768)"))
        #expect(text.contains("iPhone17,1"))
        #expect(text.contains("iOS 26.5"))
        #expect(text.contains("model qwen3-1.7b ctx 4096"))
    }

    @Test("no model loaded says so rather than leaving a gap")
    func headerWithoutAModel() {
        // A log that silently omits the model is one where the first question
        // back is "which model were you running".
        let text = DiagnosticLog.export(environment: environment(model: nil), now: at(0), timeZone: Self.utc, notes: [])
        #expect(text.contains("no model loaded"))
    }

    @Test("an empty log says it is empty")
    func emptyIsExplicit() {
        let text = DiagnosticLog.export(environment: environment(), now: at(0), timeZone: Self.utc, notes: [])
        #expect(text.contains("(nothing recorded yet)"))
    }
}
