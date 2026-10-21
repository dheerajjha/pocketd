import Foundation
import Testing
@testable import PocketdKit

/// The five-screen intro's decisions.
///
/// The cases that matter most are the walkthrough's: Back to the brain screen
/// after the download had finished fetched 386 MB again, a replayed intro
/// recommended a fourth brain to a phone holding three, and the morning-brief
/// screen hid its own primer. Each phone state below is one somebody reaches
/// by tapping Back, replaying the intro from You, or upgrading from v1.
@Suite("Intro")
struct IntroTests {

    private let qwen = ModelCatalog.model(withID: "qwen3-1.7b")!
    private let qwen4 = ModelCatalog.model(withID: "qwen3-4b")!
    private let smol = ModelCatalog.model(withID: "smollm2-360m")!

    private func plan(
        chosen: BrainChoice? = nil,
        builtIn: BuiltInBrainAvailability = .available,
        installed: [ModelRecord] = [],
        arriving: [ModelRecord] = [],
        recommendation: ModelRecord?? = .none
    ) -> Intro.BrainPlan {
        Intro.BrainPlan.make(
            chosen: chosen,
            builtIn: builtIn,
            installed: installed,
            arriving: arriving,
            recommendation: recommendation ?? qwen
        )
    }

    // MARK: Screens

    @Test("Five screens, and the funnel keeps its order")
    func screensReportInOrder() {
        #expect(Intro.Screen.allCases.count == 5)
        let positions = Intro.Screen.allCases.map { screen in
            OnboardingStep.allCases.firstIndex(of: screen.analyticsStep)!
        }
        #expect(positions == positions.sorted())
        #expect(Set(positions).count == positions.count)
        #expect(Intro.Screen.meet.analyticsStep == .welcome)
        #expect(Intro.Screen.allSet.analyticsStep == .ready)
    }

    // MARK: First run

    @Test("Built-in ready: both options, built-in recommended and selected")
    func firstRunWithAppleIntelligence() {
        let plan = plan()
        #expect(plan.layout == .choice)
        #expect(plan.builtIn == .ready)
        #expect(plan.download == .offer(qwen))
        #expect(plan.inUse == nil)
        #expect(plan.recommended == .builtIn)
        #expect(plan.preselected == .builtIn)
        #expect(plan.action(for: .builtIn) == .useBuiltIn)
        #expect(plan.action(for: .download) == .download(qwen))
    }

    @Test("Apple still fetching its model: the download is recommended, built-in still offered")
    func builtInGettingReady() {
        let plan = plan(builtIn: .gettingReady)
        #expect(plan.layout == .choice)
        #expect(plan.builtIn == .gettingReady)
        #expect(plan.recommended == .download)
        #expect(plan.preselected == .download)
        #expect(plan.action(for: .builtIn) == .useBuiltIn)
    }

    @Test("No built-in option: the one recommended download, never a disabled row",
          arguments: [BuiltInBrainAvailability.turnedOff, .unsupportedLanguage, .notEligible])
    func downloadOnly(_ availability: BuiltInBrainAvailability) {
        let plan = plan(builtIn: availability)
        #expect(plan.layout == .downloadOnly)
        #expect(plan.builtIn == nil)
        #expect(plan.download == .offer(qwen))
        #expect(plan.preselected == .download)
        #expect(plan.recommended == .download)
        #expect(plan.action(for: .download) == .download(qwen))
        #expect(plan.action(for: .builtIn) == .nothing)
    }

    @Test("Nothing to offer: said once, Continue carries on")
    func nothingFits() {
        let plan = plan(builtIn: .notEligible, recommendation: .some(nil))
        #expect(plan.layout == .nothingFits)
        #expect(plan.preselected == nil)
        #expect(plan.action(for: plan.preselected) == .nothing)
    }

    @Test("Built-in available on a phone no download fits: one row, still a choice")
    func builtInOnly() {
        let plan = plan(recommendation: .some(nil))
        #expect(plan.layout == .choice)
        #expect(plan.download == nil)
        #expect(plan.preselected == .builtIn)
    }

    // MARK: Back, and never fetching twice

