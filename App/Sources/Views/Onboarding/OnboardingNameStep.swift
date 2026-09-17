import PocketdKit
import SwiftUI

/// Screen six: the only thing this app ever asks a person about themselves.
///
/// One string, and the smallness is the product. There is no account to attach
/// it to and nothing to sync it with — it exists so that the brief can open
/// "Good morning, Sam" instead of "Good morning,". The secondary line says
/// exactly that, because an assistant asking for a name with no explanation is
/// the shape of every sign-up form this app does not have.
///
/// A 24pt field rather than a 17pt one: it is the only control on the screen,
/// and at the size of a form row it reads as the first of five.
struct OnboardingNameStep: View {
    @Environment(AppModel.self) private var model

    var onContinue: () -> Void

    @State private var typed = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        OnboardingPage(
            ornament: .icon("person"),
            headline: "What should it call you?",
            secondary: "Only for the greeting. It stays on this phone.",
            primary: .init("Continue", isEnabled: !trimmed.isEmpty, run: save),
            escape: .init("Skip", run: onContinue)
        ) {
            PDCard(warm: true) {
                TextField("Your first name", text: $typed)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.pd.ink)
                    .tint(Color.pd.accentWarm)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { if !trimmed.isEmpty { save() } }
                    .accessibilityLabel("Your first name")
            }
        }
        .onAppear {
            // Whatever is already stored, so that a replay from Settings shows
            // the name rather than an empty box next to a greeting that uses it.
            typed = model.profile.name
            focused = true
        }
    }

    private func save() {
        model.profile.name = trimmed
        onContinue()
    }
}

#Preview("Name light") {
    OnboardingStepPreview {
        OnboardingNameStep(onContinue: {})
    }
    .environment(AppModel())
}

#Preview("Name dark") {
    OnboardingStepPreview {
        OnboardingNameStep(onContinue: {})
    }
    .environment(AppModel())
    .preferredColorScheme(.dark)
}
