import PocketdKit
import SwiftUI

/// The one thing the conversation has to say, above the composer.
///
/// Exactly one, and which one is not decided here. `AppModel.askNotice` makes
/// the choice in one place (`AskNotice.decide`), so this view is a `switch`
/// that draws a sentence and one action. It used to be a seven-branch `if` over
/// five optionals, a brain-upgrade check and a Settings warning, with its
/// silencing held in view state that came back on every visit; a stack of amber
/// callouts over the composer is the wall of chrome this replaces.
///
/// Above the composer rather than in the scroll view, so a notice cannot be
/// scrolled away from and forgotten while somebody waits for a reply that was
/// never going to contain the answer.
struct AskNoticeView: View {
    let notice: AskNotice

    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    var body: some View {
        NoticeCard(
            symbol: symbol,
            tint: tint,
            text: notice.sentence,
            linkTitle: link?.title,
            linkSymbol: link?.symbol ?? "arrow.right",
            action: linkAction,
            onDismiss: dismissAction
        )
    }

    /// The one action, as words and a glyph.
    ///
    /// A failed reply gets the remedy for *its* failure (`ReplyRemedy`):
    /// "Start a new chat" only when the conversation is what broke, "Try
    /// again" when the brain was busy or slow, Settings when Apple
    /// Intelligence is off, and nothing when Pocketd simply will not answer.
    private var link: (title: String, symbol: String)? {
        if case .replyFailed = notice {
            switch model.replyFailureRemedy {
            case .startNewChat?: return ("Start a new chat", "arrow.right")
            case .tryAgain?: return ("Try again", "arrow.clockwise")
            case .openSettings?: return ("Open Settings", "arrow.up.right")
            case nil: return nil
            }
        }
        return notice.actionTitle.map { ($0, "arrow.right") }
    }

    private var linkAction: (() -> Void)? {
        guard link != nil else { return nil }
        return { act() }
    }

    /// A ✕ only where the notice can be put away; the waiting and choosing
    /// ones go when what they describe changes.
    private var dismissAction: (() -> Void)? {
        if case .never = notice.dismissal { return nil }
        let notice = notice
        let model = model
        return { model.dismissAskNotice(notice) }
    }

    private var symbol: String {
        switch notice {
        case .replyFailed: "exclamationmark.bubble"
        case let .offer(offer): offer.ability.symbolName
        case .gettingReady: "hourglass"
        case .chooseBrain: "sparkles"
        case .brainFailed: "exclamationmark.triangle"
        case .cannotReadYourDay: "calendar.badge.exclamationmark"
        }
    }

    /// Amber only for a problem the reader may want to fix. Waiting for a
    /// brain, or an offer to connect a source, is not a fault.
    private var tint: Color {
        switch notice {
        case .replyFailed, .brainFailed, .cannotReadYourDay: .pd.caution
        case .offer, .gettingReady, .chooseBrain: .pd.ink
        }
    }

    private func act() {
        if case .replyFailed = notice {
            switch model.replyFailureRemedy {
            case .startNewChat?: Task { await model.newConversation() }
            case .tryAgain?: model.retryLastQuestion()
            case .openSettings?:
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            case nil: break
            }
            return
        }
        switch notice.action {
        case .startNewChat:
            Task { await model.newConversation() }
        case let .connect(ability):
            connect(ability)
        case .chooseBrain:
            // Closes the sheet on the way: Brain is a page under You, and a
            // push underneath a sheet happens where nobody can see it. The
            // conversation, and any question waiting in it, is here again the
            // next time it is opened.
            navigator.openYou(.brain)
        case .none:
            break
        }
    }

    /// Through the one door, and then the question that needed it again.
    ///
    /// The offer is about the question just asked, so once the source is on
    /// the useful thing is that question's answer — not a toast telling the
    /// reader to type it a second time.
    private func connect(_ ability: Ability) {
        let question = model.conversation.last(where: { $0.role == .user })?.content
        model.dismissAskNotice(notice)
        model.record(.abilityOfferAccepted(ability: ability.rawValue))
        Task {
            let outcome = await model.connect(ability, from: .chatOffer)
            if outcome.isConnected {
                toasts?.show("\(ability.title) connected", symbol: "checkmark.circle", tint: .pd.positive)
                if let question, !question.isEmpty, !model.isGenerating {
                    model.draft = question
                    model.send()
                }
            } else if let sentence = outcome.sentence(for: ability) {
                toasts?.show(sentence, symbol: "exclamationmark.circle", tint: .pd.caution)
            }
        }
    }
}

#Preview("Notices") {
    ScrollView {
        VStack(spacing: PDSpacing.s) {
            NoticeCard(
                symbol: "calendar",
                text: AskNotice.offer(ToolOffer(ability: .calendar)).sentence,
                linkTitle: "Connect",
                action: {},
                onDismiss: {}
            )
            NoticeCard(
                symbol: "hourglass",
                text: AskNotice.gettingReady(minutesLeft: 2, questionWaiting: true).sentence
            )
            NoticeCard(
                symbol: "exclamationmark.bubble",
                tint: .pd.caution,
                text: "This conversation got too long. Start a new chat to keep going.",
                linkTitle: "Start a new chat",
                action: {},
                onDismiss: {}
            )
            NoticeCard(
                symbol: "calendar.badge.exclamationmark",
                tint: .pd.caution,
                text: AskNotice.cannotReadYourDay.sentence,
                linkTitle: "Switch",
                action: {},
                onDismiss: {}
            )
        }
        .padding(PDSpacing.gutter)
    }
    .pdCanvas()
}