    @Test("Back after the download finished: Ready, and Continue fetches nothing")
    func backAfterDownloadFinished() {
        let plan = plan(chosen: .downloaded(id: qwen.id), builtIn: .notEligible, installed: [qwen])
        #expect(plan.download == .onPhone(qwen))
        #expect(plan.inUse == .download)
        #expect(plan.recommended == nil)
        #expect(plan.action(for: .download) == .nothing)
    }

    @Test("Back while it is still downloading: Continue does not start a second one")
    func backWhileArriving() {
        let plan = plan(chosen: .downloaded(id: qwen.id), arriving: [qwen])
        #expect(plan.download == .arriving(qwen))
        #expect(plan.inUse == .download)
        #expect(plan.preselected == .download)
        #expect(plan.action(for: .download) == .nothing)
        #expect(plan.action(for: .builtIn) == .useBuiltIn)
    }

    @Test("A chosen download that stopped is offered again, so Continue picks it up")
    func stoppedDownloadIsOfferedAgain() {
        let plan = plan(chosen: .downloaded(id: qwen.id), builtIn: .notEligible)
        #expect(plan.download == .offer(qwen))
        #expect(plan.inUse == nil)
        #expect(plan.action(for: .download) == .download(qwen))
    }

    @Test("The recommendation already here counts as here, whatever it can do")
    func recommendationAlreadyHere() {
        let plan = plan(builtIn: .notEligible, installed: [smol], recommendation: .some(smol))
        #expect(plan.download == .onPhone(smol))
        #expect(plan.action(for: .download) == .useDownloaded(id: smol.id))
    }

    // MARK: Replay

    @Test("Replay with the built-in brain in use: it says Ready and nothing changes")
    func replayWithBuiltIn() {
        let plan = plan(chosen: .builtIn)
        #expect(plan.inUse == .builtIn)
        #expect(plan.preselected == .builtIn)
        #expect(plan.recommended == nil)
        #expect(plan.action(for: .builtIn) == .nothing)
        #expect(plan.action(for: .download) == .download(qwen))
    }

    @Test("Replay with a bigger brain that reads your day: no second brain is offered")
    func replayWithAnotherReader() {
        let plan = plan(chosen: .downloaded(id: qwen4.id), installed: [qwen4])
        #expect(plan.download == .onPhone(qwen4))
        #expect(plan.inUse == .download)
        #expect(plan.action(for: .download) == .nothing)
    }

    @Test("A download on the phone beside the built-in brain in use is chosen, not fetched")
    func switchToInstalledDownload() {
        let plan = plan(chosen: .builtIn, installed: [qwen])
        #expect(plan.download == .onPhone(qwen))
        #expect(plan.inUse == .builtIn)
        #expect(plan.action(for: .download) == .useDownloaded(id: qwen.id))
    }

    @Test("A v1 phone with only a chat-only brain is offered the upgrade, never that brain")
    func chatOnlyBrainIsNotOffered() {
        let plan = plan(chosen: .downloaded(id: smol.id), installed: [smol])
        #expect(plan.download == .offer(qwen))
        #expect(plan.inUse == nil)
        #expect(plan.recommended == .builtIn)
    }

    @Test("A built-in choice on a phone that turned Apple Intelligence off falls to the download")
    func builtInChosenButOff() {
        let plan = plan(chosen: .builtIn, builtIn: .turnedOff)
        #expect(plan.layout == .downloadOnly)
        #expect(plan.inUse == nil)
        #expect(plan.action(for: .download) == .download(qwen))
    }

    // MARK: Sources

    @Test("Calendar and Reminders follow iOS's answer and the switch")
    func eventKitSources() {
        #expect(Intro.SourceStatus.of(.calendar, isOn: false, grant: .notAsked) == .notConnected)
        #expect(Intro.SourceStatus.of(.calendar, isOn: true, grant: .granted) == .connected)
        // Switched off in You with the grant standing: Connect again, no sheet.
        #expect(Intro.SourceStatus.of(.reminders, isOn: false, grant: .granted) == .notConnected)
        #expect(Intro.SourceStatus.of(.reminders, isOn: true, grant: .refused) == .offInSettings)
        #expect(Intro.SourceStatus.of(.calendar, isOn: false, grant: .refused) == .offInSettings)
        #expect(Intro.SourceStatus.of(.calendar, isOn: true, grant: .addOnly) == .notConnected)
        #expect(Intro.SourceStatus.of(.calendar, isOn: true, grant: .restricted) == .blocked)
        #expect(Intro.SourceStatus.of(.calendar, isOn: true, grant: .unavailable) == .unavailable)
    }

