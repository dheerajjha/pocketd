import Foundation
import PocketdKit
import SwiftUI

/// The conversation: sending and stopping, the notices beside it, and the
/// history it is saved into.
@MainActor
extension AppModel {

    // MARK: - Sending

    /// Whether the resident model can see, which is the only honest basis for
    /// offering the camera button.
    ///
    /// A vision model whose projector never downloaded loads and cannot see:
    /// `ModelStore` refuses to mark such a model installed for exactly that
    /// reason, so `declaredCapabilities` is trustworthy by the time a model is
    /// loadable at all.
    var loadedModelSeesImages: Bool {
        guard let id = loadedModelID else { return false }
        return catalog.first { $0.id == id }?.declaredCapabilities.vision.isYes ?? false
    }

    func attach(_ image: Data) {
        // Four is what the context can carry: each image is hundreds of tokens
        // of projector output before a word of the question is read.
        guard attachments.count < 4 else { return }
        attachments.append(image)
    }

    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    func send() {
        noteActivity()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A picture with no words is a question — "what is this" is implied —
        // so an empty draft is allowed once something is attached.
        guard !text.isEmpty || !attachments.isEmpty, !isGenerating else { return }
        // Nothing can answer yet. The question waits in the box, the notice
        // above it says so, and it goes the moment a brain can take it — this
        // used to return here without a word, which left somebody staring at
        // their own question with no reply and no reason.
        guard brainStatus.canAnswer else {
            if !text.isEmpty { askWhenReady(text) }
            return
        }
        // A brain that cannot read the day is not asked about it. Asked "what's
        // on today?" a chat-only brain answered "a visit from a local artisan",
        // and "remind me to call mom" got "Sure, I'll call the customer at 6pm"
        // with nothing filed. The question stays in the box and the notice
        // above it says why, with the way to a brain that can.
        if brainStatus == .cannotReadYourDay, let refusal = Self.dayRefusal(for: text) {
            dayRefusal = refusal
            return
        }
        dayRefusal = nil
        // A person typing outranks a task thinking on its own. The engine's
        // gate would serialise the two on its own, but the order it would pick
        // is the wrong one: this message would queue behind an unattended
        // briefing the user cannot see and did not start, and the Chat tab
        // would sit on an empty reply bubble for the length of it.
        //
        // Not awaited, and it does not need to be. An interrupted prompt run is
        // deliberately left unsettled — see `ScheduleRunner.runPrompt` — so
        // there is no record to lose by walking away from it, and the firing is
        // picked up again by the next sweep.
        //
        // After the guard, like the event below: a tap with an empty draft must
        // not cost somebody their morning briefing.
        scheduleSweep?.cancel()
        // Same precedence, for the same reason: the daily brief holds the
        // engine's gate exactly as this does, and a typed question queueing
        // behind a paragraph nobody asked for is a chat tab sitting on an empty
        // reply bubble. The template brief stays on the Today tab either way.
        cancelBriefGeneration()
        // After the guard rather than at the top of the method: a tap with an
        // empty draft, or with nothing resident to answer it, sends no message.
        analytics.record(.chatMessageSent(modelID: loadedModelID ?? ""))

        // Decided here, while `text` is still in hand and before `draft` is
        // cleared. Only when the model is actually being given tools: on a
        // model whose template cannot call one, turning an ability on would
        // change nothing and the offer would be a lie about what happens next.
        pendingToolOffer = personalDataToolGate.registersTools
            ? ToolOffer.decide(
                for: text,
                enabled: .init(
                    calendar: calendarToolsEnabled,
                    reminders: reminderToolsEnabled,
                    health: healthToolsEnabled
                )
            )
            : nil
        // A device with no Health store registers the tool and reads nothing,
        // so offering that switch would be offering something that cannot
        // work. HealthKit cannot tell "denied" from "no data", so the honest
        // move is to say nothing rather than guess which one it is.
        if pendingToolOffer?.ability == .health, healthAvailability != .available {
            pendingToolOffer = nil
        }
        if let offered = pendingToolOffer {
            analytics.record(.abilityOfferShown(ability: offered.ability.rawValue))
        }

        let images = attachments
        draft = ""
        attachments = []
        generationError = nil
        replyFailureRemedy = nil
        waitingQuestion = nil
        // Stamped for the reader's day separators, never sent to a brain: a
        // conversation picked up again the next morning says where "today"
        // starts in it.
        let now = Date()
        conversation.append(ChatMessage(role: .user, content: text, images: images, sentAt: now))
        conversation.append(ChatMessage(role: .assistant, content: "", sentAt: now))
        isGenerating = true
        // Both written weeks ago and never called. A generation is exactly the
        // case they exist for: the idle timer was driven only by the server, so
        // a phone answering a question in Chat locked its screen mid-reply, and
        // the lock backgrounds the app, and backgrounding unloads the model.
        UIApplication.shared.isIdleTimerDisabled = true
        suppressAutoRelease("generating")
        // Before a single token exists. Until now the only saves were after a
        // generation ended, so a force-quit or a memory kill during the 60-90
        // seconds a phone takes to answer lost the question as well as the
        // reply — and the app's own recovery from a hang is a force-quit.
        scheduleConversationSave()

        // What this reply is being written into, stamped before a single token
        // exists, because from here on every event arrives across an actor hop
        // that a tap on History can slip between. See `GenerationTarget`.
        let target = GenerationTarget(conversation: currentConversationID, slot: conversation.count - 1)
        // This reply's number. A reply that was stopped keeps running for a
        // moment — cancellation is cooperative — and its last tokens, or its
        // ending, must not land on the reply that replaced it.
        generationSerial += 1
        let serial = generationSerial
        inFlightTarget = target

        var messages: [ChatMessage] = []
        if !systemPrompt.isEmpty { messages.append(.system(systemPrompt)) }
        // "Stopped." is for the person; the model never sees it.
        //
        // No "/no_think" on the last turn any more. The engine turns thinking
        // off for every request from this phone and strips any `<think>` that
        // slips through; the reasoning switch in Server settings is for other
        // devices, and appending it here made that switch decide the phone's
        // own answers too.
        messages.append(contentsOf: ReplyMarker.modelHistory(Array(conversation.dropLast())))
        // Unconditional, unlike the tools, because it is nearly free and
        // because without it the assistant is wrong rather than merely
        // unhelpful: a model that does not know the date answers "what's on
        // tomorrow" from whenever its training data stopped, and says it with
        // the same confidence as everything else. See `DateContext` for why
        // this is a sentence and not a `get_current_datetime` tool.
        //
        // It does cost one thing, and it is worth naming: the string carries a
        // clock time, so it changes between turns, and LocalLLMClient's prompt
        // cache is a prefix match on the rendered text. Crossing a minute
        // boundary mid-conversation therefore re-prefills what was already
        // decoded. Prefill is the cheap half of a generation and the trade is
        // an obviously right one — an answer that is a second slower against an
        // answer that is wrong about what day it is.
        messages = DateContext.inject(into: messages)
        // What this brain was told, so the instructions it reads back can be
        // taken out of its answer — see the end of the reply below.
        let echo = PromptEcho(messages: messages)

        // The Chat tab is a human holding the phone, which is the one origin
        // allowed to reach personal data. Every other path — including the
        // /chat page this app serves, which is indistinguishable from curl at
        // the route layer — stays on the network default.
        let request = GenerationRequest(
            modelID: loadedModelID ?? "",
            messages: messages,
            options: GenerationOptions(maxTokens: configuration.maxContextTokens),
            origin: .onDeviceChat
        )

        // `phoneBrain`, not `engine`: the brain the user chose answers — Apple's
        // model or a download — while the server keeps the download.
        generationTask = Task { [phoneBrain] in
            do {
                // One review-worthy answer per generation. See the guard below.
                var notedUsefulAnswer = false
                for try await event in try await phoneBrain.generate(request) {
                    switch event {
                    case .token(let chunk):
                        await MainActor.run {
                            guard self.isWriting(serial) else { return }
                            // Compared before assigning: this runs per token,
                            // and writing nil over nil sixty times a second
                            // invalidates every view that reads it.
                            if self.activeToolName != nil { self.activeToolName = nil }
                            guard target.canWrite(to: self.currentConversationID, messages: self.conversation) else { return }
                            self.conversation[target.slot].content += chunk
                            // After the words, not before: what is on disk
                            // when the app is killed is what was on screen.
                            self.checkpointConversation()
                        }
                    case .answerCard(let card):
                        // The tool's own output, not the model's account of it.
                        // It arrives before the narration and is what the reader
                        // should believe if the two ever disagree.
                        await MainActor.run {
                            guard self.isWriting(serial),
                                  target.canWrite(to: self.currentConversationID, messages: self.conversation)
                            else { return }
                            self.conversation[target.slot].cards.append(card)
                            // Once per generation, and only for a card that
                            // reported something. A question that reads the
                            // calendar and the reminders is one useful answer
                            // rather than two, and a padlock or an empty day is
                            // not an answer at all — asking "enjoying the app?"
                            // straight after either is how an app earns a
                            // one-star.
                            guard !notedUsefulAnswer, card.reportsSomething else { return }
                            notedUsefulAnswer = true
                            self.noteToolBackedAnswer()
                        }
                    case .toolCallStarted(let name):
                        await MainActor.run {
                            guard self.isWriting(serial) else { return }
                            self.activeToolName = name
                        }
                    case .finished:
                        break
                    }
                }
            } catch {
                // A stop is not a failure: `stopGenerating` has already said so
                // on the reply itself.
                var stopped = Task.isCancelled || error is CancellationError
                if case InferenceError.cancelled = error { stopped = true }
                await MainActor.run {
                    // Kept OUT of the message. Appending it made the error
                    // part of the assistant's turn, and the next send
                    // replayed it as something the model had said — so it
                    // would then explain its own transport failure back to
                    // the user as though it were a reply.
                    guard !stopped, self.isWriting(serial),
                          self.currentConversationID == target.conversation else { return }
                    self.discardEmptyReply()
                    self.generationError = Self.replyFailureSentence(for: error)
                    self.replyFailureRemedy = Self.remedy(for: error)
                }
            }
            await MainActor.run {
                // A newer reply owns all of this now.
                guard self.generationSerial == serial else { return }
                // A small brain sometimes ends an answer with its own
                // instructions — "The user's locale is en_IN… You are a helpful
                // assistant." Taken out once the reply is complete, so the
                // reader keeps what was an answer; a reply that was nothing
                // but instructions is no reply, and says so.
                if target.canWrite(to: self.currentConversationID, messages: self.conversation) {
                    let reply = self.conversation[target.slot]
                    let cleaned = echo.clean(reply.content).text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned != reply.content.trimmingCharacters(in: .whitespacesAndNewlines) {
                        self.conversation[target.slot].content = cleaned
                        if cleaned.isEmpty, reply.cards.isEmpty {
                            self.discardEmptyReply()
                            self.generationError = "That one didn't work."
                            self.replyFailureRemedy = .tryAgain
                        }
                    }
                }
                self.inFlightTarget = nil
                self.isGenerating = false
                self.activeToolName = nil
                self.resumeAutoRelease("generating")
                self.applyIdleTimer(running: self.serverShouldRun)
                // The transcript this reply belongs to, or nothing at all.
                // Whatever is on screen instead was saved on the way out of
                // the one being left, and writing it again here is how a
                // conversation acquires the tail of another one's answer.
                if self.currentConversationID == target.conversation { self.scheduleConversationSave() }
            }
        }
    }

