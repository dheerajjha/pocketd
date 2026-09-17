import SwiftUI

/// A 40pt circle with one symbol in it, floating over the page.
///
/// The header controls — bell, avatar, history, new chat — and nothing else.
/// They float rather than sitting in a toolbar because these screens have no
/// navigation bar: the hero line is the title, and a system bar over it would
/// take 96pt to say the same word twice.
///
/// `label` is required and not optional. A circle containing a glyph is
/// invisible to VoiceOver otherwise, and this is the control most likely to be
/// the only way to reach a screen.
struct CircleIconButton: View {
    let symbol: String
    /// What VoiceOver says. Required — see above.
    let label: String
    /// A count in the corner. `nil` for no badge; zero is also no badge, so a
    /// caller can pass a count straight through.
    var badge: Int?
    var size: CGFloat = PDMetric.circleButton
    /// Fills the circle with the ink colour instead — used for the avatar.
    var fill: Color = .pd.floatSurface
    var tint: Color = .pd.ink
    let action: () -> Void

    private var badgeText: String? {
        guard let badge, badge > 0 else { return nil }
        return badge > 9 ? "9+" : "\(badge)"
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .overlay(Circle().strokeBorder(Color.pd.cardStroke, lineWidth: 1))
                .pdFloatShadow()
                .overlay(alignment: .topTrailing) {
                    if let badgeText {
                        Text(badgeText)
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.pd.onPrimary)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .frame(minWidth: 16)
                            .background(Color.pd.danger, in: Capsule())
                            // Half off the edge, which is where a badge reads
                            // as attached to the button rather than as a
                            // second control beside it.
                            .offset(x: 5, y: -4)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(badgeText.map { "\($0) waiting" } ?? "")
    }
}

/// The circle with a letter in it that means "you".
///
/// Its own type rather than a `CircleIconButton` with a text label, because the
/// avatar is the one saturated colour in the system and because it has to work
/// when there is no name yet.
struct AvatarButton: View {
    let initial: String
    var size: CGFloat = PDMetric.circleButton
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.pd.avatar, in: Circle())
                .pdFloatShadow()
                .contentShape(Circle())
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel("You")
    }
}

#Preview("Circle icon button light") {
    CircleIconButtonPreview()
}

#Preview("Circle icon button dark") {
    CircleIconButtonPreview().preferredColorScheme(.dark)
}

private struct CircleIconButtonPreview: View {
    var body: some View {
        VStack(spacing: PDSpacing.xl) {
            HStack(spacing: PDSpacing.s) {
                CircleIconButton(symbol: "bell", label: "Routines") {}
                CircleIconButton(symbol: "bell", label: "Routines", badge: 2) {}
                CircleIconButton(symbol: "bell", label: "Routines", badge: 14) {}
                AvatarButton(initial: "D") {}
            }
            HStack(spacing: PDSpacing.s) {
                CircleIconButton(symbol: "clock", label: "History", size: 34) {}
                CircleIconButton(symbol: "plus", label: "New chat", size: 34) {}
                CircleIconButton(symbol: "hand.thumbsup", label: "Good answer", size: 34) {}
                CircleIconButton(symbol: "hand.thumbsdown", label: "Bad answer", size: 34) {}
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pdCanvas()
    }
}
