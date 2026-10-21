import Foundation
import Testing
@testable import PocketdKit

/// The one answer to "can Pocketd answer, and how well".
@Suite("Where the brain stands")
struct BrainStatusTests {

    private static let qwen = BrainStatus.Resident(choice: .downloaded(id: "qwen3-1.7b"), readsYourDay: true)
    private static let smol = BrainStatus.Resident(choice: .downloaded(id: "smollm2-360m"), readsYourDay: false)

    @Test("nothing on the phone and nothing coming is a choice to make")
    func nothingAtAll() {
        #expect(BrainStatus.derive(.init()) == .none(hasDownloaded: false))
        #expect(BrainStatus.derive(.init(hasDownloaded: true)) == .none(hasDownloaded: true))
    }

    @Test("a resident brain is ready, or ready without your day")
    func residentBrains() {
        #expect(BrainStatus.derive(.init(resident: Self.qwen, hasDownloaded: true)) == .ready)
        #expect(BrainStatus.derive(.init(resident: Self.smol, hasDownloaded: true)) == .cannotReadYourDay)
    }

    @Test("the built-in brain needs no case of its own")
    func builtInIsJustReady() {
        let apple = BrainStatus.Resident(choice: .builtIn, readsYourDay: true)
        #expect(BrainStatus.derive(.init(resident: apple)) == .ready)
    }

    @Test("a load in progress outranks the brain it is replacing")
    func loadingOutranksResident() {
        // Switching holds the engine until the new brain is in: a question sent
        // now waits either way, and "ready" would be the lie.
        #expect(BrainStatus.derive(.init(resident: Self.qwen, isLoading: true)) == .loading)
        #expect(BrainStatus.derive(.init(isLoading: true, arriving: .init(fraction: 0.5))) == .loading)
    }

    @Test("a download in the background does not stop the current brain answering")
    func residentOutranksArrival() {
        #expect(BrainStatus.derive(.init(resident: Self.smol, arriving: .init(fraction: 0.3))) == .cannotReadYourDay)
    }

    @Test("a download reports its share and whole minutes, never zero")
    func arrivalNumbers() {
        #expect(BrainStatus.derive(.init(arriving: .init())) == .arriving(fraction: nil, minutesLeft: nil))
        #expect(BrainStatus.derive(.init(arriving: .init(fraction: 0.34, secondsLeft: 95)))
            == .arriving(fraction: 0.34, minutesLeft: 2))
        #expect(BrainStatus.derive(.init(arriving: .init(fraction: 0.99, secondsLeft: 4)))
            == .arriving(fraction: 0.99, minutesLeft: 1))
        #expect(BrainStatus.derive(.init(arriving: .init(fraction: 1.4)))
            == .arriving(fraction: 1, minutesLeft: nil))
        // A rate that has not settled is not a promise.
        #expect(BrainStatus.minutes(for: .infinity) == nil)
        #expect(BrainStatus.minutes(for: 0) == nil)
        #expect(BrainStatus.minutes(for: 3 * 24 * 60 * 60) == nil)
    }

    @Test("a failed load is reported until something better is on its way")
    func failures() {
        let failed = BrainStatus.derive(.init(hasDownloaded: true, loadFailure: "It needs more memory than this iPhone has free."))
        #expect(failed == .failed(reason: "It needs more memory than this iPhone has free."))
        #expect(BrainStatus.derive(.init(arriving: .init(fraction: 0.1), loadFailure: "x")) == .arriving(fraction: 0.1, minutesLeft: nil))
        #expect(BrainStatus.derive(.init(resident: Self.qwen, loadFailure: "x")) == .ready)
    }

    @Test("only a resident brain can answer, and only one that reads the day writes the brief")
    func whatEachStatusAllows() {
        let all: [BrainStatus] = [
            .none(hasDownloaded: false), .none(hasDownloaded: true), .arriving(fraction: 0.5, minutesLeft: 2),
            .loading, .ready, .cannotReadYourDay, .failed(reason: "x"),
        ]
        for status in all {
            #expect(status.canAnswer == (status == .ready || status == .cannotReadYourDay), "\(status)")
            #expect(status.canWriteBrief == (status == .ready), "\(status)")
        }
        #expect(BrainStatus.loading.isGettingReady)
        #expect(BrainStatus.arriving(fraction: nil, minutesLeft: nil).isGettingReady)
        #expect(BrainStatus.ready.isGettingReady == false)
    }

    @Test("a brain that just arrived loads itself only where it is an improvement")
    func loadingWhatArrived() {
        #expect(BrainStatus.shouldLoadArrival(current: .none(hasDownloaded: false), arrivedReadsYourDay: false))
        #expect(BrainStatus.shouldLoadArrival(current: .failed(reason: "x"), arrivedReadsYourDay: true))
        #expect(BrainStatus.shouldLoadArrival(current: .cannotReadYourDay, arrivedReadsYourDay: true))
        // Never a sideways swap, and never a working brain pulled out from
        // under somebody.
        #expect(BrainStatus.shouldLoadArrival(current: .cannotReadYourDay, arrivedReadsYourDay: false) == false)
        #expect(BrainStatus.shouldLoadArrival(current: .ready, arrivedReadsYourDay: true) == false)
        #expect(BrainStatus.shouldLoadArrival(current: .loading, arrivedReadsYourDay: true) == false)
    }
}

@Suite("Why a brain would not load, in plain words")
struct BrainLoadFailureTests {
    @Test("every reason has one short sentence with no machinery in it")
    func everyReason() {
        for reason in LoadFailureReason.allCases {
            let sentence = BrainStatus.loadFailureSentence(for: reason)
            #expect(sentence.hasSuffix("."))
            #expect(sentence.split(separator: " ").count <= 12)
            for jargon in ["projector", "GGUF", "llama", "model", "file", "error"] {
                #expect(!sentence.localizedCaseInsensitiveContains(jargon), "\(sentence)")
            }
        }
    }
}
