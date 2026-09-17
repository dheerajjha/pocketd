import SwiftUI

/// The curves and durations this app animates with.
///
/// Named rather than written inline so that "the app's animation" is one thing
/// a reader can find, and so that changing the feel is a change to five
/// numbers rather than a search for every `.easeInOut`.
enum PDMotion {
    /// The default. Springy enough to feel physical, short enough that nobody
    /// waits for it.
    static let standard: Animation = .snappy(duration: 0.28)
    /// A card arriving.
    static let enter: Animation = .snappy(duration: 0.34)
    /// A toast, a callout — something that should not draw the eye away from
    /// what the person was reading.
    static let gentle: Animation = .easeOut(duration: 0.22)
    /// Between one staggered card and the next.
    static let staggerStep: Double = 0.04
    /// How long one pass of the shimmer takes.
    static let shimmerPeriod: Double = 1.4
}

// MARK: - Stagger

/// Cards arrive one after another rather than all at once.
///
/// 8pt of travel and 40ms apart: enough for the eye to read the list as
/// ordered, not enough to be a wait. The index is the card's position, so a
/// screen with six cards finishes in a quarter of a second.
///
/// Under Reduce Motion there is no travel and no delay — the content is simply
/// there. Fading a stack of six cards in sequence is still motion, and the
/// setting means what it says.
private struct StaggerIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(PDMotion.enter.delay(Double(index) * PDMotion.staggerStep)) {
                        shown = true
                    }
                }
            }
    }
}

// MARK: - Shimmer

/// The placeholder for text that is coming but is not here yet.
///
/// A moving highlight over a flat fill, and it is doing a specific job: it says
/// "this will fill in" where a spinner says "wait" and an empty box says
/// "broken". Used on the brief while the model warms up.
///
/// Under Reduce Motion the highlight does not travel; the shape stays as a
/// static tint, which still reads as a placeholder.
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.pd.card.opacity(0.85),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.6)
                        .offset(x: phase * width * 1.6)
                        .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)
                }
                .mask(content)
                .onAppear {
                    withAnimation(
                        .linear(duration: PDMotion.shimmerPeriod).repeatForever(autoreverses: false)
                    ) {
                        phase = 1
                    }
                }
        } else {
            content
        }
    }
}

/// A block standing in for a line of text that has not arrived.
///
/// Its own view rather than a modifier on `Text(" ")`, because the thing being
/// replaced has no intrinsic size yet and a zero-height shimmer is invisible.
struct ShimmerLine: View {
    var widthFraction: CGFloat = 1
    var height: CGFloat = 13

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.pd.fillTile)
                .frame(width: proxy.size.width * widthFraction, height: height)
                .pdShimmer()
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Modifiers

extension View {
    /// Arrive `index` steps after the first thing on the screen.
    func pdStaggerIn(_ index: Int) -> some View {
        modifier(StaggerIn(index: index))
    }

    /// Sweep a highlight across this view while `active`.
    func pdShimmer(_ active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

// MARK: - Previews

#Preview("Motion light") {
    MotionPreview()
}

#Preview("Motion dark") {
    MotionPreview().preferredColorScheme(.dark)
}

private struct MotionPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                SectionLabel("STAGGER")
                ForEach(0..<4, id: \.self) { index in
                    HStack {
                        Text("Card \(index + 1)")
                            .font(Font.pd.headline)
                            .foregroundStyle(Color.pd.ink)
                        Spacer()
                    }
                    .padding(PDSpacing.cardPadding)
                    .pdCardSurface()
                    .pdStaggerIn(index)
                }

                SectionLabel("SHIMMER")
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    ShimmerLine()
                    ShimmerLine(widthFraction: 0.92)
                    ShimmerLine(widthFraction: 0.55)
                }
                .padding(PDSpacing.cardPadding)
                .pdCardSurface()
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}
