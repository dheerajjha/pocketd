import SwiftUI

// MARK: - Glass

extension View {
    /// The surface for chrome that floats over content: the composer, the
    /// suggestion chip, the header capsule.
    ///
    /// Liquid Glass on iOS 26 and later, where the system draws the lift, the
    /// edge and the refraction itself and adapts them to Reduce Transparency
    /// and Increase Contrast. Before iOS 26 it is the solid floating surface
    /// the approved v2 frames were drawn with — `floatSurface`, a hairline and
    /// the two-part float shadow — rather than a material: a blur that only
    /// some phones get would make the same screen look like two designs.
    ///
    /// Only for chrome. A card is content and keeps `pdCardSurface`; glass on
    /// a card turns the page into a stack of windows.
    ///
    /// - Parameter interactive: Whether the glass responds to touch (iOS 26's
    ///   press highlight). Set it when the whole surface is one control.
    @ViewBuilder
    func pdGlass<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            background {
                // The shadow is cast by the fill alone. On the whole view it
                // would also shadow every glyph and letter on the surface,
                // which reads as smudged text.
                shape.fill(Color.pd.floatSurface).pdFloatShadow()
            }
            .overlay(shape.strokeBorder(Color.pd.cardStroke, lineWidth: 1))
        }
    }

    /// `pdGlass` in a capsule, the shape nearly all floating chrome is.
    func pdGlass(interactive: Bool = false) -> some View {
        pdGlass(Capsule(style: .continuous), interactive: interactive)
    }

    /// Pins `bar` to the bottom of a scrolling screen, over its content.
    ///
    /// iOS 26's `safeAreaBar`, which gives the scroll view under it the native
    /// scroll-edge effect so text fades out beneath the bar instead of
    /// colliding with it. Before iOS 26, `safeAreaInset` with a fade into
    /// `scrim` doing the same job by hand: the content still ends above the
    /// bar when scrolled to the bottom, and passes under a soft wash on the
    /// way there.
    ///
    /// - Parameter scrim: The page colour to fade into. The canvas unless the
    ///   screen sits on another one.
    func pdBottomBar<Bar: View>(scrim: Color = .pd.canvas, @ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(PDBottomBar(scrim: scrim, bar: bar()))
    }
}

private struct PDBottomBar<Bar: View>: ViewModifier {
    let scrim: Color
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) { bar }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                bar.background(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: scrim.opacity(0), location: 0),
                            .init(color: scrim.opacity(0.92), location: 0.45),
                            .init(color: scrim, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .padding(.top, -PDSpacing.l)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

#Preview("Glass light") {
    GlassPreview()
}

#Preview("Glass dark") {
    GlassPreview().preferredColorScheme(.dark)
}

private struct GlassPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                ForEach(0..<8, id: \.self) { index in
                    PDCard {
                        Text("Card \(index + 1) scrolls under the bar.")
                            .font(Font.pd.body)
                            .foregroundStyle(Color.pd.ink)
                    }
                }
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
        .pdBottomBar {
            Text("Floating chrome")
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.ink)
                .padding(.horizontal, PDSpacing.l)
                .frame(minHeight: PDMetric.askBarHeight)
                .pdGlass()
                .padding(.bottom, PDSpacing.xs)
        }
    }
}