    /// Removes an assistant turn that never said anything.
    ///
    /// `send()` appends `.assistant("")` before a token exists so there is a
    /// slot to stream into. If the generation then fails or is stopped before
    /// the first token, nothing removed it: the transcript kept a permanent
    /// "…" bubble, the save wrote it to disk, and the next send replayed it to
    /// the model as a turn in which the assistant had said nothing — which a
    /// small model reads as an example of how to answer.
    ///
    /// Cards count as having said something: a tool can return a card and the
    /// narration fail afterwards, and the card is the part worth keeping.
    private func discardEmptyReply() {
        guard let last = conversation.indices.last,
              conversation[last].role == .assistant,
              conversation[last].content.isEmpty,
              conversation[last].cards.isEmpty
        else { return }
        conversation.remove(at: last)
    }

    /// Stops the reply being written, and says so on it.
    ///
    /// "Stopped." on the reply rather than nothing: a reply stopped before its
    /// first word used to vanish, which left the question standing alone with
    /// no answer and no reason. Partial words are kept above the marker.
    func stopGenerating() {
        // A stopped reply is still a reply: the partial text is on screen and
        // has to survive the same way a finished one does.
        defer { scheduleConversationSave() }
        resumeAutoRelease("generating")
        applyIdleTimer(running: serverShouldRun)
        if isGenerating, let target = inFlightTarget,
           target.canWrite(to: currentConversationID, messages: conversation) {
            conversation[target.slot].content = ReplyMarker.markingStopped(conversation[target.slot].content)
        }
        generationTask?.cancel()
        generationTask = nil
        inFlightTarget = nil
        isGenerating = false
        activeToolName = nil
    }

