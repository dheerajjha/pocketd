import PocketdKit
import SwiftUI

/// The one thing the app has to say, above the composer.
///
/// v1 put each of these in a full-width orange band, and a warning stripe across
/// a screen makes an app feel broken — almost none of what this app has to say
/// is a fault. A model that swapped underneath you is a fact; a window too small
/// for a third tool is a fact; an offer to read your calendar is help. They get
/// the blue bubble that help gets, and only a transport failure gets the red
/// one.
///
/// One at a time, deliberately. A stack of callouts over the composer is the
/// same wall of chrome in a softer colour, and the reader can only act on one of
/// them anyway.
struct AskNotices: View {
    @Environment(AppModel.self) private var model

    /// Notices with no dismissal of their own, silenced for this screen's
    /// lifetime once read. `capabilityNotice` is derived from the loaded model
    /// and would otherwise come straight back.
    @Binding var silenced: Set<String>

    /// An offer to draw instead of the model's own. Only ever set by the DEBUG
    /// launch argument that stages the states a simulator cannot reach — see
    /// `AskPreviewChat.showsPendingStates`. `nil` everywhere else, including
    /// every Release build, where nothing can set it.
    var forcedOffer: ToolOffer?

    var body: some View {
        Group {
            if let offer = forcedOffer {
                toolOffer(offer)
            } else if let error = model.generationError {
                Callout(
                    symbol: "exclamationmark.triangle",
                    text: error,
                    tint: .pd.danger,
                    fill: .pd.dangerSoft
                ) {
                    dismiss("Dismiss") { model.dismissGenerationError() }
                }
            } else if let offer = model.pendingToolOffer {
                toolOffer(offer)
            } else if let notice = model.modelSwitchNotice {
                Callout(symbol: "arrow.triangle.2.circlepath", text: notice) {
                    dismiss("OK") { model.dismissModelSwitchNotice() }
                }
            } else if let notice = model.offloadNotice {
                Callout(symbol: "moon.zzz", text: notice) {
                    dismiss("OK") { model.dismissOffloadNotice() }
                }
            } else if BrainUpgrade.cannotReadYourDay(model), !silenced.contains(Self.toollessKey) {
                // Ahead of `capabilityWarning`, and instead of it. The Kit's
                // sentence for this case is Settings wording — "nothing is
                // registered and no context is spent on them. A 3B model or
                // larger can" — and it was the only warning on the one screen
                // where the consequence is visible: four suggestion chips that
                // this brain will answer out of thin air.
                BrainUpgradeCallout { silenced.insert(Self.toollessKey) }
            } else if let capability = capabilityWarning {
                Callout(symbol: "lightbulb", text: capability) {
                    dismiss("OK") { silenced.insert(capability) }
                }
            }
        }
        .padding(.horizontal, PDSpacing.gutter)
        .animation(PDMotion.gentle, value: model.generationError)
        .animation(PDMotion.gentle, value: model.pendingToolOffer)
    }

    /// The silencing key for the toolless-brain callout. A constant rather than
    /// the sentence, because the sentence carries the brain's name and swapping
    /// brains must bring the warning back.
    private static let toollessKey = "pd.notice.toolless"

    /// Only the ones the reader can do something about.
    ///
    /// `capabilityNotice` also describes switches that are working perfectly
    /// well, and a bubble over the composer saying so every time somebody opens
    /// Ask is chrome, not help.
    private var capabilityWarning: String? {
        guard let notice = model.capabilityNotice, notice.isWarning else { return nil }
        return silenced.contains(notice.summary) ? nil : notice.summary
    }

    /// The offer to turn on an ability the last question would have used.
    ///
    /// Deliberately not a message bubble and not an `AnswerCard`. The model did
    /// not say this — the app did — and a card would be written into the saved
    /// transcript, where it would still be offering months later beside an
    /// ability that has long since been switched on.
    ///
    /// Above the composer rather than inside the scroll view, so it cannot be
    /// scrolled away from and forgotten while somebody waits for a reply that
    /// was never going to contain the answer.
    private func toolOffer(_ offer: ToolOffer) -> some View {
        Callout(symbol: offer.ability.symbolName, text: offer.sentence) {
            HStack(spacing: PDSpacing.s) {
                PillButton(title: "Connect", symbol: "checkmark", isOn: true) {
                    model.acceptToolOffer()
                }
                Button("Not now") { model.dismissToolOffer() }
                    .font(Font.pd.secondary.weight(.medium))
                    .foregroundStyle(Color.pd.inkSecondary)
                    .buttonStyle(PDPressStyle())
                Spacer(minLength: 0)
            }
        }
    }

    private func dismiss(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button(title) {
                Haptics.tap()
                action()
            }
            .font(Font.pd.secondary.weight(.medium))
            .foregroundStyle(Color.pd.inkSecondary)
            .buttonStyle(PDPressStyle())
        }
    }
}

#Preview("Notices") {
    VStack(spacing: PDSpacing.s) {
        Callout(symbol: "calendar", text: "I can check your calendar — turn that on?") {
            HStack(spacing: PDSpacing.s) {
                PillButton(title: "Connect", symbol: "checkmark", isOn: true) {}
                Button("Not now") {}
                    .font(Font.pd.secondary.weight(.medium))
                    .foregroundStyle(Color.pd.inkSecondary)
                Spacer(minLength: 0)
            }
        }
        Callout(
            symbol: "exclamationmark.triangle",
            text: "The reply could not be completed.",
            tint: .pd.danger,
            fill: .pd.dangerSoft
        )
    }
    .padding(PDSpacing.gutter)
    .pdCanvas()
}

#Preview("Notices dark") {
    VStack(spacing: PDSpacing.s) {
        Callout(symbol: "calendar", text: "I can check your reminders — turn that on?") {
            HStack(spacing: PDSpacing.s) {
                PillButton(title: "Connect", symbol: "checkmark", isOn: true) {}
                Button("Not now") {}
                    .font(Font.pd.secondary.weight(.medium))
                    .foregroundStyle(Color.pd.inkSecondary)
                Spacer(minLength: 0)
            }
        }
    }
    .padding(PDSpacing.gutter)
    .pdCanvas()
    .preferredColorScheme(.dark)
}
