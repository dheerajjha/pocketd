import SwiftUI
import UIKit

// MARK: - Colour

/// Pocketd's palette, as tokens rather than as literals scattered through
/// layout code.
///
/// The values are the measured ones — pixel-sampled from the reference design
/// rather than estimated — and the names are the ones the v2 spec defines, so
/// that a screen written against `Color.pd.accent` keeps compiling when a hue
/// is corrected here.
///
/// Every token carries both appearances in one value, built with
/// `UIColor { trait in }` rather than as asset-catalogue entries. Two reasons,
/// and the second is the one that matters:
///
/// - The catalogue is a binary blob in a repository whose whole argument is
///   that its details are checkable. A reviewer can read a hex pair here.
/// - A `Color` from an asset resolves against the *bundle*, so a SwiftUI
///   preview or a widget extension that cannot see the app bundle silently
///   renders black. `UIColor { trait in }` has no bundle to miss.
///
/// The names are roles, not hues: `ink` is "the colour text is", not "near
/// black", so a later repaint changes one line here instead of a hundred call
/// sites arguing about which grey they meant.
///
/// Two families of surface, and the distinction matters. The **cool** family
/// (`canvas`, `card`, `ink`) is the app proper. The **warm** family
/// (`canvasWarm`, `cardWarm`, `inkSecondaryWarm`, `fillWarm`) is the beige
/// onboarding run, where the same greys read cold against the paper.
extension Color {
    // Lowercase on purpose: `Color.pd.canvas` reads as a namespace and not as
    // a type anyone is meant to construct.
    enum pd { // swiftlint:disable:this type_name
        // MARK: Surfaces

        /// The true base. Not white — near-white with a trace of warmth, which
        /// is what stops a full screen of it glaring.
        static let canvas = dual(light: 0xFFFEFB, dark: 0x141311)
        /// The beige the onboarding run sits on.
        static let canvasWarm = dual(light: 0xF4F1EA, dark: 0x1A1816)
        /// The top of the home hero wash, fading into `canvas` over ~240pt.
        /// Always a gradient — see `PDGradient.canvasWash`.
        static let canvasTop = dual(light: 0xD7DDE5, dark: 0x1B1E26)
        /// The onboarding wash, fading into `canvasWarm` over ~400pt.
        static let canvasTopWarm = dual(light: 0xEFF0EB, dark: 0x201E1B)

        static let card = dual(light: 0xFFFFFF, dark: 0x1E1C19)
        /// A card on the warm canvas. Pure white there reads as a hole.
        static let cardWarm = dual(light: 0xFFFEFB, dark: 0x211F1C)
        static let cardStroke = dual(light: 0xE5E5E5, dark: 0x2C2926)
        static let cardStrokeWarm = dual(light: 0xE8E5DE, dark: 0x332F2B)
        /// Hairlines inside a card. The same value as the border by design:
        /// one weight of line in the whole system.
        static let divider = dual(light: 0xE5E5E5, dark: 0x2C2926)

        /// Chips, and the fill under anything that floats — the tab bar, the
        /// composer, a circular button.
        static let chip = dual(light: 0xF7F6F4, dark: 0x26231F)
        /// The same value under its other name, because "the tab bar is a
        /// chip" is not a sentence anybody should have to read.
        static let fillFloat = dual(light: 0xF7F6F4, dark: 0x26231F)
        /// A tile nested inside a card, which needs to be darker than the card
        /// and is therefore not `chip`.
        static let fillTile = dual(light: 0xEDEDED, dark: 0x2A2724)
        /// Icon tiles and pills on the warm canvas.
        static let fillWarm = dual(light: 0xEFEDE8, dark: 0x2A2723)
        /// The "Connect" pill.
        static let fillPill = dual(light: 0xF4F1EA, dark: 0x2E2B27)
        /// A circular floating button's own surface, a shade brighter than the
        /// canvas so its shadow has something to sit against.
        static let floatSurface = dual(light: 0xFDFDFB, dark: 0x232120)
        /// The capsule behind the selected tab.
        ///
        /// Its own token rather than `card`, because "selected" has to read as
        /// *raised* in both appearances and `card` is darker than the bar in
        /// dark mode — which turns the selection into a hole punched in the
        /// capsule. Caught in a dark screenshot, not in a preview.
        static let tabSelection = dual(light: 0xFFFFFF, dark: 0x35312C)
        /// The info bubble behind a `Callout`. The same fill as `accentSoft`.
        static let callout = dual(light: 0xECF2F9, dark: 0x1E2A3B)

        // MARK: Text

        static let ink = dual(light: 0x242424, dark: 0xF1EFEA)
        static let inkSecondary = dual(light: 0x7B7B7B, dark: 0xA39F97)
        /// Secondary text on the warm canvas, where the cool grey goes green.
        static let inkSecondaryWarm = dual(light: 0x76726A, dark: 0xA39F97)
        static let inkTertiary = dual(light: 0x747474, dark: 0x7C7871)