    /// Whether the reply numbered `serial` is still the one being written.
    private func isWriting(_ serial: Int) -> Bool {
        isGenerating && generationSerial == serial
    }

    /// One plain sentence for a reply that failed.
    ///
    /// The engine's own sentence when it has one written for people — the
    /// engine's failures are `InferenceError`, which carries plain sentences —
    /// and otherwise the spec's: something went wrong, and a new chat is the
    /// way on. Never an error's `description`, which is how "contextExhausted"
    /// and a file path reached the screen.
    static func replyFailureSentence(for error: any Error) -> String {
        // The built-in brain's failures carry a sentence written for this
        // screen — "Turn on Apple Intelligence in Settings to ask Pocketd." —
        // which `InferenceError.errorDescription` deliberately flattens to
        // "That one didn't work" for every other engine's log-style detail.
        if let sentence = SystemModelFailure.screenSentence(for: error) {
            return sentence
        }
        if error is InferenceError,
           let sentence = (error as? LocalizedError)?.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sentence.isEmpty {
            return sentence
        }
        return "That one didn't work."
    }

    /// What the reader can do about a reply that failed: the one action next
    /// to the sentence.
    ///
    /// Not always "Start a new chat". That is the way out of exactly one
    /// failure — a conversation that has outgrown what the brain can hold —
    /// and offered under "Pocketd is busy right now" it throws away a
    /// conversation that was fine.
    enum ReplyRemedy: Equatable {
        /// The conversation is too long to go on with.
        case startNewChat
        /// Ask the same question again: busy, timed out, or a one-off fault.
        case tryAgain
        /// Apple Intelligence is off, and only Settings turns it on.
        case openSettings
    }

