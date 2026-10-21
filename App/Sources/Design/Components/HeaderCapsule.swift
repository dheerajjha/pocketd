import SwiftUI

/// The home screen's two ways out: Routines and You.
///
/// One capsule holding the routines glyph and the avatar, the way the
/// reference's home header does it. Two things, not three: v2 had a bell that
/// meant "routines" (a bell means notifications) and an avatar that duplicated
/// a tab.
///
/// The badge is a dot, not a count — "something new in Routines", set only
/// while a routine's result is unread. A number would be a to-do list in the
/// corner of a screen that is meant to be calm.
///
/// Fixed chrome: the capsule does not grow with Dynamic Type, so each button
/// offers the Large Content Viewer, as the system's bar buttons do. Each is a
/// full 44×44 target; the capsule is drawn around them.
struct HeaderCapsule: View {
    let initial: String
    /// A routine result is waiting to be read.
    var showsBadge: Bool = false
    let onRoutines: () -> Void
    let onYou: () -> Void

    /// The avatar inside the capsule, a step smaller than a free-standing one
    /// so the capsule stays 48pt tall.
    private let avatarSize: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.tap()
                onRoutines()
            } label: {
                Image(systemName: "alarm")
                    // Fixed chrome; see the type comment.
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.pd.ink)
                    .overlay(alignment: .topTrailing) {
                        if showsBadge {
                            Circle()
                                .fill(Color.pd.accent)
                                .frame(width: 9, height: 9)
                                // A ring in the capsule's own colour, so the
                                // dot reads as on the glyph, not part of it.
                                .overlay(Circle().strokeBorder(Color.pd.floatSurface, lineWidth: 1.5))
                                .offset(x: 4, y: -2)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .pdHitTarget()
            }
            .buttonStyle(PDPressStyle())
            .accessibilityLabel("Routines")
            .accessibilityValue(showsBadge ? "New result" : "")
            .accessibilityShowsLargeContentViewer {
                Label("Routines", systemImage: "alarm")
            }

            Button {
                Haptics.tap()
                onYou()
            } label: {
                AvatarCircle(initial: initial, size: avatarSize)
                    .pdHitTarget()
            }
            .buttonStyle(PDPressStyle())
            .accessibilityLabel("You")
            .accessibilityShowsLargeContentViewer {
                Label("You", systemImage: "person.crop.circle")
            }
        }
        .padding(.horizontal, PDSpacing.xxs)
        .padding(.vertical, 2)
        .pdGlass()
        .animation(PDMotion.gentle, value: showsBadge)
    }
}

#Preview("Header capsule light") {
    HeaderCapsulePreview()
}

#Preview("Header capsule dark") {
    HeaderCapsulePreview().preferredColorScheme(.dark)
}

private struct HeaderCapsulePreview: View {
    var body: some View {
        VStack(spacing: PDSpacing.xl) {
            HeaderCapsule(initial: "D", onRoutines: {}, onYou: {})
            HeaderCapsule(initial: "S", showsBadge: true, onRoutines: {}, onYou: {})
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pdCanvas()
        .pdHeroWash()
    }
}