        // MARK: Meaning

        static let accent = dual(light: 0x39649E, dark: 0x8FB0EA)
        /// The accent on the warm canvas.
        static let accentWarm = dual(light: 0x2966A3, dark: 0x8FB0EA)
        static let accentSoft = dual(light: 0xECF2F9, dark: 0x1E2A3B)
        /// The onboarding icon tile's fill, which is not the callout blue.
        static let accentTile = dual(light: 0xE7EDED, dark: 0x212A2A)

        static let positive = dual(light: 0x2E613F, dark: 0x79CF95)
        static let positiveSoft = dual(light: 0xE7F2EB, dark: 0x16261B)
        static let caution = dual(light: 0x7D541D, dark: 0xE0B364)
        static let cautionSoft = dual(light: 0xF6ECD9, dark: 0x2B2213)
        static let danger = dual(light: 0xB03A2E, dark: 0xF08A7E)
        static let dangerSoft = dual(light: 0xF8E4E1, dark: 0x33201D)

        /// The avatar circle. The one saturated colour in the system, and it
        /// is deliberately nothing else's: it means "you".
        static let avatar = dual(light: 0x9F4DB6, dark: 0xC07FD4)

        // MARK: Controls

        /// Inverted against the canvas, which is what makes one button on a
        /// screen unmistakably *the* button without a colour anybody has to
        /// learn. Not pure black: nothing in this system is.
        static let primaryButton = dual(light: 0x17181A, dark: 0xF1EFEA)
        static let onPrimary = dual(light: 0xFFFEFB, dark: 0x17181A)

        /// The download stripe. The one place a hue is fixed across
        /// appearances: progress is the same event in both, and a stripe that
        /// changes colour with the system theme reads as a different state.
        static let progressStart = fixed(0x12AFFB)
        static let progressEnd = fixed(0x5A73CA)
        static let progressTrack = dual(light: 0xDEE0DB, dark: 0x34312C)

        // MARK: Construction

        private static func dual(light: UInt32, dark: UInt32) -> Color {
            Color(uiColor: UIColor { trait in
                UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light)
            })
        }

        private static func fixed(_ rgb: UInt32) -> Color {
            Color(uiColor: UIColor(rgb: rgb))
        }
    }
}