    /// The remedy for an error, from its type — never from its words. `nil`
    /// where there is nothing to do but read the sentence: Pocketd declining,
    /// a language it does not speak yet, a picture it cannot see.
    static func remedy(for error: any Error) -> ReplyRemedy? {
        if let failure = error as? InferenceError, failure.suggestsNewConversation { return .startNewChat }
        if let sentence = SystemModelFailure.screenSentence(for: error) {
            switch sentence {
            case SystemModelFailure.turnedOff.sentence: return .openSettings
            case SystemModelFailure.guardrail.sentence,
                 SystemModelFailure.unsupportedLanguage.sentence,
                 SystemModelFailure.pictures.sentence: return nil
            default: return .tryAgain
            }
        }
        return .tryAgain
    }

    /// Asks the question whose answer failed, again.
    ///
    /// The failed turn goes first — the question and whatever half-answer it
    /// got — so the transcript shows the question once, with the answer that
    /// worked under it, rather than twice with a hole between.
    func retryLastQuestion() {
        guard !isGenerating, let index = conversation.lastIndex(where: { $0.role == .user }) else { return }
        let question = conversation[index]
        conversation.removeSubrange(index...)
        draft = question.content
        attachments = question.images
        send()
    }

    // MARK: - A question this brain cannot answer

