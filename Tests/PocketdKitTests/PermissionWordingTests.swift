import Foundation
import Testing
@testable import PocketdKit

/// App Review rejected Pocketd 1.1.3 under guideline 5.1.1(iv) on 24 Nov 2026:
/// a custom screen before the Calendar, Reminders and HealthKit requests had a
/// "Connect" button, and the lines above it named the sheet's own Allow
/// buttons. Whatever leads to an iOS permission sheet says Continue (or Next),
/// and no line says which answer to give.
@Suite("Permission wording (5.1.1(iv))")
struct PermissionWordingTests {
    @Test("the intro's row pill and morning button say Continue")
    func continueButtons() {
        #expect(Intro.SourceStatus.notConnected.pillTitle == "Continue")
        #expect(Intro.Copy.morningContinue == "Continue")
        #expect(AbilityAction.turnOn.label(for: .calendar) == "Continue")
        #expect(AskNotice.offer(ToolOffer(ability: .calendar)).actionTitle == "Continue")
    }

    @Test("no primer names a button on iOS's sheet")
    func neutralPrimers() {
        let lines = [Ability.calendar, .reminders, .health].compactMap { Intro.primer(for: $0) } + [Intro.Copy.morningPrimer]
        #expect(lines.count == 4)
        for line in lines {
            for word in ["Allow", "Turn On", "tap", "**"] {
                #expect(!line.contains(word), "\(line) contains \(word)")
            }
        }
    }

    /// Every code line in the app and the kit, comments skipped: none may
    /// bring back a word App Review rejected before a permission sheet.
    @Test("no source line steers people to grant access")
    func sourceScan() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketdKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
        // Phrases match in any letter case; button labels only as whole literals.
        let phrases = ["next, tap", "tap **allow", "turn on all", "turn on to see", "allow the prompt", "turn that on"]
        let labels = ["\"Connect\"", "\"Connect \\(", "\"Turn on\"", "\"Set it up\""]
        for folder in ["App/Sources", "Sources"] {
            var scanned = 0
            let base = root.appendingPathComponent(folder)
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    let lower = line.lowercased()
                    for phrase in phrases where lower.contains(phrase) {
                        Issue.record("\(url.lastPathComponent):\(index + 1) contains \(phrase)")
                    }
                    for label in labels where line.contains(label) {
                        Issue.record("\(url.lastPathComponent):\(index + 1) contains \(label)")
                    }
                }
            }
            // Each folder on its own, so a wrong path can't pass on the other.
            #expect(scanned > 100, "only \(scanned) Swift files under \(folder)")
        }
    }
}
