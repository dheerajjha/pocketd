import PocketdKit
import SwiftUI

/// Ask: the assistant, and the only screen where the phone talks back.
///
/// The shape is three fixed things and one scrolling one. The header and the
/// brain chip say what is answering; the transcript scrolls; the notices and the
/// composer are pinned to the bottom so that neither an offer nor the box can be
/// scrolled away from.
///
/// Everything this screen can do to the user's own data goes through `AppModel`
/// — see `AppModel+Reminders`. Nothing here touches EventKit.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    @State private var isShowingHistory = false
    /// Writes still inside their undo window, pulled after every generation.
    @State private var writes: [PersonalDataWrite] = []
    @State private var silencedNotices: Set<String> = []

    var body: some View {
        VStack(spacing: PDSpacing.s) {
            AskHeader(
                onHistory: { isShowingHistory = true },
                onNew: { Task { await model.newConversation() } }
            )
            AskBrainChip(
                name: model.loadedModelID == nil ? nil : model.loadedModelName,
                isLoading: model.isLoadingModel,
                onChoose: { navigator.openYou(.brain) }
            )

            transcript

            AskNotices(silenced: $silencedNotices, forcedOffer: stagedOffer)
            AskComposer(followUp: followUp)
        }
        .padding(.top, PDSpacing.xs)
        .pdCanvas()
        .sheet(isPresented: $isShowingHistory) {
            ConversationHistoryView()
        }
        .task {
            #if DEBUG
            // A simulator cannot hold a model that calls tools, so the one
            // screen whose job is drawing tool results would have nothing to
            // draw. See `AskPreviewChat`.
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

    // MARK: - The conversation

    @ViewBuilder
    private var transcript: some View {
        if model.conversation.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                    if model.loadedModelID == nil { noBrainCard }
                    AskEmptyState(
                        onAsk: ask(_:),
                        onConnect: connect(_:),
                        isOn: { model.isOn($0) }
                    )
                }
                .padding(.bottom, PDSpacing.l)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        } else {
            AskTranscript(
                writes: writes,
                onCompleteReminder: completeReminder(_:),
                onUndo: undo(_:),
                onCopy: copy(_:),
                onFeedback: feedback(_:),
                forcedThinking: stagesPendingStates
            )
        }
    }

    /// The one dead end this screen can reach, with the way out on it.
    private var noBrainCard: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                SectionLabel("Nothing to answer with")
                Text(
                    model.installed.isEmpty
                        ? "Pocketd needs a brain before it can answer."
                        : "You have one downloaded — load it and it can answer."
                )
                .font(Font.pd.lead)
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
                PillButton(title: "Choose a brain", symbol: "brain", isOn: true) {
                    navigator.openYou(.brain)
                }
            }
        }
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.top, PDSpacing.s)
    }

    /// The two mid-generation states, staged rather than reached.
    ///
    /// Both need a resident model, and no model that can call a tool fits in a
    /// simulator — so on the machine every screenshot comes from they are not
    /// rare, they are unreachable. DEBUG only; in a Release build these are a
    /// constant `false` and a constant `nil`, and nothing can set them.
    private var stagesPendingStates: Bool {
        #if DEBUG
        AskPreviewChat.showsPendingStates
        #else
        false
        #endif
    }

    private var stagedOffer: ToolOffer? {
        stagesPendingStates ? ToolOffer(ability: .calendar) : nil
    }

    /// The chip above the composer, from what the last answer drew.
    private var followUp: AskSuggestion? {
        guard !model.isGenerating else { return nil }
        guard let last = model.conversation.last(where: { !$0.cards.isEmpty }) else { return nil }
        return AskSuggestion.followUp(after: last.cards)
    }

    // MARK: - Actions

    private func ask(_ suggestion: AskSuggestion) {
        model.draft = suggestion.text
        // `send()` no-ops without a resident model, which would leave somebody
        // staring at their own words with no reply and no explanation. The
        // question stays in the box instead, beside a card that says why.
        guard model.loadedModelID != nil else { return }
        model.send()
    }

    private func connect(_ ability: Ability) {
        model.enableAbility(ability)
        toasts?.show("\(ability.title) connected", symbol: "checkmark.circle", tint: .pd.positive)
    }

    private func completeReminder(_ title: String) {
        Task {
            let result = await model.completeReminder(named: title)
            guard !result.completed else {
                toasts?.show("Ticked off", symbol: "checkmark.circle", tint: .pd.positive)
                return
            }
            // The sentence rather than "failed": the interesting cases are an
            // ambiguous title and a permission that is off, and both are
            // answerable by the person reading them.
            toasts?.show(result.sentence, symbol: "exclamationmark.circle", tint: .pd.caution, seconds: 3.4)
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
            toasts?.show(WriteUndo.undoneSentence(for: write), symbol: "arrow.uturn.backward", tint: .pd.ink, seconds: 3)
        }
    }

    /// The cards too. The substance of an answer that ran a tool is drawn rather
    /// than written, so copying the prose alone hands back "here is your day"
    /// and none of the day.
    private func copy(_ message: ChatMessage) {
        UIPasteboard.general.string = ([message.content] + message.cards.map(\.transcript))
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