    @Test("Health that is on reads as connected, and a failed ask is one plain sentence")
    func healthSource() {
        #expect(Intro.SourceStatus.of(.health, isOn: false, grant: .neverReported) == .notConnected)
        #expect(Intro.SourceStatus.of(.health, isOn: true, grant: .neverReported) == .connected)

        let reason = HealthRequestFailure.other.reason
        let failed = Intro.SourceStatus.of(.health, isOn: true, grant: .failed(reason))
        #expect(failed == .couldNotAsk(reason: reason))
        #expect(failed.pillTitle == "Try again")
        #expect(failed.note(for: .health) == reason)
        #expect(failed.note(for: .health)?.localizedCaseInsensitiveContains("entitlement") == false)

        #expect(Intro.SourceStatus.of(.health, isOn: false, grant: .failed(reason)) == .notConnected)
        #expect(Intro.SourceStatus.of(.health, isOn: true, grant: .unavailable) == .unavailable)
    }

    @Test("Each status shows a pill or a word, never both")
    func pillOrWord() {
        let all: [Intro.SourceStatus] = [
            .notConnected, .connected, .offInSettings, .blocked, .unavailable, .couldNotAsk(reason: "x"), .asking,
        ]
        for status in all {
            #expect((status.pillTitle == nil) != (status.statusWord == nil))
        }
        #expect(Intro.SourceStatus.blocked.note(for: .calendar)?.hasPrefix("Calendar is blocked") == true)
        #expect(Intro.SourceStatus.connected.note(for: .calendar) == nil)
        // While iOS is being asked nothing claims a connection.
        #expect(Intro.SourceStatus.asking.statusWord == "Asking…")
        #expect(!Intro.SourceStatus.asking.isConnected)
    }

    @Test("Primers name the button on iOS's own sheet, in bold")
    func primers() {
        #expect(Intro.primer(for: .calendar) == "Next, tap **Allow Full Access**.")
        #expect(Intro.primer(for: .reminders) == "Next, tap **Allow**.")
        #expect(Intro.primer(for: .health)?.contains("**Turn On All**") == true)
        #expect(Intro.primer(for: .localServer) == nil)
    }

    @Test("One primer, under the row being connected or the next one to connect")
    func primerRow() {
        let fresh: [(Ability, Intro.SourceStatus)] = [
            (.calendar, .notConnected), (.reminders, .notConnected), (.health, .notConnected),
        ]
        #expect(Intro.primerRow(connecting: nil, statuses: fresh) == .calendar)
        #expect(Intro.primerRow(connecting: .health, statuses: fresh) == .health)

        let calendarDone: [(Ability, Intro.SourceStatus)] = [
            (.calendar, .connected), (.reminders, .offInSettings), (.health, .notConnected),
        ]
        #expect(Intro.primerRow(connecting: nil, statuses: calendarDone) == .health)

        // A failed Health ask is not primed again: iOS did not show a sheet.
        let settled: [(Ability, Intro.SourceStatus)] = [
            (.calendar, .connected), (.reminders, .connected), (.health, .couldNotAsk(reason: "x")),
        ]
        #expect(Intro.primerRow(connecting: nil, statuses: settled) == nil)
    }

    // MARK: All set

    @Test("The checklist is four lines, the brief with its time")
    func checklist() {
        let items = Intro.checklist(
            calendar: true, reminders: true, health: false,
            morningBrief: (time: "7:30 AM", weekdaysOnly: true)
        )
        #expect(items.map(\.title) == ["Calendar", "Reminders", "Health", "Morning brief"])
        #expect(items.map(\.isDone) == [true, true, false, true])
        #expect(items[3].detail == "7:30 AM, weekdays")

        let everyDay = Intro.checklist(
            calendar: false, reminders: false, health: false,
            morningBrief: (time: "6:45 AM", weekdaysOnly: false)
        )
        #expect(everyDay[3].detail == "6:45 AM, every day")

        let none = Intro.checklist(calendar: false, reminders: false, health: false, morningBrief: nil)
        #expect(none[3].isDone == false)
        #expect(none[3].detail == nil)
    }