    /// What a brain that cannot read the day says to a question about it.
    enum DayRefusal: Equatable {
        case readCalendar, readReminders, readHealth, addReminder, addEvent

        var sentence: String {
            switch self {
            case .readCalendar: "This brain can't read your calendar."
            case .readReminders: "This brain can't read your reminders."
            case .readHealth: "This brain can't read your sleep or steps."
            case .addReminder: "This brain can't add reminders."
            case .addEvent: "This brain can't add events."
            }
        }

        var symbol: String {
            switch self {
            case .readCalendar, .addEvent: "calendar"
            case .readReminders, .addReminder: "checklist"
            case .readHealth: "bed.double"
            }
        }
    }

    /// Whether `question` is about the day, and which part of it.
    ///
    /// Two detectors, the strict one first. `ToolOffer` hears "what's on
    /// today?", "remind me to…" and "how did I sleep?" and stays silent for
    /// "remind me of the time we met"; it misses the bare "Anything overdue?",
    /// which has no "my" in it. So the router's named capabilities count too —
    /// but only beside a word that makes it about the asker's own day, because
    /// on its own the router arms the calendar for "help me plan a party", and
    /// refusing that would be refusing a chat to a chat brain.
    static func dayRefusal(for question: String) -> DayRefusal? {
        let lower = question.lowercased()
        let group: CapabilityGroup?
        if let offer = ToolOffer.decide(for: question, enabled: .init(calendar: false, reminders: false, health: false)) {
            group = switch offer.ability {
            case .calendar: .calendar
            case .reminders: .reminders
            case .health: .health
            case .localServer: nil
            }
        } else if case let .named(groups) = CapabilityRouter.decide(question), isAboutTheDay(lower) {
            group = groups.first
        } else {
            group = nil
        }
        switch group {
        case .calendar?:
            return asksToAdd(lower, phrases: ["add ", "schedule ", "book ", "put ", "create "]) ? .addEvent : .readCalendar
        case .reminders?:
            return asksToAdd(lower, phrases: ["remind me to", "reminder to", "set a reminder", "add a reminder", "add "])
                ? .addReminder : .readReminders
        case .health?:
            return .readHealth
        default:
            return nil
        }
    }

    private static func isAboutTheDay(_ lower: String) -> Bool {
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        let markers: Set<String> = [
            "my", "today", "tonight", "tomorrow", "yesterday", "week", "weekend",
            "morning", "afternoon", "evening", "any", "anything", "overdue",
        ]
        return !words.isDisjoint(with: markers)
    }

    private static func asksToAdd(_ lower: String, phrases: [String]) -> Bool {
        phrases.contains { lower.hasPrefix($0) || lower.contains(" " + $0) }
    }

    // MARK: - A write taken back

    /// Rewrites the block that reported a write once it has been undone.
    ///
    /// The card is a record of what the tool did, and after Undo the tool's
    /// "Reminder set: “Call Mom”" is no longer true — leaving it there tells
    /// somebody scrolling back that a reminder exists when they removed it. The
    /// block now says what happened last, in `WriteUndo`'s words. The newest
    /// matching block, because the same title written twice is two blocks and
    /// the later write is the one with the Undo.
    func markWriteUndone(_ write: PersonalDataWrite) {
        let undone = WriteUndo.undoneSentence(for: write)
        for message in conversation.indices.reversed() {
            let match = conversation[message].cards.lastIndex { card in
                WriteUndo.offer(for: card, from: [write], now: write.madeAt) != nil
            }
            guard let card = match else { continue }
            conversation[message].cards[card].lede = undone
            conversation[message].cards[card].symbol = "arrow.uturn.backward"
            // The brain's own sentence about it goes too — "A reminder to call
            // mom has been added." over "Removed the reminder…" is the card
            // arguing with itself. Only where this write was the whole answer;
            // an answer that also drew something else keeps its words.
            if conversation[message].cards.count == 1, !ReplyMarker.isMarkedStopped(conversation[message].content) {
                conversation[message].content = undone
            }
            scheduleConversationSave()
            return
        }
    }

    // MARK: - Notices

