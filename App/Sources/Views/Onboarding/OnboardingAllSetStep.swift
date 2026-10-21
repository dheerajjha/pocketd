import PocketdKit
import SwiftUI

/// Screen five: what is set up, a name if somebody wants to give one, and
/// whether Pocketd can answer yet — then Today.
///
/// The old last screen held a sample brief, a brain card, an ask-ahead box and
/// a promise — "I'll answer the moment the brain is ready" — printed directly
/// under a card saying the brain was ready; a question typed there landed the
/// person on Ask, not Today, under an invented agenda. All of that is gone.
/// What is left is a tally, one optional field and one line, and the button
/// goes to Today, where the brief and the real tiles are.
///
/// The name is the separate screen it used to be, folded in here: optional,
/// one field, and saved on the way out — writing it re-renders the brief, so
/// Today greets by it from its first frame.
struct OnboardingAllSetStep: View {
    @Environment(AppModel.self) private var model

    /// Held by the flow, so Back and forward keep what was typed.
    @Binding var name: String

    var onOpen: () -> Void

    @FocusState private var nameFocused: Bool

    var body: some View {
        OnboardingPage(
            ornament: .icon("checkmark"),
            headline: Intro.Copy.allSetTitle,
            primary: .init(Intro.Copy.openPocketd, run: onOpen)
        ) {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                readiness
                    .padding(.bottom, PDSpacing.xs)
                checklist
                nameField
            }
        }
        .animation(PDMotion.gentle, value: model.introReadiness)
    }

    // MARK: - The one line

    /// "Ready." or "Pocketd is getting ready — about 2 minutes." — and only
    /// for a download that stopped, one action.
    private var readiness: some View {
        let state = model.introReadiness
        return VStack(alignment: .leading, spacing: PDSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
                readinessGlyph(state)
                Text(state.sentence)
                    .font(Font.pd.body)
                    .foregroundStyle(state == .ready ? Color.pd.ink : Color.pd.inkSecondaryWarm)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if let title = state.actionTitle, let stopped = model.introStoppedDownload {
                TextLink(title, symbol: "arrow.clockwise") { model.download(stopped) }
                    .padding(.leading, PDSpacing.l)
            }
        }
    }

    @ViewBuilder
    private func readinessGlyph(_ state: Intro.Readiness) -> some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.positive)
        case .gettingReady:
            Image(systemName: "arrow.down.circle")
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.accentWarm)
        case .stopped, .failed:
            Image(systemName: "exclamationmark.circle")
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.caution)
        case .noBrain:
            Image(systemName: "info.circle")
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.accentWarm)
        }
    }

    // MARK: - The tally

    private var checklist: some View {
        PDCard(warm: true) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                ForEach(model.introChecklist) { item in
                    HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                        Image(systemName: item.isDone ? "checkmark" : "minus")
                            .font(Font.pd.secondary.weight(.semibold))
                            .foregroundStyle(item.isDone ? Color.pd.positive : Color.pd.inkTertiary)
                            .frame(minWidth: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(Font.pd.rowTitle)
                                .foregroundStyle(item.isDone ? Color.pd.ink : Color.pd.inkSecondaryWarm)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(Font.pd.secondary)
                                    .foregroundStyle(Color.pd.inkSecondaryWarm)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    // SF Symbols calls `minus` "Remove", which is not what a
                    // tally line is saying.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([item.title, item.detail, item.isDone ? "set up" : "not set up"]
                        .compactMap { $0 }
                        .joined(separator: ", "))
                }
            }
        }
    }

    // MARK: - The name

    private var nameField: some View {
        PDCard(warm: true) {
            VStack(alignment: .leading, spacing: PDSpacing.xs) {
                Text(Intro.Copy.nameQuestion)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(Intro.Copy.namePlaceholder, text: $name)
                    .font(Font.pd.statText.weight(.regular))
                    .foregroundStyle(Color.pd.ink)
                    .tint(Color.pd.accentWarm)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    .frame(minHeight: PDMetric.minHitTarget)
                    .accessibilityLabel(Intro.Copy.nameQuestion)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { nameFocused = true }
    }
}

#Preview("All set light") {
    OnboardingAllSetPreview()
}

#Preview("All set dark") {
    OnboardingAllSetPreview().preferredColorScheme(.dark)
}

#Preview("All set AX") {
    OnboardingAllSetPreview().dynamicTypeSize(.accessibility3)
}

private struct OnboardingAllSetPreview: View {
    @State private var name = ""

    var body: some View {
        OnboardingStepPreview {
            OnboardingAllSetStep(name: $name, onOpen: {})
        }
        .environment(AppModel())
    }
}
