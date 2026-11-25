import Testing
@testable import PocketdKit

@Suite("Microphone resources belong to an explicit dictation start")
struct DictationMicrophoneTests {
    private enum Failure: Error, CaseIterable { case activate, noInput, start }

    /// Factories correspond to AVAudioSession activation and AVAudioEngine's
    /// on-demand inputNode lookup. A release captures the exact installed tap.
    private final class Hardware {
        var events: [String] = []
        var failure: Failure?

        func owner() -> DictationMicrophone<Int> {
            DictationMicrophone(activate: {
                self.events.append("activate")
                if self.failure == .activate { throw Failure.activate }
                return { self.events.append("deactivate") }
            }, install: { tap in
                self.events.append("input \(tap)")
                if self.failure == .noInput { throw Failure.noInput }
                self.events.append("install \(tap)")
                return (startEngine: {
                    self.events.append("start \(tap)")
                    if self.failure == .start { throw Failure.start }
                }, removeTapAndStopEngine: { self.events.append("release \(tap)") })
            })
        }
    }

    @Test("Constructing, cancelling and discarding temporary idle owners never activates audio or looks up an input")
    func idle() {
        let hardware = Hardware()
        for _ in 0..<5 {
            var mic: DictationMicrophone<Int>? = hardware.owner()
            weak var discarded = mic
            mic?.stop()
            mic = nil
            #expect(discarded == nil)
        }
        #expect(hardware.events.isEmpty)
    }

    @Test("A failed start unwinds only acquired resources, even after a subsequent dismissal")
    func failedStart() {
        for failure in Failure.allCases {
            let hardware = Hardware()
            hardware.failure = failure
            var mic: DictationMicrophone<Int>? = hardware.owner()
            do { try mic?.start(tap: 7); Issue.record("failed stage succeeded: \(failure)") }
            catch { #expect(error as? Failure == failure) }
            mic?.stop()
            mic = nil
            let expected: [String] = switch failure {
            case .activate: ["activate"]
            case .noInput: ["activate", "input 7", "deactivate"]
            case .start: ["activate", "input 7", "install 7", "start 7", "release 7", "deactivate"]
            }
            #expect(hardware.events == expected)
        }
    }

    @Test("Interruption or destruction releases the installed graph once, with no new input lookup", arguments: [true, false])
    func cleanup(interrupted: Bool) throws {
        let hardware = Hardware()
        var mic: DictationMicrophone<Int>? = hardware.owner()
        try mic?.start(tap: 11)
        if interrupted { mic?.stop(); mic?.stop() }
        mic = nil
        #expect(hardware.events == ["activate", "input 11", "install 11", "start 11", "release 11", "deactivate"])
    }
}
