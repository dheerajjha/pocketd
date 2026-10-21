import SwiftUI

/// The way out, under the way forward.
///
/// "Not now" and "Skip" are the most important words on a permission screen and
/// they are the ones an app is always tempted to hide. This is a real control:
/// full tap target, readable size, secondary ink rather than a grey that has
/// given up. It is quieter than the `PrimaryButton` above it and it is not
/// hiding.
struct SecondaryLink: View {
    let title: String
    var action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(Font.pd.body.weight(.medium))
                .foregroundStyle(Color.pd.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                // 44pt at least, which is the tap target Apple asks for and
                // which this control is usually the one to miss. A minimum,
                // so a larger text size grows it rather than clipping it.
                .pdHitTarget()
        }
        .buttonStyle(PDPressStyle())
    }
}

#Preview("Secondary link light") {
    SecondaryLinkPreview()
}

#Preview("Secondary link dark") {
    SecondaryLinkPreview().preferredColorScheme(.dark)
}

private struct SecondaryLinkPreview: View {
    var body: some View {
        VStack(spacing: PDSpacing.xs) {
            PrimaryButton(title: "Connect Calendar") {}
            SecondaryLink("Not now") {}
            SecondaryLink("See other options") {}
        }
        .padding(PDSpacing.heroGutter)
        .frame(maxHeight: .infinity)
        .pdCanvas()
    }
}