private extension UIColor {
    /// 0xRRGGBB, in the sRGB space the hex values were sampled in.
    ///
    /// `UIColor(red:green:blue:)` is `deviceRGB`, which is not sRGB on every
    /// display and shifts these values by enough to see on a large flat area
    /// like the canvas.
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Gradients

enum PDGradient {
    /// The home hero wash: `canvasTop` fading into the canvas over the top
    /// ~240pt. Not a full-height gradient — it resolves before the first card,
    /// so the page below it is flat.
    static let canvasWash = LinearGradient(
        colors: [Color.pd.canvasTop, Color.pd.canvas],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The onboarding wash, over the top ~400pt of the warm canvas.
    static let canvasWashWarm = LinearGradient(
        colors: [Color.pd.canvasTopWarm, Color.pd.canvasWarm],
        startPoint: .top,
        endPoint: .bottom
    )

    static let progress = LinearGradient(
        colors: [Color.pd.progressStart, Color.pd.progressEnd],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Type

/// The type scale, at the measured sizes.
///
/// Absolute sizes rather than text styles, because the layout the design was
/// drawn at is the layout that ships. `Text` wrappers below carry the tracking
/// and the leading, which are text layout rather than font properties and so
/// cannot live on a `Font` at all.
extension Font {
    enum pd { // swiftlint:disable:this type_name
        /// The onboarding hero. Pair with `Text.pdHero()`, which owns the
        /// -0.6 tracking and the 45pt line height.
        static let hero = Font.system(size: 36, weight: .bold)
        /// The home screen's H1 — the day name.
        static let title = Font.system(size: 30, weight: .bold)
        /// A pushed detail screen's H1, a step down from the home one.
        static let titleDetail = Font.system(size: 27, weight: .bold)
        /// A page's one calm explanatory sentence under the title.
        static let subtitle = Font.system(size: 17)
        /// The lead sentence inside a card: larger than body, still regular.
        static let lead = Font.system(size: 20)
        /// A card's own title.
        static let headline = Font.system(size: 19, weight: .semibold)
        /// The title of a row in a list of rows.
        static let rowTitle = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 17)
        static let secondary = Font.system(size: 15)
        static let caption = Font.system(size: 15)
        /// The sentence *under* a card rather than in it — the footnote that
        /// answers the objection the card has just raised, and the caveat a
        /// row is not big enough to carry. Smaller than `secondary` on
        /// purpose: it is a margin note, and a margin note set at body size
        /// competes with the body it is annotating.
        static let footnote = Font.system(size: 13)
        /// A control's label. Bigger than body, which is what makes a CTA read
        /// as one from across a room.
        static let buttonLabel = Font.system(size: 18, weight: .semibold)
        /// Mono uppercase section labels. Apply with `SectionLabel`, which also
        /// owns the 1.4 tracking and the casing.
        static let label = Font.system(size: 11, design: .monospaced)
        /// The same idea, one step smaller, for an eyebrow inside a card.
        static let miniLabel = Font.system(size: 10, design: .monospaced)
        /// A number in a row, right-aligned against other numbers.
        static let monoValue = Font.system(size: 16, weight: .semibold, design: .monospaced)
            .monospacedDigit()
        /// The big number on a stat tile. Regular rather than bold: the tile is
        /// a reading, not a headline.
        static let statValue = Font.system(size: 27, design: .monospaced)
            .monospacedDigit()
        /// The same slot when the value is words rather than a figure — an
        /// event title on UP NEXT, or "Free". Proportional and semibold: the
        /// mono face is the reference's way of saying "this is a number", and
        /// a letter-spaced "Design review" reads as a rendering fault.
        static let statText = Font.system(size: 24, weight: .semibold)
    }
}

extension Text {
    /// The hero line: 36pt bold, tracked in, leading set to 45pt.
    ///
    /// A method on `Text` rather than a `Font` token because tracking and line
    /// spacing are not part of a font — they are text layout, and putting them
    /// here is what stops every caller reinventing the two numbers.
    func pdHero() -> some View {
        font(Font.pd.hero)
            .tracking(-0.6)
            // 45pt line height on a 36pt face. `lineSpacing` is the gap added
            // between lines rather than the line height itself, so this is the
            // difference from the font's own ~43pt default.
            .lineSpacing(2)
    }

    /// The home screen's day name.
    func pdTitle() -> some View {
        font(Font.pd.title).tracking(-0.4)
    }

    /// A page subtitle: 17pt secondary, 25pt line height.
    func pdSubtitle() -> some View {
        font(Font.pd.subtitle)
            .foregroundStyle(Color.pd.inkSecondary)
            .lineSpacing(5)
    }

    /// Body copy in a card: 17pt secondary with the measured 5pt leading.
    func pdBody() -> some View {
        font(Font.pd.body)
            .foregroundStyle(Color.pd.inkSecondary)
            .lineSpacing(5)
    }
}

// MARK: - Space and shape

/// The spacing scale. Nothing outside it: a stray 14 is how a layout stops
/// looking like one system.
enum PDSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40

    /// The distance from the edge of the screen to anything in it.
    static let gutter: CGFloat = 16
    /// The wider margin the onboarding run and any hero page use.
    static let heroGutter: CGFloat = 24
    /// The inside of a `PDCard`.
    static let cardPadding: CGFloat = 20
    /// Between two stacked cards.
    static let cardGap: CGFloat = 16
    /// Between two cards side by side.
    static let tileGap: CGFloat = 12
    /// From the bottom of a hero header to the first card under it.
    static let heroToCard: CGFloat = 32
}

/// Corner radii. Every one of them `.continuous`; a circular corner next to a
/// continuous one is visible even when nobody can say why.
enum PDRadius {
    /// A content card.
    static let card: CGFloat = 26
    /// The larger source card the onboarding run uses.
    static let sourceCard: CGFloat = 24
    /// A small card in a two-up row.
    static let smallCard: CGFloat = 22
    static let callout: CGFloat = 20
    /// A stat tile nested inside a card.
    static let tile: CGFloat = 16
    /// The onboarding-sized icon tile.
    static let iconTile: CGFloat = 16
    /// The in-card icon tile.
    static let iconTileSmall: CGFloat = 8
    /// A chat bubble.
    static let bubble: CGFloat = 22
    /// Any number larger than half the height. `Capsule()` is preferred where
    /// the shape is known; this exists for the APIs that take a radius.
    static let pill: CGFloat = 999
    /// The primary button and the ask bar are both capsules. Kept as named
    /// constants because the spec names them, and because a future square
    /// button changes one line rather than twenty.
    static let button: CGFloat = pill
    static let chip: CGFloat = pill
    static let askBar: CGFloat = pill
}

/// Fixed dimensions the design depends on, named so that the tab bar's height
/// and the space a screen leaves for it cannot drift apart.
enum PDMetric {
    /// The pinned call to action.
    static let primaryButtonHeight: CGFloat = 54
    /// A pill that performs an action on this screen.
    static let pillHeight: CGFloat = 37
    /// A pill that is really a link.
    static let linkPillHeight: CGFloat = 24
    /// A circular icon button.
    static let circleButton: CGFloat = 40
    /// The floating action button.
    static let floatingActionButton: CGFloat = 56
    /// The composer.
    static let askBarHeight: CGFloat = 52
    /// The onboarding-sized icon tile.
    static let iconTile: CGFloat = 52
    /// The in-card icon tile.
    static let iconTileSmall: CGFloat = 30

