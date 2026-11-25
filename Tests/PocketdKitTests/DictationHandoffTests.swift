import Foundation
import Testing
@testable import PocketdKit

@Suite("Dictation only sends confirmed words from this press")
struct DictationHandoffTests {
    /// Keep the submitted text in the box, as Ask does when no brain is ready.
    /// Exactly-once delivery cannot rely on send() clearing the draft for us.
    private struct Composer {
        var handoff = DictationHandoff()
        var conversation = UUID()
        var draft = ""
        var sent: [String] = []
        var reviews: [String] = []
        var finalDrafts: [String] = []
        var hasAttachments = false
        var destination: DictationHandoff.Destination = .local(modelID: "fixture", selection: UUID())
        var endAudioCount = 0

        mutating func reserve() -> UUID {
            handoff.begin(draft: draft, in: conversation, destination: destination, hasAttachments: hasAttachments)
        }

        mutating func begin() -> UUID {
            let id = reserve()
            let opened = handoff.beginCapture(for: id, draft: draft, in: conversation)
            #expect(opened)
            return id
        }

        mutating func receive(_ event: DictationHandoff.Event, for id: UUID) {
            switch handoff.receive(event, for: id, draft: draft, in: conversation, destination: destination, hasAttachments: hasAttachments) {
            case .preview(let words): draft = words
            case .submit(let words): draft = words; sent.append(words)
            case .reviewFinal(let words): draft = words; finalDrafts.append(words)
            case .review(let message): reviews.append(message)
            case .endAudio: endAudioCount += 1
            case .cancel: handoff.cancel()
            case nil: break
            }
        }
    }

    @Test("A long hold released before permission cannot open the mic later")
    func releaseDuringAuthorization() throws {
        var press = DictationHandoff.Press()
        var handoff = DictationHandoff()
        let chat = UUID()
        var starts = 0
        for _ in 0..<3 {
            press.begin(at: 10) {
                starts += 1
                return .started(handoff.begin(draft: "", in: chat, destination: .review))
            }
        }
        #expect(starts == 1)
        let lifted = press.end(at: 10.6)
        let id = try #require(lifted)
        #expect(handoff.id == id)
        let action = handoff.receive(.release, for: id, draft: "", in: chat, destination: .review)
        #expect(action == .cancel) // Also retire the composer's pending permission task.
        #expect(handoff.id == nil)
        let opened = handoff.beginCapture(for: id, draft: "", in: chat)
        #expect(!opened)
        #expect(!press.isDown)
    }

    @Test("Release ends audio once; later provisional words never substitute for the delayed final")
    func delayedFinal() {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("remind me"), for: id)
        #expect(box.draft == "remind me")
        #expect(box.handoff.isHeld)
        box.receive(.release, for: id)
        box.receive(.release, for: id)
        box.receive(.partial("remind me at"), for: id)
        #expect(box.endAudioCount == 1)
        #expect(!box.handoff.isHeld)
        #expect(box.draft == "remind me at")
        #expect(box.sent.isEmpty)