    @Test("Readiness is one line, from the one status")
    func readiness() {
        #expect(Intro.Readiness.of(.ready, downloadStopped: false) == .ready)
        #expect(Intro.Readiness.of(.cannotReadYourDay, downloadStopped: false) == .ready)
        #expect(Intro.Readiness.of(.none(hasDownloaded: true), downloadStopped: false) == .ready)
        #expect(Intro.Readiness.of(.loading, downloadStopped: false) == .gettingReady(minutes: nil))
        #expect(Intro.Readiness.of(.arriving(fraction: 0.3, minutesLeft: 2), downloadStopped: false)
            == .gettingReady(minutes: 2))
        #expect(Intro.Readiness.of(.none(hasDownloaded: false), downloadStopped: true) == .stopped)
        #expect(Intro.Readiness.of(.none(hasDownloaded: false), downloadStopped: false) == .noBrain)
        #expect(Intro.Readiness.of(.failed(reason: "x"), downloadStopped: false) == .failed(reason: "x"))
        #expect(Intro.Readiness.of(.failed(reason: "x"), downloadStopped: true) == .stopped)
    }

    @Test("Readiness sentences")
    func readinessWords() {
        #expect(Intro.Readiness.ready.sentence == "Ready.")
        #expect(Intro.Readiness.gettingReady(minutes: 2).sentence == "Pocketd is getting ready — about 2 minutes.")
        #expect(Intro.Readiness.gettingReady(minutes: 1).sentence == "Pocketd is getting ready — about a minute.")
        #expect(Intro.Readiness.gettingReady(minutes: nil).sentence == "Pocketd is getting ready.")
        #expect(Intro.Readiness.stopped.actionTitle == "Try again")
        #expect(Intro.Readiness.ready.actionTitle == nil)
        #expect(!Intro.Readiness.gettingReady(minutes: 3).sentence.contains("answer the moment"))
    }

    // MARK: Words

    private var everyBlock: [String] {
        typealias C = Intro.Copy
        return [
            C.meetTitle, C.meetLine, C.usageCounts, C.getStarted,
            C.brainTitle, C.brainLine, C.recommended, C.downloadTitle, C.downloadWorksAnywhere,
            C.gettingBrainTitle, C.gettingBrainLine, C.hasBrainTitle, C.hasBrainLine, C.onPhoneDetail,
            C.downloadInBackground, C.mobileData(size: "1.1 GB"),
            C.nothingFitsTitle, C.nothingFitsLine, C.builtInGettingReady, C.ready,
            C.connectTitle, C.connectLine,
            C.morningTitle, C.morningLine, C.exampleLabel, C.exampleFallback, C.morningPrimer,
            C.setItUp, C.notNow,
            C.allSetTitle, C.allSetLine, C.nameQuestion, C.namePlaceholder, C.openPocketd,
        ]
        + C.promises.map(\.text)
        + [Ability.calendar, .reminders, .health].map(C.sourceDetail(for:))
        + [Ability.calendar, .reminders, .health].compactMap(Intro.primer(for:))
        + [Intro.Readiness.ready, .gettingReady(minutes: 4), .stopped, .noBrain].map(\.sentence)
    }

    @Test("Every block is at most about 25 words")
    func shortBlocks() {
        for block in everyBlock {
            let words = block.split(whereSeparator: { $0.isWhitespace }).count
            #expect(words <= 25, "\(words) words: \(block)")
        }
    }

    @Test("No machinery, no Skip, and Pocketd is never 'it'")
    func plainWords() {
        let banned = [
            "OpenAI", "ChatGPT", "GPT", "model", "LLM", "token", "GGUF", "Skip",
            "Let it", "Give it", "it will", "it can", "It can", "It will",
        ]
        for block in everyBlock {
            for word in banned {
                #expect(!block.contains(word), "\"\(word)\" in: \(block)")
            }
        }
    }
}