    static let tabBarHeight: CGFloat = 53
    static let tabBarMaxWidth: CGFloat = 358
    static let tabBarSideMargin: CGFloat = 16
    /// How far the capsule floats above the bottom safe area.
    static let tabBarBottomInset: CGFloat = 22
    /// The selected tab's capsule.
    static let tabBarSelectionWidth: CGFloat = 57
    static let tabBarSelectionHeight: CGFloat = 37

    /// What every tab's scroll view must keep clear at the bottom so its last
    /// row is not under the floating bar. Content scrolls *under* the bar, so
    /// this is a bottom safe-area inset on the scroll view and never a gap in
    /// the page.
    static let tabBarClearance: CGFloat = 96

    /// Real layout space for the bar, for a screen that cannot scroll under it.
    ///
    /// A screen whose bottom edge is a control — a composer, a pinned CTA —
    /// has to *end* above the capsule rather than pass beneath it. Measured
    /// from the bottom safe area rather than from the screen edge, which is
    /// where this sits in the shell's `ZStack`.
    static let tabBarReserve: CGFloat = tabBarBottomInset + tabBarHeight + PDSpacing.xs
}

// MARK: - Surfaces

extension View {
    /// The flat page colour, under everything including the safe areas.
    func pdCanvas() -> some View {
        background(Color.pd.canvas.ignoresSafeArea())
    }

    /// The warm page colour the onboarding run sits on.
    func pdCanvasWarm() -> some View {
        background(Color.pd.canvasWarm.ignoresSafeArea())
    }

    /// The card surface: fill, hairline border, and a shadow soft enough that
    /// it reads as lift rather than as a drop.
    ///
    /// The border is what defines the edge — the shadow alone leaves a card
    /// floating with no outline, which on a near-white canvas is a smudge. Both
    /// or neither.
    func pdCardSurface(
        radius: CGFloat = PDRadius.card,
        fill: Color = .pd.card,
        stroke: Color = .pd.cardStroke
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .pdCardShadow()
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        )
    }

    /// The lift under a card.
    func pdCardShadow() -> some View {
        shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 4)
    }

    /// The lift under anything that floats over content: the tab bar, the
    /// composer, a circular button, a pinned CTA.
    ///
    /// Two shadows and not one. The wide soft one is the height; the tight
    /// near-opaque one is the contact edge, and without it a floating capsule
    /// on a light canvas looks pasted on.
    func pdFloatShadow() -> some View {
        shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 6)
            .shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Previews

#Preview("Palette light") {
    PalettePreview()
}

#Preview("Palette dark") {
    PalettePreview().preferredColorScheme(.dark)
}

private struct PalettePreview: View {
    private let swatches: [(String, Color)] = [
        ("canvas", .pd.canvas), ("canvasWarm", .pd.canvasWarm), ("canvasTop", .pd.canvasTop),
        ("card", .pd.card), ("cardWarm", .pd.cardWarm), ("cardStroke", .pd.cardStroke),
        ("chip / fillFloat", .pd.chip), ("fillTile", .pd.fillTile), ("fillWarm", .pd.fillWarm),
        ("fillPill", .pd.fillPill), ("floatSurface", .pd.floatSurface), ("callout", .pd.callout),
        ("ink", .pd.ink), ("inkSecondary", .pd.inkSecondary), ("inkTertiary", .pd.inkTertiary),
        ("accent", .pd.accent), ("accentSoft", .pd.accentSoft), ("accentTile", .pd.accentTile),
        ("positive", .pd.positive), ("positiveSoft", .pd.positiveSoft),
        ("caution", .pd.caution), ("cautionSoft", .pd.cautionSoft),
        ("danger", .pd.danger), ("dangerSoft", .pd.dangerSoft),
        ("avatar", .pd.avatar), ("primaryButton", .pd.primaryButton), ("onPrimary", .pd.onPrimary),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.m) {
                Text("Thursday").pdTitle().foregroundStyle(Color.pd.ink)
                Text("Every token, both appearances.").pdSubtitle()
                ForEach(swatches, id: \.0) { name, colour in
                    HStack(spacing: PDSpacing.s) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colour)
                            .frame(width: 44, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.pd.cardStroke, lineWidth: 1)
                            )
                        Text(name).font(Font.pd.monoValue).foregroundStyle(Color.pd.ink)
                    }
                }
            }
            .padding(PDSpacing.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pdCanvas()
    }
}
