import PocketdKit
import SwiftUI

/// The conversation: what was asked, what came back, and the box.
///
/// Two things, and only two: the transcript scrolling, and the bar pinned
/// under it — the composer with exactly one thing above it. That one thing is
/// the Stop pill while a reply is being written, else the notice the
/// conversation has to give (`AppModel.askNotice`), else one follow-up
/// question. No brain pill, no model name, no stack of warnings: the old tab
/// spent nearly half the screen on chrome and left the rest for the answer.
///
/// Everything this screen can do to the user's own data goes through `AppModel`
/// — see `AppModel+Reminders`. Nothing here touches EventKit.
///
/// The content of `ConversationSheet`, which owns the navigation bar (✕,
/// History, New chat) around it.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    /// Writes still inside their undo window, pulled after every generation.
    @State private var writes: [PersonalDataWrite] = []

    var body: some View {
        ConversationContent(
            writes: writes,
            forcedThinking: stagesPendingStates,
            onExample: ask(_:),
            onConnect: connect(_:),
            onCompleteReminder: completeReminder(_:),
            onUndo: undo(_:),
            onCopy: copy(_:),
            onFeedback: feedback(_:)
        )
        .pdBottomBar {
            AskComposer {
                AskBarAccessory(stagedNotice: stagedNotice)
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.top, PDSpacing.xs)
            .padding(.bottom, PDSpacing.xs)
        }
        .pdCanvas()
        .task {
            #if DEBUG
            // Every card shape on screen at once, without waiting on a brain
            // for each — see `AskPreviewChat`.
            await AskPreviewChat.seedIfRequested(into: model)
            #endif
            await refreshWrites()
        }
        // After a generation, because that is when a tool may have written
        // something. Not on a timer: the pills expire by themselves.
        .onChange(of: model.isGenerating) { _, generating in
            guard !generating else { return }
            Task { await refreshWrites() }
        }
    }

    /// The two mid-generation states, staged rather than reached.
    ///
    /// Both last a second or two under a real brain, which is too short to
    /// screenshot. DEBUG only; in a Release build these are a constant `false`
    /// and a constant `nil`, and nothing can set them.
    private var stagesPendingStates: Bool {
        #if DEBUG
        AskPreviewChat.showsPendingStates
        #else
        false
        #endif
    }

    private var stagedNotice: AskNotice? {
        stagesPendingStates ? .offer(ToolOffer(ability: .calendar)) : nil
    }

    // MARK: - Actions

    /// An example from the empty conversation: asked at once, or — for
    /// "Remind me to…" — started in the box with the cursor after it.
    private func ask(_ example: AskSuggestion) {
        if let stem = example.stem {
            // The same hand-off a "Remind me to…" chip on Today makes: in the
            // box, cursor after it. Not `askComposerFocusRequested`, which
            // opens the microphone where the phone can listen.
            navigator.ask(stem, send: false)
        } else {
            model.draft = example.text
            model.send()
        }
    }

    /// Through the one door. "Connected" only when iOS said yes.
    private func connect(_ ability: Ability) {
        Task {
            let outcome = await model.connect(ability, from: .chatOffer)
            if outcome.isConnected {
                toasts?.show("\(ability.title) connected", symbol: "checkmark.circle", tint: .pd.positive)
            } else if let sentence = outcome.sentence(for: ability) {
                toasts?.show(sentence, symbol: "exclamationmark.circle", tint: .pd.caution)
            }
        }
    }

    private func completeReminder(_ title: String) {
        Task {
            let result = await model.completeReminder(named: title)
            guard !result.completed else {
                // Today's Due tile is counting it until the day is read again,
                // and Today is under this sheet.
                model.dayMayHaveChanged()
                toasts?.show("Ticked off", symbol: "checkmark.circle", tint: .pd.positive)
                return
            }
            // The sentence rather than "failed": the interesting cases are an
            // ambiguous title and a permission that is off, and both are
            // answerable by the person reading them.
            toasts?.show(AnswerWords.curlingQuotes(result.sentence), symbol: "exclamationmark.circle", tint: .pd.caution)
        }
    }

    private func undo(_ write: PersonalDataWrite) {
        Task {
            let removed = await model.undoWrite(write)
            await refreshWrites()
            guard removed else {
                toasts?.show("That has already gone.", symbol: "exclamationmark.circle", tint: .pd.caution)
                return
            }
            Haptics.success()
            // The block that said "Reminder set" now says it was removed: the
            // transcript is a record, and that line is no longer true.
            model.markWriteUndone(write)
            model.dayMayHaveChanged()
            toasts?.show(
                AnswerWords.curlingQuotes(WriteUndo.undoneSentence(for: write)),
                symbol: "arrow.uturn.backward",
                tint: .pd.ink
            )
        }
    }

    /// The cards too. The substance of an answer that ran a tool is drawn rather
    /// than written, so copying the prose alone hands back "here is your day"
    /// and none of the day.
    private func copy(_ message: ChatMessage) {
        UIPasteboard.general.string = ([ReplyMarker.strippingStopped(message.content)] + message.cards.map(\.transcript))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        Haptics.tap()
        toasts?.show("Copied", symbol: "doc.on.doc")
    }

    private func feedback(_ positive: Bool) {
        model.record(.answerFeedback(positive: positive))
        Haptics.tap()
        toasts?.show("Thanks", symbol: positive ? "hand.thumbsup" : "hand.thumbsdown")
    }

    private func refreshWrites() async {
        writes = await model.recentWrites()
    }
}

