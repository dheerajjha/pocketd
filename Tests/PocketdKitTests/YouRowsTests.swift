import Foundation
import Testing
@testable import PocketdKit

/// The You page's rows: a source says On, Off or "Off in iOS Settings", and the
/// Brain row says which brain and whether it is ready — in words a person can
/// act on, with no machinery.
///
/// Written as tables, like `ConnectDoorTests`: a test that recomputes the
/// mapping it checks agrees with any mapping at all.
@Suite("You rows")
struct YouRowsTests {

    // MARK: - Sources

    @Test("A source that reads is On — Health included, which iOS never confirms")
    func readingIsOn() {
        #expect(SourceSwitch.of(.on) == .on)
        #expect(SourceSwitch.of(AbilityState.of(.health, enabled: true, grant: .neverReported)) == .on)
        // The brain in use not carrying the tool is the Brain row's sentence,
        // never "Needs attention" on the source.
        #expect(SourceSwitch.of(.onButWithheld("The brain in use cannot look things up.")) == .on)
        // A sheet that is up is the switch on its way to on.
        #expect(SourceSwitch.of(.pending) == .on)
    }

    @Test("A switch nothing reads through yet shows Off, so turning it on asks iOS")
    func unansweredIsOff() {
        let calendar = AbilityState.of(.calendar, enabled: true, grant: .notAsked)
        #expect(calendar == .onAwaitingGrant)
        #expect(SourceSwitch.of(calendar) == .off)
        let failedHealth = AbilityState.of(.health, enabled: true, grant: .failed("Pocketd couldn't ask iOS for Health."))
        #expect(SourceSwitch.of(failedHealth) == .off)
        #expect(SourceSwitch.of(.off) == .off)
        // Switched off with the permission still granted: off, and quiet.
        #expect(SourceSwitch.of(.offWithGrantStanding) == .off)
    }

    @Test("A refusal is Off in iOS Settings whichever way the switch is, and the row opens Settings")
    func refusedIsOffInSettings() {
        for enabled in [true, false] {
            for grant in [AbilityGrant.refused, .addOnly] {
                let row = SourceSwitch.of(AbilityState.of(.calendar, enabled: enabled, grant: grant))
                #expect(row == .offInSettings)
                #expect(row.statusText == "Off in iOS Settings")
                #expect(row.rowOpensSettings)
                #expect(!row.isSwitch)
            }
        }
    }

    @Test("Screen Time is blocked and opens nothing; a missing store says so")
    func blockedAndMissing() {
        let blocked = SourceSwitch.of(AbilityState.of(.reminders, enabled: true, grant: .restricted))
        #expect(blocked == .blocked)
        #expect(!blocked.rowOpensSettings)
        #expect(blocked.statusText == "Blocked on this iPhone")
        let missing = SourceSwitch.of(AbilityState.of(.health, enabled: true, grant: .unavailable))
        #expect(missing == .unavailable)
        #expect(missing.statusText == "Not on this iPhone")
    }

    @Test("Only On and Off are switches, and only they have no words of their own")
    func switchesHaveNoStatusText() {
        #expect(SourceSwitch.on.isSwitch && SourceSwitch.on.statusText == nil)
        #expect(SourceSwitch.off.isSwitch && SourceSwitch.off.statusText == nil)
    }

    @Test("Each source says what Pocketd does with it, in a few plain words")
    func sourceLines() {
        #expect(SourceSwitch.detail(for: .calendar) == "Reads and adds events")
        #expect(SourceSwitch.detail(for: .reminders) == "Reads, adds and ticks off reminders")
        #expect(SourceSwitch.detail(for: .health) == "Reads sleep and steps")
        for ability in [Ability.calendar, .reminders, .health] {
            let line = SourceSwitch.detail(for: ability)
            #expect(line.split(separator: " ").count <= 6)
            #expect(!Self.machinery.contains { line.lowercased().contains($0) })
        }
    }