        box.receive(.final("Remind me at four.\n"), for: id)
        box.receive(.final("Remind me at five."), for: id)
        box.receive(.partial("late partial"), for: id)
        box.receive(.timedOut, for: id)
        box.receive(.release, for: id)
        #expect(box.draft == "Remind me at four.")
        #expect(box.sent == ["Remind me at four."])
        #expect(box.reviews.isEmpty)
        #expect(box.handoff.id == nil)
    }

    @Test("A final before release, including after the audio cap, waits for the user's release")
    func earlyFinal() throws {
        var box = Composer()
        let id = box.begin()
        box.receive(.final("What's next?"), for: id)
        box.receive(.partial("what"), for: id)
        box.receive(.failed("Recognition has ended"), for: id)
        #expect(box.draft == "What's next?")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.isEmpty)
        #expect(box.handoff.isHeld)

        // A page may have opened the mic with no finger down. A tap adopts
        // that turn rather than starting over with an empty recording.
        var tap = DictationHandoff.Press()
        tap.begin(at: 10) { box.handoff.startOrJoin { Issue.record("a page mic already exists"); return nil } }
        let tapped = tap.end(at: 10.06)
        #expect(tapped == id)
        box.receive(.release, for: try #require(tapped))
        box.receive(.release, for: id)
        #expect(box.sent == ["What's next?"])
        #expect(box.endAudioCount == 0)
    }

    @Test("Timeout, error and an empty final keep the last heard words for editing",
          arguments: [DictationHandoff.Event.timedOut, .failed("Microphone disconnected"), .final(" \n ")])
    func unfinished(_ terminal: DictationHandoff.Event) {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("bring"), for: id)
        box.receive(.release, for: id)
        box.receive(.partial("bring bread"), for: id)
        box.receive(.partial(""), for: id)
        box.receive(terminal, for: id)
        box.receive(.final("obsolete"), for: id)
        #expect(box.draft == "bring bread")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.count == 1)
        #expect(box.handoff.id == nil)
    }

    @Test("Auto-stop without a final releases the draft even if the mic button is still held")
    func timeoutWhileHeld() {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("pick up"), for: id)
        box.receive(.timedOut, for: id)
        box.receive(.release, for: id)
        #expect(!box.handoff.isHeld)
        #expect(box.draft == "pick up")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.count == 1)
    }

    @Test("Old callbacks and an old release cannot finalize a newer press on an identical draft")
    func replacement() throws {
        var box = Composer()
        let old = box.begin()
        var oldPress = DictationHandoff.Press()
        oldPress.begin(at: 10) { .joined(old) }
        box.receive(.partial("buy"), for: old)
        box.receive(.release, for: old)
        let new = box.begin()
        box.receive(.partial("old partial"), for: old)
        box.receive(.final("old final"), for: old)
        box.receive(.timedOut, for: old)
        let lateLift = oldPress.end(at: 10.1)
        box.receive(.release, for: try #require(lateLift))
        #expect(box.draft == "buy")
        #expect(box.handoff.id == new)
        #expect(box.handoff.isHeld)
        #expect(box.reviews.isEmpty)
        box.receive(.release, for: new)
        box.receive(.final("Buy apples."), for: new)
        #expect(box.sent.isEmpty)
        #expect(box.finalDrafts == ["buy Buy apples."])
    }

    @Test("A changed draft wins even if a recognition callback beats the UI change notification",
          arguments: [DictationHandoff.Event.partial("old partial"), .final("old final"), .timedOut])
    func editsWin(_ late: DictationHandoff.Event) {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("ask"), for: id)
        box.receive(.release, for: id)
        box.draft = "my correction"
        box.receive(late, for: id)
        #expect(box.draft == "my correction")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.isEmpty)
        #expect(box.handoff.id == nil)
    }

    @Test("A view dismissal cancels a buffered final without erasing its words")
    func cancelledBeforeRelease() {
        var box = Composer()
        let id = box.begin()
        box.receive(.final("Heard words."), for: id)
        box.handoff.cancel()
        box.receive(.release, for: id)
        box.receive(.final("Late words."), for: id)
        #expect(box.draft == "Heard words.")
        #expect(box.sent.isEmpty)
    }

    @Test("Editing and undoing while waiting cannot revive the old automatic send")
    func editAndUndo() {
        var box = Composer()
        let id = box.begin()
        box.receive(.partial("Heard words"), for: id)
        box.receive(.release, for: id)
        box.handoff.cancel() // the text binding retires the turn on its first edit
        box.draft = "My correction"
        box.draft = "Heard words"
        box.receive(.final("Heard words and more."), for: id)
        #expect(box.draft == "Heard words")
        #expect(box.sent.isEmpty)
        #expect(box.reviews.isEmpty)
    }

    @Test("The same draft in another conversation does not belong to the microphone")
    func changedConversation() {
        var box = Composer()
        let id = box.begin()
        box.receive(.release, for: id)
        box.conversation = UUID()
        box.receive(.final("Other conversation's words"), for: id)
        #expect(box.draft.isEmpty)
        #expect(box.sent.isEmpty)
        #expect(box.handoff.id == nil)
    }

    @Test("A quick first tap survives both permission prompts; the second tap finishes exactly once")
    func quickTapPermissionAndFinish() throws {
        var box = Composer()
        var touch = DictationHandoff.Press()
        touch.begin(at: 1) { box.handoff.startOrJoin { box.reserve() } }
        let id = try #require(box.handoff.id)
        #expect(touch.end(at: 1.07) == nil)
        #expect(box.handoff.phase(isListening: false) == .starting)
        #expect(box.handoff.awaitsCapture(for: id, draft: box.draft, in: box.conversation))
        let opened = box.handoff.beginCapture(for: id, draft: box.draft, in: box.conversation)
        #expect(opened)
        let reopened = box.handoff.beginCapture(for: id, draft: box.draft, in: box.conversation)
        #expect(!reopened)
        #expect(box.handoff.phase(isListening: true) == .listening)
        box.receive(.partial("What is seven"), for: id)
        touch.begin(at: 4) { box.handoff.startOrJoin { Issue.record("second tap started another session"); return nil } }
        let secondLift = touch.end(at: 4.08)
        let finished = try #require(secondLift)
        box.receive(.release, for: finished)
        #expect(finished == id)
        #expect(box.handoff.phase(isListening: false) == .finishing)
        touch.begin(at: 4.1) { box.handoff.startOrJoin { Issue.record("restarted while waiting for final"); return nil } }
        #expect(touch.end(at: 4.17) == nil)
        #expect(box.endAudioCount == 1 && box.sent.isEmpty)
        box.receive(.final("What is seven plus five?"), for: id)
        box.receive(.final("Duplicate"), for: id)
        #expect(box.sent == ["What is seven plus five?"])
    }

    @Test("Holding a fresh mic finishes on lift; a cancelled contact never sends even an early final")
    func holdOrCancel() throws {
        for interrupted in [false, true] {
            var box = Composer()
            var touch = DictationHandoff.Press()
            touch.begin(at: 1) { box.handoff.startOrJoin { box.begin() } }
            let id = try #require(box.handoff.id)
            box.receive(.final("Fixture question"), for: id)
            #expect(box.handoff.phase(isListening: false) == .awaitingFinish)
            #expect(box.sent.isEmpty)
            if interrupted {
                #expect(touch.cancel() == id)
                box.handoff.cancel()
                #expect(touch.end(at: 2) == nil)
            } else {
                let release = touch.end(at: 2)
                let lifted = try #require(release)
                box.receive(.release, for: lifted)
            }
            box.receive(.release, for: id)
            #expect(box.sent == (interrupted ? [] : ["Fixture question"]))
            #expect(box.draft == "Fixture question")
        }
    }

    @Test("A finish tap cancels a page handoff that is still waiting to open the mic")
    func tapOnPendingPageHandoff() throws {
        var box = Composer()
        let page = box.reserve()
        var touch = DictationHandoff.Press()
        touch.begin(at: 1) { box.handoff.startOrJoin { Issue.record("replaced the page turn"); return nil } }
        let release = touch.end(at: 1.08)
        let lifted = try #require(release)
        box.receive(.release, for: lifted)
        #expect(!box.handoff.awaitsCapture(for: page, draft: box.draft, in: box.conversation))
        let lateOpen = box.handoff.beginCapture(for: page, draft: box.draft, in: box.conversation)
        #expect(!lateOpen && box.handoff.id == nil && box.sent.isEmpty)
    }

    @Test("Finishing sends one confirmed final to an unchanged, explicitly chosen and resident PCC brain",
          arguments: [false, true])
    func stableCloud(finalFirst: Bool) {
        let selection = UUID()
        let cloudID = ModelRecord.privateCloudComputeID
        var box = Composer()
        box.destination = .resolve(chosen: .privateCloudCompute, effective: .privateCloudCompute, residentID: cloudID,
                                   canAnswer: true, cloud: .available, selection: selection)
        #expect(box.destination == .explicitCloud(modelID: cloudID, selection: selection))
        let id = box.begin()
        box.receive(.partial("Seven plus"), for: id)
        if finalFirst { box.receive(.final("Seven plus five?"), for: id) }
        #expect(box.sent.isEmpty)
        // Approaching the quota still permits this same selected brain to answer.
        box.destination = .resolve(chosen: .privateCloudCompute, effective: .privateCloudCompute, residentID: cloudID,
                                   canAnswer: true, cloud: .approachingLimit, selection: selection)
        box.receive(.release, for: id)
        box.receive(.final("Seven plus five?"), for: id)
        box.receive(.release, for: id)
        box.receive(.final("Duplicate"), for: id)
        #expect(box.sent == ["Seven plus five?"] && box.finalDrafts.isEmpty)
        #expect(box.endAudioCount == (finalFirst ? 0 : 1))
    }

    @Test("A cloud ID alone, an unavailable cloud or a temporary fallback never authorizes sending")
    func destinationEvidence() {
        let token = UUID(), cloud = BrainChoice.privateCloudCompute, local = BrainChoice.downloaded(id: "fixture")
        func resolved(_ chosen: BrainChoice?, _ effective: BrainChoice?, _ resident: String?,
                      ready: Bool = true, status: AppleCloudStatus = .available) -> DictationHandoff.Destination {
            .resolve(chosen: chosen, effective: effective, residentID: resident,
                     canAnswer: ready, cloud: status, selection: token)
        }
        for invalid in [resolved(nil, cloud, cloud.modelID), resolved(local, cloud, cloud.modelID),
                        resolved(cloud, nil, cloud.modelID), resolved(cloud, local, local.modelID),
                        resolved(cloud, cloud, nil), resolved(cloud, cloud, local.modelID),
                        resolved(nil, .downloaded(id: cloud.modelID), cloud.modelID),
                        resolved(cloud, cloud, cloud.modelID, ready: false),
                        resolved(cloud, cloud, cloud.modelID, status: .unavailable),
                        resolved(cloud, cloud, cloud.modelID, status: .notReady),
                        resolved(cloud, cloud, cloud.modelID, status: .limitReached(reset: nil))] {
            #expect(invalid == .review)
        }
        #expect(resolved(local, local, local.modelID) == .local(modelID: local.modelID, selection: token))
        #expect(resolved(nil, .builtIn, BrainChoice.builtIn.modelID) == .local(modelID: BrainChoice.builtIn.modelID, selection: token))
        #expect(resolved(local, local, cloud.modelID) == .review)
    }

    @Test("Changed destinations and selecting the same brain again keep the final for an explicit Send")
    func reviewDestination() {
        let first = DictationHandoff.Destination.local(modelID: "A", selection: UUID())
        let changed = DictationHandoff.Destination.local(modelID: "B", selection: UUID())
        let back = DictationHandoff.Destination.local(modelID: "A", selection: UUID())
        let cloud = DictationHandoff.Destination.explicitCloud(modelID: ModelRecord.privateCloudComputeID, selection: UUID())
        let cloudAgain = DictationHandoff.Destination.explicitCloud(modelID: ModelRecord.privateCloudComputeID, selection: UUID())
        for (start, finish) in [(first, changed), (first, back), (first, cloud), (cloud, first), (cloud, cloudAgain),
                                (.review, .review), (first, .review), (.review, first), (cloud, .review), (.review, cloud)] {
            var box = Composer()
            box.destination = start
            let id = box.begin()
            box.receive(.partial("fixture"), for: id)
            box.receive(.release, for: id)
            box.destination = finish
            box.receive(.final("Fixture final"), for: id)
            box.receive(.release, for: id)
            box.receive(.final("Late"), for: id)
            #expect(box.sent.isEmpty && box.draft == "Fixture final")
            #expect(box.finalDrafts == ["Fixture final"])
        }
    }

    @Test("A destination lost before or at the finish gesture stays lost even if it recovers before the final",
          arguments: [false, true])
    func restoredBeforeFinal(changedAtRelease: Bool) {
        var box = Composer()
        let cloud = DictationHandoff.Destination.explicitCloud(modelID: ModelRecord.privateCloudComputeID, selection: UUID())
        box.destination = cloud
        let id = box.begin()
        box.receive(.partial("A question"), for: id)
        if changedAtRelease { box.destination = .review }
        else { box.handoff.observeDestination(.review) } // readiness changed between recognizer events
        box.receive(.release, for: id)
        box.destination = cloud
        box.receive(.final("A question?"), for: id)
        #expect(box.finalDrafts == ["A question?"] && box.sent.isEmpty)
    }

    @Test("One mic turn, two nonoverlapping audio requests: the iPhone blue-folder / green-notebook sequence")
    func witnessedSequence() throws {
        let blue = "The blue folder is near the window", green = "The green notebook is on the shelf"
        var box = Composer(), audio = DictationAudioRequests()
        let id = box.begin()
        // Synthetic 10 ms PCM envelopes matching the operator's clip times:
        // 4.27 s A, 4.64 s inter-clip gap + B's 3.20 s lead-in, then 3.93 s B.
        // This tests the production buffer router, not a recording of the phone.
        func write(_ frames: Int, level: Float) throws -> [Int] {
            try (0..<frames).map { _ in
                let write = audio.write(level: level, seconds: 0.01, spareReady: true)
                return try #require(write).part
            }
        }
        let a = try write(427, level: 0.6)
        #expect(Set(a) == [0])
        box.receive(.partial(blue), for: id)
        #expect(box.draft == blue)
        let quiet = try write(784, level: 0.02)
        #expect(Set(quiet) == [0, 1] && quiet == quiet.sorted())
        #expect(audio.state(at: 0).sealed && !audio.state(at: 1).ready)
        let b = try write(393, level: 0.55)
        #expect(Set(b) == [1] && audio.state(at: 1).ready)
        let old = audio.finish(at: 0)
        #expect(old?.hasNext == true)
        #expect(!audio.acceptsResult(from: 0) && audio.acceptsResult(from: 1))
        let obsolete = audio.finish(at: 0)
        #expect(obsolete == nil)
        // B's audio was already collected. Even entirely untimed callbacks
        // in each independent request cannot make the second replace the first.
        box.receive(.nextRequest(final: blue, timing: .init()), for: id)
        for hypothesis in ["The green", "The green note", "The green notebook", green, green] {
            box.receive(.partial(hypothesis), for: id)
            #expect(box.draft == blue + " " + hypothesis)
        }
        #expect(box.handoff.isHeld && box.sent.isEmpty)
        audio.close()
        #expect(audio.state(at: 1).sealed)
        let afterStop = audio.write(level: 1, seconds: 0.01, spareReady: true)
        #expect(afterStop == nil)
        box.receive(.release, for: id)
        let last = audio.finish(at: 1)
        #expect(last?.hasNext == false && !audio.acceptsResult(from: 1))
        box.receive(.final(green), for: id)
        box.receive(.final(green), for: id)
        #expect(box.sent == [blue + " " + green])
    }

    @Test("Overlapping audio corrects words; disjoint audio survives a suffix-only result; cumulative finals don't duplicate it")
    func timedHypotheses() {
        func at(_ start: Double, _ duration: Double) -> DictationTiming { .init(speechStart: start, speechDuration: duration) }
        for cumulative in [false, true] {
            var box = Composer()
            let id = box.begin()
            box.receive(.partial("blew", timing: at(0.2, 0.3)), for: id)
            box.receive(.partial("blue", timing: at(0.2, 0.32)), for: id)
            box.receive(.partial("blue folder", timing: at(0.2, 0.8)), for: id)
            box.receive(.partial("green", timing: at(2.0, 0.4)), for: id)
            box.receive(.partial("green", timing: at(2.0, 0.4)), for: id)
            #expect(box.draft == "blue folder green")
            box.receive(.release, for: id)
            if cumulative {
                box.receive(.final("Blue folder. Green.", timing: at(0.2, 2.3)), for: id)
                #expect(box.sent == ["Blue folder. Green."])
            } else {
                box.receive(.final("Green.", timing: at(2.0, 0.5)), for: id)
                #expect(box.finalDrafts == ["blue folder Green."] && box.sent.isEmpty)
            }
        }
    }

    @Test("An overlapping rolling window keeps only the earlier formatted words, including UTF-16 ranges")
    func rollingWindow() {
        var box = Composer()
        let id = box.begin()
        let first = DictationTiming(segments: [.init(start: 0.2, duration: 0.3, substringRange: NSRange(location: 0, length: 2)),
                                              .init(start: 0.7, duration: 0.3, substringRange: NSRange(location: 4, length: 6))])
        box.receive(.partial("🟦, folder", timing: first), for: id)
        box.receive(.partial("folder green", timing: .init(speechStart: 0.7, speechDuration: 1.4)), for: id)
        #expect(box.draft == "🟦, folder green")
    }

    @Test("Identical words spoken twice survive; duplicate revisions of either request do not")
    func repeatedSpeech() {
        var box = Composer()
        let id = box.begin()
        let timing = DictationTiming(speechStart: 0, speechDuration: 0.4)
        box.receive(.partial("again", timing: timing), for: id)
        box.receive(.nextRequest(final: "again", timing: timing), for: id)
        box.receive(.partial("again", timing: timing), for: id) // new request starts its clock at zero
        box.receive(.partial("again", timing: timing), for: id)
        box.receive(.release, for: id)
        box.receive(.final("again", timing: timing), for: id)
        #expect(box.sent == ["again again"])
    }

    @Test("Starting with typed words appends to that exact draft and waits for Send", arguments: ["My note:", "My note: ", "My note:\n"])
    func appendToDraft(_ prefix: String) {
        var box = Composer()
        box.draft = prefix
        let id = box.begin(), base = prefix + (prefix.last!.isWhitespace ? "" : " ")
        box.receive(.partial("blue"), for: id)
        box.receive(.partial("blue folder"), for: id)
        #expect(box.draft == base + "blue folder")
        box.receive(.release, for: id)
        box.receive(.final("Blue folder."), for: id)
        #expect(box.finalDrafts == [base + "Blue folder."] && box.sent.isEmpty)
    }

    @Test("Continue after a finished recognizer starts a new mic turn with the first phrase intact")
    func continueAfterFinal() {
        var box = Composer()
        let old = box.begin()
        box.receive(.final("Blue folder."), for: old)
        #expect(box.handoff.canContinue && box.sent.isEmpty)
        box.handoff.cancel() // explicit Continue; it does not deliver the old finish gesture
        let new = box.begin()
        box.receive(.release, for: old)
        box.receive(.partial("green"), for: new)
        box.receive(.release, for: new)
        box.receive(.final("Green notebook."), for: new)
        #expect(box.finalDrafts == ["Blue folder. Green notebook."] && box.sent.isEmpty)
    }

    @Test("Silence/timeout can't submit existing text, and a failed earlier phrase isn't promoted by a later final")
    func incompleteAppend() {
        var box = Composer()
        box.draft = "Keep this"
        let id = box.begin()
        box.receive(.release, for: id)
        box.receive(.final(""), for: id)
        #expect(box.draft == "Keep this" && box.sent.isEmpty)
        let next = box.begin()
        box.receive(.partial("blue"), for: next)
        box.receive(.timedOut, for: next)
        #expect(box.draft == "Keep this blue" && box.sent.isEmpty)
        var fresh = Composer()
        let turn = fresh.begin()
        fresh.receive(.partial("blue"), for: turn)
        fresh.receive(.nextRequest(final: nil, timing: .init()), for: turn)
        fresh.receive(.release, for: turn)
        fresh.receive(.final("green"), for: turn)
        #expect(fresh.finalDrafts == ["blue green"] && fresh.sent.isEmpty)
    }

    @Test("Only a silent trailing request can finish with the confirmed earlier words alone")
    func silentTail() {
        for hasPartial in [false, true] {
            var box = Composer()
            let id = box.begin()
            box.receive(.nextRequest(final: "Blue folder.", timing: .init()), for: id)
            if hasPartial { box.receive(.partial("green"), for: id) }
            box.receive(.release, for: id)
            box.receive(.emptyTail, for: id)
            #expect(box.sent == (hasPartial ? [] : ["Blue folder."]))
            #expect(box.draft == (hasPartial ? "Blue folder. green" : "Blue folder."))
        }
    }

    @Test("Deleting the draft during finalization wins; a pre-existing or newly staged photo is never auto-sent")
    func attachmentsAndDeletion() {
        for startsWithPhoto in [false, true] {
            var box = Composer()
            box.hasAttachments = startsWithPhoto
            let id = box.begin()
            box.receive(.partial("blue"), for: id)
            box.hasAttachments = true
            box.receive(.release, for: id)
            box.receive(.final("Blue"), for: id)
            #expect(box.sent.isEmpty && box.finalDrafts == ["Blue"])
        }
        var box = Composer()
        box.draft = "Prefix"
        let id = box.begin()
        box.receive(.partial("blue"), for: id)
        box.receive(.release, for: id)
        box.draft = ""
        box.receive(.final("late"), for: id)
        #expect(box.draft.isEmpty && box.sent.isEmpty && box.finalDrafts.isEmpty)
    }
}
