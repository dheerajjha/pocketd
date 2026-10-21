import SwiftUI

/// A 40pt circle with one symbol in it, floating over the page.
///
/// The header controls — back, close, history, new chat — and nothing else.
/// They float rather than sitting in a toolbar on screens that draw their own
/// header; a screen with a native navigation bar uses toolbar items instead.
///
/// `label` is required and not optional. A circle containing a glyph is
/// invisible to VoiceOver otherwise, and this is the control most likely to be
/// the only way to reach a screen.
///
/// The circle is drawn at `size` but the button is never smaller than 44×44
/// to a finger: a 32pt thumb or a 40pt back button gets the rest of its target
/// as transparent frame around it. The glyph does not grow with Dynamic Type —
/// the circle is fixed chrome — so a long press shows it in the Large Content
/// Viewer instead, the way the system's own bar buttons do.
struct CircleIconButton: View {
    let symbol: String
    /// What VoiceOver says. Required — see above.
    let label: String
    /// A count in the corner. `nil` for no badge; zero is also no badge, so a
    /// caller can pass a count straight through.
    var badge: Int?
    /// The visible circle. The tappable frame is at least 44 whatever this is.
    var size: CGFloat = PDMetric.circleButton
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
                // A glyph in fixed chrome: sized by the circle, not by the
                // text setting. See the type comment.
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(fill).pdFloatShadow()
                }
                .overlay(Circle().strokeBorder(Color.pd.cardStroke, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if let badgeText {
                        Text(badgeText)
                            .font(Font.pd.tick.weight(.bold))
                            .monospacedDigit()
                            // Chrome: the count stays the size of the circle
                            // it is pinned to.
                            .dynamicTypeSize(...DynamicTypeSize.large)
                            .foregroundStyle(Color.pd.onPrimary)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.pd.danger, in: Capsule())
                            // Half off the edge, which is where a badge reads
                            // as attached to the button rather than as a
                            // second control beside it.
                            .offset(x: 5, y: -4)
                    }
                }
                .pdHitTarget()
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(badgeText.map { "\($0) waiting" } ?? "")
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: symbol)
        }
    }
}

/// The purple circle with a letter in it that means "you".
///
/// Drawn here once so the header, the You page and anything else showing the
/// person agree on it — including the initial's colour, which is `onAvatar`
/// rather than white: white on the dark-mode purple is 2.9:1.
///
/// The letter is set in a text style chosen by the circle's size and capped
/// at the default text size: it is a monogram in fixed chrome, and a letter
/// that grew with Dynamic Type would leave the circle.
struct AvatarCircle: View {
    let initial: String
    var size: CGFloat = PDMetric.circleButton

    private var letterFont: Font {
        switch size {
        case ..<36: .system(.subheadline, weight: .semibold)
        case ..<48: .system(.body, weight: .semibold)
        case ..<64: .system(.title2, weight: .semibold)
        default: .system(.largeTitle, weight: .semibold)
        }
    }

    var body: some View {
        Text(initial)
            .font(letterFont)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .foregroundStyle(Color.pd.onAvatar)
            .frame(width: size, height: size)
            .background(Color.pd.avatar, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The avatar as a button — "You".
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
            AvatarCircle(initial: initial, size: size)
                .background { Circle().fill(Color.pd.avatar).pdFloatShadow() }
                .pdHitTarget()
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel("You")
        .accessibilityShowsLargeContentViewer {
            Label("You", systemImage: "person.crop.circle")
        }
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
                CircleIconButton(symbol: "chevron.left", label: "Back") {}
                CircleIconButton(symbol: "bell", label: "Routines", badge: 2) {}
                CircleIconButton(symbol: "bell", label: "Routines", badge: 14) {}
                AvatarButton(initial: "D") {}
            }
            HStack(spacing: PDSpacing.s) {
                CircleIconButton(symbol: "clock", label: "History", size: 34) {}
                CircleIconButton(symbol: "plus", label: "New chat", size: 34) {}
                CircleIconButton(symbol: "hand.thumbsup", label: "Good answer", size: 32) {}
                CircleIconButton(symbol: "hand.thumbsdown", label: "Bad answer", size: 32) {}
            }
            HStack(spacing: PDSpacing.s) {
                AvatarCircle(initial: "S", size: 32)
                AvatarCircle(initial: "S", size: 40)
                AvatarCircle(initial: "S", size: 56)
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pdCanvas()
    }
}
