import SwiftUI

/// A quiet blue bubble with one useful sentence in it.
///
/// This replaces the full-width orange band v1 used for capability notices, and
/// the replacement is the point: a warning stripe across a screen makes an app
/// feel broken, and almost none of what this app has to say is a fault. A
/// primer — "Next, tap **Allow Full Access**." — is help, and it should look
/// like help.
///
/// It takes optional actions for the one case that genuinely needs them: the
/// in-chat tool offer, which asks a question and has to be answerable where it
/// is asked.
struct Callout<Actions: View>: View {
    var symbol: String = "lightbulb"
    let text: String
    var tint: Color = .pd.accent
    var fill: Color = .pd.callout
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            HStack(alignment: .top, spacing: PDSpacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(tint)
                    // Nudged onto the first line's baseline. Top-aligned
                    // without this, a symbol sits a couple of points above the
                    // cap height of the text beside it and reads as loose.
                    .padding(.top, 1)
                Text(text)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions
        }
        .padding(PDSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: PDRadius.callout, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension Callout where Actions == EmptyView {
    init(symbol: String = "lightbulb", text: String, tint: Color = .pd.accent, fill: Color = .pd.callout) {
        self.init(symbol: symbol, text: text, tint: tint, fill: fill) { EmptyView() }
    }
}

#Preview("Callout light") {
    CalloutPreview()
}

#Preview("Callout dark") {
    CalloutPreview().preferredColorScheme(.dark)
}

private struct CalloutPreview: View {
    var body: some View {
        VStack(spacing: PDSpacing.m) {
            Callout(text: "Next, tap Allow Full Access.")
            Callout(
                symbol: "calendar",
                text: "Let it see your calendar to answer that?"
            ) {
                HStack(spacing: PDSpacing.xs) {
                    PillButton(title: "Connect", symbol: "checkmark", isOn: true) {}
                    PillButton(title: "Not now", symbol: "xmark") {}
                }
            }
            Callout(
                symbol: "exclamationmark.triangle",
                text: "This phone is warm, so answers will be slower for a few minutes.",
                tint: .pd.caution,
                fill: .pd.cautionSoft
            )
        }
        .padding(PDSpacing.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .pdCanvas()
    }
}
