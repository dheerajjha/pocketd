import SwiftUI

/// The one piece of theatre in the app, and it is load-bearing.
///
/// A phone generating text takes seconds, and seconds of nothing is how a
/// person decides an app is broken. A spinner says "waiting"; this says
/// "working". It is also the app's only mark — the thing on the welcome screen
/// that has to make somebody want to keep going.
///
/// Two sizes: 96pt as the hero on the welcome and ready screens, 24pt inline
/// beside "Thinking…" in Ask. Everything scales from `size`, so any value
/// between works.
///
/// Under Reduce Motion the mesh stops and the dots stop: what is left is a
/// still orb with the same colours, which still reads as the same object.
struct ThinkingOrb: View {
    var size: CGFloat = 96
    /// How many dots drift over it. Twelve at hero size; fewer would look
    /// sparse and more turns into noise.
    var dotCount: Int = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                still
            } else {
                // `TimelineView(.animation)` rather than a chain of
                // `repeatForever` animations: the mesh points and the dots all
                // need to read the *same* clock, and twelve independently
                // scheduled animations drift apart within a minute.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    mesh(at: time)
                        .rotationEffect(.degrees(time * 5))
                        .overlay { dots(at: time) }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(Color.pd.cardStroke.opacity(0.7), lineWidth: size > 40 ? 1 : 0.5)
        )
        // A slow breath on the whole orb. `phaseAnimator` is the right tool
        // here and the wrong one for the rotation above: a two-phase scale
        // wants to reverse, and a rotation does not.
        .modifier(BreathModifier(active: !reduceMotion, amount: size > 40 ? 0.03 : 0.015))
        .accessibilityElement()
        .accessibilityLabel("Thinking")
    }

    // MARK: Mesh

    /// Three colours, and they are the app's: accent, positive, canvas. Not a
    /// rainbow — the orb has to sit on the same page as a brief without
    /// becoming the loudest thing on it.
    private var meshColours: [Color] {
        [
            .pd.accent, .pd.accentSoft, .pd.canvas,
            .pd.positiveSoft, .pd.accent, .pd.accentSoft,
            .pd.canvas, .pd.positive, .pd.accent,
        ]
    }

    private func mesh(at time: TimeInterval) -> some View {
        MeshGradient(width: 3, height: 3, points: meshPoints(at: time), colors: meshColours)
    }

    /// A 3×3 grid whose edge midpoints and centre wander.
    ///
    /// The corners are pinned. A mesh whose corners move leaves the unit square
    /// and the gradient tears at the edge of the circle, which looks like a
    /// rendering bug rather than a design.
    private func meshPoints(at time: TimeInterval) -> [SIMD2<Float>] {
        func wobble(_ base: Float, _ phase: Double, _ amount: Float = 0.12) -> Float {
            base + amount * Float(sin(time * 0.6 + phase))
        }
        return [
            SIMD2(0, 0), SIMD2(wobble(0.5, 0.0), 0), SIMD2(1, 0),
            SIMD2(0, wobble(0.5, 1.3)), SIMD2(wobble(0.5, 2.1), wobble(0.5, 3.4)), SIMD2(1, wobble(0.5, 4.2)),
            SIMD2(0, 1), SIMD2(wobble(0.5, 5.0), 1), SIMD2(1, 1),
        ]
    }

    private var still: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
                SIMD2(0, 0.5), SIMD2(0.5, 0.5), SIMD2(1, 0.5),
                SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1),
            ],
            colors: meshColours
        )
    }

    // MARK: Dots

    /// Twelve dots on their own orbits.
    ///
    /// Drawn in one `Canvas` rather than as twelve `Circle` views: twelve views
    /// each with their own animation is twelve layers the compositor has to
    /// keep in step, and at 24pt they would be sub-pixel anyway.
    private func dots(at time: TimeInterval) -> some View {
        Canvas { context, canvasSize in
            let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let maximum = min(canvasSize.width, canvasSize.height) / 2
            for index in 0..<dotCount {
                let seed = Double(index)
                let orbit = maximum * (0.28 + 0.62 * CGFloat((sin(seed * 2.4) + 1) / 2))
                let speed = 0.18 + 0.22 * ((sin(seed * 1.7) + 1) / 2)
                let angle = time * speed + seed * 0.52
                let drift = 1 + 0.08 * sin(time * 0.9 + seed)
                let point = CGPoint(
                    x: centre.x + orbit * CGFloat(cos(angle)) * CGFloat(drift),
                    y: centre.y + orbit * CGFloat(sin(angle)) * CGFloat(drift)
                )
                let radius = maximum * (0.028 + 0.030 * CGFloat((sin(seed * 3.1) + 1) / 2))
                let opacity = 0.28 + 0.34 * ((sin(time * 1.3 + seed * 0.9) + 1) / 2)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: point.x - radius, y: point.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// A slow scale breath, built on `phaseAnimator`.
///
/// Separated out so the orb's body stays readable, and because the modifier is
/// the only thing that needs to know that a two-phase animator reverses.
private struct BreathModifier: ViewModifier {
    let active: Bool
    let amount: CGFloat

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, inhaled in
                view.scaleEffect(inhaled ? 1 + amount : 1 - amount)
            } animation: { _ in
                .easeInOut(duration: 2.6)
            }
        } else {
            content
        }
    }
}

#Preview("Thinking orb light") {
    ThinkingOrbPreview()
}

#Preview("Thinking orb dark") {
    ThinkingOrbPreview().preferredColorScheme(.dark)
}

private struct ThinkingOrbPreview: View {
    var body: some View {
        VStack(spacing: PDSpacing.xxl) {
            ThinkingOrb()
            HStack(spacing: PDSpacing.xs) {
                ThinkingOrb(size: 24, dotCount: 7)
                Text("Thinking…")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
            }
            ThinkingOrb(size: 56, dotCount: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pdCanvas()
    }
}
