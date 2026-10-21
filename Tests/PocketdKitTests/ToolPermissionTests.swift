import Foundation
import Testing

/// The rule that no tool puts a permission sheet up in the middle of an answer.
///
/// Read off the app's own source, the way `HealthSummaryTests` checks the
/// HealthKit read set: the tools run in the app target, where a package test
/// cannot call them, and the failure being guarded against is a one-word
/// regression — somebody writing `await requestReadAccess(to:)` back into a
/// read because it "makes sure access is there". It does, by putting iOS's
/// modal over a stream that has stopped to wait for it.
@Suite("Tools never ask for permission")
struct ToolPermissionTests {

    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketdKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("App/Sources/Tools/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("no EventKit read or write asks; only the connect door does")
    func eventKitReadsNeverAsk() throws {
        let source = try Self.source("EventAccess.swift")
        // Defined once, called nowhere in the file.
        #expect(source.components(separatedBy: "func requestReadAccess(").count - 1 == 1)
        #expect(!source.contains("await requestReadAccess("))
        #expect(!source.contains("await self.requestReadAccess("))
        // The two prompting EventKit calls live inside that one function.
        let door = try #require(source.range(of: "func requestReadAccess("))
        let reads = try #require(source.range(of: "// MARK: - Reads"))
        for call in ["store.requestFullAccessToEvents()", "store.requestFullAccessToReminders()"] {
            let found = try #require(source.range(of: call))
            #expect(found.lowerBound > door.upperBound && found.lowerBound < reads.lowerBound, "\(call)")
        }
    }

    @Test("the tool bodies go through the shared functions, not around them")
    func toolStructsUseTheSharedBodies() throws {
        #expect(try Self.source("CalendarTools.swift").contains("ToolBodies.calendar("))
        #expect(try Self.source("ReminderTools.swift").contains("ToolBodies.reminders("))
        #expect(try Self.source("HealthTools.swift").contains("ToolBodies.health("))
        // And nothing in the tool layer reaches for a sheet.
        for file in ["ToolBodies.swift", "DayReader.swift", "CalendarTools.swift", "ReminderTools.swift", "HealthTools.swift"] {
            let text = try Self.source(file)
            #expect(!text.contains("requestReadAccess("), "\(file)")
            #expect(!text.contains("requestAllReadAccess("), "\(file)")
            #expect(!text.contains("requestAuthorization("), "\(file)")
        }
    }
}