    /// The one notice above the composer, or nothing. See `AskNotice` for the
    /// order and the words; a screen draws `sentence`, one button for
    /// `action`, and a way to put it away when `dismissal` allows.
    var askNotice: AskNotice? {
        AskNotice.decide(.init(
            brain: brainStatus,
            replyFailure: generationError,
            offer: pendingToolOffer,
            questionWaiting: waitingQuestion != nil,
            dismissed: dismissedNotices
        ))
    }

    /// Puts a notice away, for as long as it allows.
    func dismissAskNotice(_ notice: AskNotice) {
        switch notice.dismissal {
        case .never:
            return
        case .forNow:
            switch notice {
            case .replyFailed: generationError = nil
            case .offer: pendingToolOffer = nil
            case .gettingReady, .chooseBrain, .brainFailed, .cannotReadYourDay: break
            }
        case let .forever(key):
            dismissedNotices.insert(key)
        }
    }


    // MARK: - Questions that arrive before a brain can answer

    /// Holds a question until a brain can answer it, and gets one ready.
    ///
    /// Siri, a Shortcut, the Control Center button and the composer all end
    /// here when nothing can answer yet. The question stays in the box, the
    /// notice says it will be sent, and `sendWaitingQuestionIfReady` sends it
    /// the moment a brain is in — never left silently unsent, which is what a
    /// question asked while the brain was still downloading used to be.
    func askWhenReady(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        waitingQuestion = text
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = text }
        loadDownloadedBrainIfIdle()
    }

    /// A question handed over by Siri or a Shortcut, before or after the
    /// screen it belongs on exists.
    ///
    /// When a brain can answer, the Ask screen sends it as it always has.
    /// When none can, it is held here — the screen only ever put it in the box
    /// and left it there.
    func questionArrived(_ question: String) {
        guard !brainStatus.canAnswer else { return }
        askWhenReady(question)
    }

    /// Sends the waiting question once a brain can take it.
    ///
    /// Only if the box still holds it: somebody who has since typed something
    /// else has changed their mind, and sending the old question over their
    /// new words would be the app deciding for them.
    func sendWaitingQuestionIfReady() {
        guard let waiting = waitingQuestion, brainStatus.canAnswer, !isGenerating else { return }
        let inBox = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inBox == waiting || inBox.isEmpty else {
            waitingQuestion = nil
            return
        }
        draft = waiting
        send()
    }

    /// Asks from somewhere other than the conversation — Today, a detail
    /// page, a tile.
    ///
    /// Starts a new conversation unless the open one was used in the last
    /// half hour, so a question about sleep never lands at the bottom of an
    /// unrelated chat from yesterday.
    func askFresh(_ question: String, now: Date = Date()) async {
        if !conversation.isEmpty, now.timeIntervalSince(lastConversationActivity) > Self.freshConversationAfter {
            if isGenerating { stopGenerating() }
            await newConversation()
        }
        draft = question
        send()
    }

    /// How long a conversation stays the one a new question joins.
    static let freshConversationAfter: TimeInterval = 30 * 60

    /// When the open conversation was last added to.
    var lastConversationActivity: Date {
        history.first(where: { $0.id == currentConversationID })?.updatedAt ?? conversationStartedAt
    }

    // MARK: - History

    func loadHistory() async {
        history = await conversations.all()
    }

    /// What goes to disk.
    ///
    /// While a reply is being written, the copy on disk already says it
    /// stopped. If the app is killed mid-reply — by iOS, or by somebody's own
    /// force-quit — the conversation reopens with the words that arrived and
    /// "Stopped." under them, rather than half a sentence and no explanation.
    /// The finished reply's own save, a moment later, replaces it.
    private func snapshotConversation() -> Conversation {
        var messages = conversation
        if isGenerating, let target = inFlightTarget,
           target.canWrite(to: currentConversationID, messages: messages) {
            messages[target.slot].content = ReplyMarker.markingStopped(messages[target.slot].content)
        }
        let stored = history.first(where: { $0.id == currentConversationID })
        return Conversation(
            id: currentConversationID,
            title: stored?.title ?? "",
            createdAt: conversationStartedAt,
            // When it was last added to, not when it happened to be saved.
            // Every save stamped "now", and leaving a chat saves it — so a
            // conversation untouched for two hours read "4 minutes ago" in
            // History, and counted as fresh for `askFresh`.
            updatedAt: conversation.compactMap(\.sentAt).max() ?? stored?.updatedAt ?? Date(),
            modelID: loadedModelID,
            messages: messages,
            draft: draft
        )
    }

    /// Writes the transcript mid-generation, at most every few seconds.
    ///
    /// Deliberately not `scheduleConversationSave`: that is a debounce, so
    /// calling it per token restarts its timer per token and it never fires at
    /// all for the whole of a continuous stream — the exact case it would be
    /// called for. This is the other shape, a throttle with a floor, and the
    /// floor is what keeps a long reply from rewriting the file sixty times a
    /// second.
    func checkpointConversation() {
        guard Date().timeIntervalSince(lastCheckpoint) >= 3 else { return }
        lastCheckpoint = Date()
        let snapshot = snapshotConversation()
        Task { [conversations] in try? await conversations.save(snapshot) }
    }

    /// Persists the current transcript shortly after it stops changing.
    func scheduleConversationSave() {
        saveTask?.cancel()
        let snapshot = snapshotConversation()
        saveTask = Task { [conversations] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? await conversations.save(snapshot)
            let all = await conversations.all()
            await MainActor.run { self.history = all }
        }
    }

    /// Saves immediately, for the paths where there may be no later chance —
    /// backgrounding, or switching away from a conversation.
    func flushConversation() async {
        saveTask?.cancel()
        try? await conversations.save(snapshotConversation())
        history = await conversations.all()
    }

    func newConversation() async {
        await flushConversation()
        conversation.removeAll()
        draft = ""
        dayRefusal = nil
        // An offer belongs to the turn that prompted it; following the
        // user into another conversation would make it look like the app
        // had read something it has not.
        pendingToolOffer = nil
        generationError = nil
        modelSwitchNotice = nil
        waitingQuestion = nil
        currentConversationID = UUID()
        conversationStartedAt = Date()
    }

    func openConversation(_ id: UUID) async {
        guard id != currentConversationID else { return }
        await flushConversation()
        guard let found = history.first(where: { $0.id == id }) else { return }
        // Stopped for the same reason `loadModel` and `offloadModel` stop: the
        // transcript the reply is being written into is about to be replaced,
        // and a generation that outlived the swap has nowhere honest to put the
        // rest of its answer. Placed after the guard above so a conversation
        // that could not be opened costs nobody a reply, and before the swap so
        // the save it schedules still describes the transcript being left.
        let interrupted = isGenerating
        if interrupted { stopGenerating() }
        conversation = found.messages
        draft = found.draft
        currentConversationID = found.id
        conversationStartedAt = found.createdAt
        // Nothing to say here: the reply that was cut off says "Stopped." in
        // the conversation it belongs to, which is where anybody would look.
        generationError = nil
        modelSwitchNotice = nil
        waitingQuestion = nil
    }

    func deleteConversation(_ id: UUID) async {
        // Before the file goes, so the reply cannot be writing into a
        // transcript whose only copy is being deleted underneath it — and the
        // pending write goes with it, or the debounced save lands 600ms after
        // the delete and puts the whole conversation back.
        if id == currentConversationID {
            if isGenerating { stopGenerating() }
            saveTask?.cancel()
        }
        await conversations.delete(id)
        history = await conversations.all()
        // Deleting what you are looking at has to leave you somewhere, and an
        // emptied-but-still-current transcript would be saved straight back.
        if id == currentConversationID {
            conversation.removeAll()
            draft = ""
            // An offer belongs to the turn that prompted it; following the
            // user into another conversation would make it look like the app
            // had read something it has not.
            pendingToolOffer = nil
            currentConversationID = UUID()
            conversationStartedAt = Date()
        }
    }

    func renameConversation(_ id: UUID, to title: String) async {
        guard var found = history.first(where: { $0.id == id }) else { return }
        found.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await conversations.save(found)
        history = await conversations.all()
    }
}
