import SwiftUI

/// The one button on a screen that matters.
///
/// Inverted against the canvas rather than tinted, which is what lets a page
/// have exactly one of these and be understood without anybody learning a
/// colour. A second `PrimaryButton` on a screen is a design bug, not a feature
/// of this component.
///
/// Full width and 54pt tall because it is usually pinned to the bottom of a
/// page and a thumb should not have to aim. At the accessibility text sizes
/// the label may take two lines and the button grows to hold them; 54 is the
/// floor, not the height.
struct PrimaryButton: View {
    let title: String
    /// The trailing `arrow.right`. On by default: this button almost always
    /// moves you forward, and the arrow is what says so before the label is
    /// read.
    var arrow: Bool = true
    var isLoading: Bool = false
    /// Off when the action is not available yet. Distinct from `isLoading`,
    /// which means the action is already running.
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            ZStack {
                // Both states are laid out; only one is visible. Swapping the
                // label for a spinner resizes the button mid-tap, and a
                // control that changes size under the finger that pressed it
                // reads as a mis-tap.
                HStack(spacing: PDSpacing.xs) {
                    Text(title)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if arrow {
                        Image(systemName: "arrow.right")
                    }
                }
                .opacity(isLoading ? 0 : 1)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.pd.onPrimary)
                    .opacity(isLoading ? 1 : 0)
            }
            .font(Font.pd.buttonLabel)
            .foregroundStyle(Color.pd.onPrimary)
            .padding(.horizontal, PDSpacing.l)
            .padding(.vertical, PDSpacing.s)
            .frame(maxWidth: .infinity)
            .frame(minHeight: PDMetric.primaryButtonHeight)
            // A capsule at 54pt; a rounded rectangle with the same radius once
            // a second line makes it taller, rather than a lozenge.
            .background(
                Color.pd.primaryButton,
                in: RoundedRectangle(cornerRadius: PDMetric.primaryButtonHeight / 2, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: PDMetric.primaryButtonHeight / 2, style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .disabled(isLoading || !isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? "Working" : "")
    }
}

/// The press response every control in this system shares.
///
/// A scale rather than an opacity change: dimming a dark button on a light
/// canvas makes it look disabled at the exact moment it is doing something.
struct PDPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(PDMotion.gentle, value: configuration.isPressed)
    }
}

#Preview("Primary button light") {
    PrimaryButtonPreview()
}

#Preview("Primary button dark") {
    PrimaryButtonPreview().preferredColorScheme(.dark)
}

private struct PrimaryButtonPreview: View {
    var body: some View {
        VStack(spacing: PDSpacing.m) {
            PrimaryButton(title: "Get started") {}
            PrimaryButton(title: "Download and continue") {}
            PrimaryButton(title: "Set it up", arrow: false) {}
            PrimaryButton(title: "Opening", isLoading: true) {}
            PrimaryButton(title: "Continue", isEnabled: false) {}
        }
        .padding(PDSpacing.heroGutter)
        .frame(maxHeight: .infinity)
        .pdCanvas()
    }
}