    // MARK: - The Brain row

    @Test("Built into iPhone: the name, and Apple's model's own line")
    func builtInRow() {
        let ready = BrainRowSummary.make(status: .ready, usingBuiltIn: true, builtInAvailability: .available, downloadName: nil)
        #expect(ready == BrainRowSummary(title: "Built into iPhone", detail: "Ready"))
        let arriving = BrainRowSummary.make(
            status: .arriving(fraction: nil, minutesLeft: nil),
            usingBuiltIn: true, builtInAvailability: .gettingReady, downloadName: nil
        )
        #expect(arriving.detail == "Getting ready")
        let off = BrainRowSummary.make(
            status: .failed(reason: "Turn on Apple Intelligence in Settings to ask Pocketd."),
            usingBuiltIn: true, builtInAvailability: .turnedOff, downloadName: nil
        )
        #expect(off.detail == "Turn on Apple Intelligence")
    }

    @Test("A download: its name, then Ready, Getting ready · N%, or the way out")
    func downloadRow() {
        func row(_ status: BrainStatus, waiting: Bool = true) -> BrainRowSummary {
            BrainRowSummary.make(
                status: status, usingBuiltIn: false, builtInAvailability: .notEligible,
                downloadName: "Qwen3 1.7B", waitingReadsYourDay: waiting
            )
        }
        #expect(row(.ready) == BrainRowSummary(title: "Qwen3 1.7B", detail: "Ready"))
        #expect(row(.loading).detail == "Getting ready")
        #expect(row(.arriving(fraction: 0.349, minutesLeft: 2)).detail == "Getting ready · 34%")
        #expect(row(.arriving(fraction: nil, minutesLeft: nil)).detail == "Getting ready")
        // Out-of-range fractions are clamped, never "103%".
        #expect(row(.arriving(fraction: 1.03, minutesLeft: nil)).detail == "Getting ready · 100%")
        #expect(row(.cannotReadYourDay).detail == "Can't read your day — switch?")
        #expect(row(.failed(reason: "It couldn't start on this iPhone.")).detail == "It couldn't start on this iPhone.")
        // On disk, not in memory: it loads itself, so it is ready — unless it
        // is a brain that cannot read the day.
        #expect(row(.none(hasDownloaded: true)).detail == "Ready")
        #expect(row(.none(hasDownloaded: true), waiting: false).detail == "Can't read your day — switch?")
    }

    @Test("No brain at all: the row asks for the choice")
    func noBrainRow() {
        let row = BrainRowSummary.make(
            status: .none(hasDownloaded: false), usingBuiltIn: false,
            builtInAvailability: .notEligible, downloadName: nil
        )
        #expect(row == BrainRowSummary(title: "Not set up", detail: "Choose how Pocketd thinks"))
    }

    @Test("The row never shows machinery")
    func brainRowHasNoMachinery() {
        let statuses: [BrainStatus] = [
            .ready, .loading, .cannotReadYourDay, .none(hasDownloaded: true), .none(hasDownloaded: false),
            .arriving(fraction: 0.5, minutesLeft: 3), .arriving(fraction: nil, minutesLeft: nil),
        ]
        for status in statuses {
            for builtIn in [true, false] {
                for availability in BuiltInBrainAvailability.allCases {
                    let row = BrainRowSummary.make(
                        status: status, usingBuiltIn: builtIn,
                        builtInAvailability: availability, downloadName: nil
                    )
                    let words = "\(row.title) \(row.detail)".lowercased()
                    #expect(!Self.machinery.contains { words.contains($0) }, "\(row)")
                    #expect(!words.contains("openai") && !words.contains("gpt"))
                }
            }
        }
    }

    /// Words the consumer screens may not use (ideal-ui §1.6, §8).
    static let machinery = ["model", "gguf", "token", "context", "load", "weights", "registered", "enable", "grant"]
}