// MARK: - The scrolling part

/// The transcript, or — before the first question — the empty conversation.
///
/// Its own view so that `model.conversation`, which changes on every token, is
/// read here and not by `AskView`: the screen's body, and the bar under it, do
/// not run again per word.
private struct ConversationContent: View {
    let writes: [PersonalDataWrite]
    let forcedThinking: Bool
    let onExample: (AskSuggestion) -> Void
    let onConnect: (Ability) -> Void
    let onCompleteReminder: (String) -> Void
    let onUndo: (PersonalDataWrite) -> Void
    let onCopy: (ChatMessage) -> Void
    let onFeedback: (Bool) -> Void

    @Environment(AppModel.self) private var model
    /// Read so the source row is re-judged on coming back from Settings,
    /// where a refusal may just have been turned into a yes.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if model.conversation.isEmpty && !forcedThinking {
            ScrollView {
                AskEmptyState(
                    readsYourDay: model.brainStatus != .cannotReadYourDay,
                    onExample: onExample,
                    onConnect: onConnect,
                    offSource: offSource
                )
                .padding(.bottom, PDSpacing.l)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .conversationScrollEdges()
        } else {
            AskTranscript(
                writes: writes,
                onCompleteReminder: onCompleteReminder,
                onUndo: onUndo,
                onCopy: onCopy,
                onFeedback: onFeedback,
                forcedThinking: forcedThinking
            )
        }
    }

    /// Calendar, then Reminders: the first that Pocketd cannot read yet.
    ///
    /// Off means the switch is off *or* iOS has not said yes — a switch left
    /// on over a refusal still reads nothing. Health is not offered here: it
    /// is optional, and a sheet about your day opens with your day.
    private var offSource: Ability? {
        // `standingGrant` asks EventKit directly, which SwiftUI cannot watch.
        // The door writes iOS's answer here when Connect gets one, so reading
        // it is what redraws this row the moment Calendar is allowed.
        _ = model.personalDataAuthorization
        _ = scenePhase
        return [Ability.calendar, .reminders].first { ability in
            !(model.isOn(ability) && model.standingGrant(for: ability) == .granted)
        }
    }
}

// MARK: - Above the bar

/// The one thing above the composer: Stop, a notice, or a follow-up question.
///
/// In that order. Stop while a reply is being written, because it is the only
/// control that matters then; the notice next, because it is something the
/// reader may need to act on; and only when there is nothing to say, the next
/// question — chosen from the last answer's own subject.
private struct AskBarAccessory: View {
    /// A notice to draw instead of the model's own. DEBUG launch argument only.
    let stagedNotice: AskNotice?

    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Group {
            if model.isGenerating {
                PillButton(title: "Stop", symbol: "stop.fill") {
                    Haptics.tap()
                    model.stopGenerating()
                }
                .accessibilityHint("Stops the answer being written")
            } else if let refusal = model.dayRefusal, model.brainStatus == .cannotReadYourDay {
                // The question just asked, answered honestly: this brain
                // cannot see what it was about. Shown even when the general
                // warning was put away — this one is about this question.
                //
                // No ✕. It goes by itself with the next question sent or a new
                // conversation, and the ✕'s column was what squeezed the
                // sentence onto two lines ("This brain can't read / your
                // reminders.") beside a card with room to spare.
                NoticeCard(
                    symbol: refusal.symbol,
                    tint: .pd.caution,
                    text: refusal.sentence,
                    linkTitle: "Switch",
                    action: { navigator.openYou(.brain) }
                )
            } else if let notice = stagedNotice ?? model.askNotice {
                AskNoticeView(notice: notice)
            } else if let followUp {
                SuggestionChip(followUp.text, symbol: followUp.symbol) {
                    model.draft = followUp.text
                    model.send()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .animation(PDMotion.gentle, value: model.isGenerating)
    }

    /// From the last answer only, and only one that drew something: what to
    /// ask next depends on what was just read.
    private var followUp: AskSuggestion? {
        guard let lastIndex = model.conversation.indices.last else { return nil }
        let last = model.conversation[lastIndex]
        guard last.role == .assistant, !last.cards.isEmpty,
              !ReplyMarker.isMarkedStopped(last.content) else { return nil }
        let question = model.conversation[..<lastIndex].last(where: { $0.role == .user })?.content
        return AskSuggestion.followUp(after: last.cards, lastQuestion: question)
    }
}
