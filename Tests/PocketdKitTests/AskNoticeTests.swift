import Foundation
import Testing
@testable import PocketdKit

/// One notice at a time, in a fixed order, each one sentence and one action.
@Suite("What the conversation says above the composer")
struct AskNoticeTests {

    private static let offer = ToolOffer(ability: .calendar)

    @Test("a failed reply outranks everything, and its way out is a new chat")
    func failureFirst() {
        let notice = AskNotice.decide(.init(
            brain: .cannotReadYourDay,
            replyFailure: "That one didn't work.",
            offer: Self.offer,
            questionWaiting: true
        ))
        #expect(notice == .replyFailed("That one didn't work."))
        #expect(notice?.action == .startNewChat)
        #expect(notice?.actionTitle == "Start a new chat")
        #expect(notice?.dismissal == .forNow)
    }

    @Test("an offer about this turn outranks the brain")
    func offerSecond() {
        let notice = AskNotice.decide(.init(brain: .cannotReadYourDay, offer: Self.offer))
        #expect(notice == .offer(Self.offer))
        #expect(notice?.action == .connect(.calendar))
        #expect(notice?.sentence == "Connect your calendar so Pocketd can answer that.")
    }

    @Test("no brain: getting ready while one is on its way, a choice when none is")
    func noBrain() {
        #expect(AskNotice.decide(.init(brain: .arriving(fraction: 0.4, minutesLeft: 2)))
            == .gettingReady(minutesLeft: 2, questionWaiting: false))
        #expect(AskNotice.decide(.init(brain: .loading)) == .gettingReady(minutesLeft: nil, questionWaiting: false))
        #expect(AskNotice.decide(.init(brain: .none(hasDownloaded: false))) == .chooseBrain(questionWaiting: false))
        #expect(AskNotice.decide(.init(brain: .failed(reason: "x"))) == .brainFailed(questionWaiting: false))
        #expect(AskNotice.gettingReady(minutesLeft: 2, questionWaiting: false).sentence
            == "Pocketd is getting ready — about 2 minutes.")
        #expect(AskNotice.gettingReady(minutesLeft: 1, questionWaiting: false).sentence
            == "Pocketd is getting ready — about 1 minute.")
        #expect(AskNotice.chooseBrain(questionWaiting: false).sentence == "Choose how Pocketd thinks to start asking.")
        #expect(AskNotice.chooseBrain(questionWaiting: false).action == .chooseBrain)
    }

    @Test("a waiting question is never left unexplained")
    func waitingQuestionsAreExplained() {
        let statuses: [BrainStatus] = [
            .none(hasDownloaded: false), .none(hasDownloaded: true), .arriving(fraction: nil, minutesLeft: nil),
            .loading, .failed(reason: "x"),
        ]
        for status in statuses {
            let notice = AskNotice.decide(.init(brain: status, questionWaiting: true))
            #expect(notice != nil, "a question waits on \(status) with nothing said")
            #expect(notice?.sentence.contains("question") == true, "\(status): \(notice?.sentence ?? "")")
        }
    }

    @Test("a brain on the phone that is not in memory needs no word until a question waits")
    func downloadedButNotLoaded() {
        #expect(AskNotice.decide(.init(brain: .none(hasDownloaded: true))) == nil)
        #expect(AskNotice.decide(.init(brain: .none(hasDownloaded: true), questionWaiting: true))
            == .gettingReady(minutesLeft: nil, questionWaiting: true))
    }

    @Test("the brain warning is said once and stays put away")
    func cannotReadYourDayOnce() {
        let notice = AskNotice.decide(.init(brain: .cannotReadYourDay))
        #expect(notice == .cannotReadYourDay)
        #expect(notice?.sentence == "This brain can't read your calendar.")
        #expect(notice?.actionTitle == "Switch")
        #expect(notice?.dismissal == .forever(key: AskNotice.cannotReadYourDayKey))
        #expect(AskNotice.decide(.init(brain: .cannotReadYourDay, dismissed: [AskNotice.cannotReadYourDayKey])) == nil)
    }

    @Test("a ready brain with nothing to report says nothing")
    func silence() {
        #expect(AskNotice.decide(.init(brain: .ready)) == nil)
        #expect(AskNotice.decide(.init(brain: .ready, dismissed: [AskNotice.cannotReadYourDayKey])) == nil)
    }

    @Test("every notice is one short plain sentence with no machinery in it")
    func copyRules() {
        let notices: [AskNotice] = [
            .replyFailed("That one didn't work."), .offer(Self.offer), .offer(ToolOffer(ability: .health)),
            .gettingReady(minutesLeft: 12, questionWaiting: true), .gettingReady(minutesLeft: nil, questionWaiting: false),
            .chooseBrain(questionWaiting: true), .chooseBrain(questionWaiting: false),
            .brainFailed(questionWaiting: true), .brainFailed(questionWaiting: false), .cannotReadYourDay,
        ]
        for notice in notices {
            let words = notice.sentence.split(separator: " ").count
            #expect(words <= 25, "\(words) words: \(notice.sentence)")
            #expect(notice.sentence.hasSuffix("."))
            for jargon in ["model", "token", "context", "registered", "GGUF", "smollm", "qwen", "load"] {
                #expect(!notice.sentence.localizedCaseInsensitiveContains(jargon), "\(notice.sentence)")
            }
            // One action at most, and a verb when there is one.
            if notice.action == .none { #expect(notice.actionTitle == nil) } else { #expect(notice.actionTitle != nil) }
        }
    }
}
