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
/// Three greys were *not* kept as sampled, and on purpose: the reference's
/// secondary text measured 4.2:1 on its own canvas, under the 4.5:1 that body
/// text needs, and its tertiary grey was darker than its secondary one. The
/// light `inkSecondary`, `inkSecondaryWarm` and `inkTertiary` below are the
/// corrected values; every other surface and hue is still the measured one.
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

        // MARK: Text

        static let ink = dual(light: 0x242424, dark: 0xF1EFEA)
        /// Every grey word in the app: summaries, card body, captions, labels.
        ///
        /// 0x686868 rather than the sampled 0x7B7B7B, which was 4.2:1 on the
        /// canvas. This clears 4.5:1 on every light surface text sits on —
        /// canvas 5.5, card 5.6, chip 5.1, a nested `fillTile` 4.8, and the
        /// hero wash where the date sits 4.6. Dark is 6.4–7.0 everywhere.
        static let inkSecondary = dual(light: 0x686868, dark: 0xA39F97)
        /// Secondary text on the warm canvas, where the cool grey goes green.
        /// Darkened from 0x76726A (4.25:1) for the same reason: 5.0 on the warm
        /// canvas, 4.8 on `fillWarm`.
        static let inkSecondaryWarm = dual(light: 0x6B675F, dark: 0xA39F97)
        /// Decoration only: timeline rails, an unticked circle, the "·"
        /// between two facts, a chevron that repeats what the row already
        /// says. **Never words** — anything a person has to read is
        /// `inkSecondary`.
        ///
        /// Lighter than `inkSecondary`, which it was not (the sampled 0x747474
        /// sat *darker* than the sampled secondary and inverted the
        /// hierarchy). It keeps 3.4:1 on canvas and card, the floor for a
        /// glyph that carries state, and no more.
        static let inkTertiary = dual(light: 0x8A8A8A, dark: 0x7C7871)

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
        /// The initial on the avatar. White on the light purple (5.0:1), but a
        /// deep plum on the dark-mode one: white on 0xC07FD4 is 2.9:1, which
        /// fails even for large text, and darkening the circle instead would
        /// lose the one saturated colour against a dark canvas.
        static let onAvatar = dual(light: 0xFFFFFF, dark: 0x2A1233)

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

/// The type scale, built on text styles so that Dynamic Type works.
///
/// v2 shipped absolute sizes ("the layout the design was drawn at is the
/// layout that ships"), which meant a person who had asked iOS for larger
/// text got the same 15pt grey everywhere. Every token now names a text style,
/// and the point sizes in the comments are what each resolves to at the
/// default Large setting — within a point or two of the measured design.
///
/// Two consequences every caller inherits:
///
/// - **Nothing here has a fixed height any more.** A container that sets
///   `.frame(height:)` around text will clip it at the accessibility sizes.
///   Use `minHeight`, and let rows grow.
/// - **Glyphs next to text take the text's token**, so the symbol grows with
///   the word it belongs to (`Image(systemName:).font(Font.pd.secondary)`).
///   Only a glyph inside fixed chrome — a 40pt circle, a 30pt icon tile —
///   keeps a fixed `.system(size:)`, and that chrome offers the Large Content
///   Viewer instead.
///
/// `Text` wrappers below carry the tracking and the leading, which are text
/// layout rather than font properties and so cannot live on a `Font` at all.
extension Font {
    enum pd { // swiftlint:disable:this type_name
        /// The onboarding and promo hero — `.largeTitle` bold, 34pt. Pair with
        /// `Text.pdHero()`, which owns the tracking and the leading.
        static let hero = Font.system(.largeTitle, weight: .bold)
        /// The home screen's H1, the day name — `.largeTitle` bold, 34pt.
        static let title = Font.system(.largeTitle, weight: .bold)
        /// A pushed detail screen's H1, a step down from the home one —
        /// `.title` bold, 28pt.
        static let titleDetail = Font.system(.title, weight: .bold)
        /// A page's one calm explanatory sentence under the title — `.body`.
        static let subtitle = Font.system(.body)
        /// The lead sentence: the brief on Today, the answer in a card —
        /// `.title3`, 20pt, regular.
        static let lead = Font.system(.title3)
        /// A card's own title — `.title3` semibold, 20pt.
        static let headline = Font.system(.title3, weight: .semibold)
        /// The title of a row in a list of rows — `.headline`, 17pt semibold.
        static let rowTitle = Font.system(.headline)
        /// `.body`, 17pt.
        static let body = Font.system(.body)
        /// Card body, a row's grey line, a chip — `.subheadline`, 15pt.
        static let secondary = Font.system(.subheadline)
        /// The same 15pt under its older name. Kept because callers use it;
        /// new code says `secondary`.
        static let caption = Font.system(.subheadline)
        /// The sentence *under* a card rather than in it — the footnote that
        /// answers the objection the card has just raised, and the caveat a
        /// row is not big enough to carry. Smaller than `secondary` on
        /// purpose: it is a margin note, and a margin note set at body size
        /// competes with the body it is annotating. `.footnote`, 13pt.
        static let footnote = Font.system(.footnote)
        /// The primary pill's label — `.headline`, 17pt semibold.
        static let buttonLabel = Font.system(.headline)
        /// Mono uppercase section labels and dates — `.caption2` monospaced,
        /// 11pt. Apply with `SectionLabel`, which also owns the 1.4 tracking
        /// and the casing.
        ///
        /// Mono has exactly two jobs in this system: these small caps labels,
        /// and right-aligned values in a list (`monoValue`). Never a title, a
        /// hero number, or a word in a sentence.
        static let label = Font.system(.caption2, design: .monospaced)
        /// An eyebrow inside a card or tile. The same style as `label` — text
        /// styles stop at `.caption2` — and set apart by `MiniLabel`'s tighter
        /// tracking.
        static let miniLabel = Font.system(.caption2, design: .monospaced)
        /// A value right-aligned against other values in a list — "6:30",
        /// "7h 05m" — `.callout` mono semibold, 16pt.
        static let monoValue = Font.system(.callout, design: .monospaced, weight: .semibold)
        /// A hero number: a comparison tile, a stat tile — `.title`, 28pt.
        ///
        /// Proportional, regular weight. The reference sets every hero number
        /// in its sans and keeps mono for columns; a 28pt typewriter "6h 36m"
        /// reads as a terminal. The digits are tabular only so that a count
        /// that updates in place does not shuffle sideways as it changes.
        static let statValue = Font.system(.title).monospacedDigit()
        /// The same slot when the value is words rather than a figure — an
        /// event title, or "Free" — `.title2` semibold, 22pt.
        static let statText = Font.system(.title2, weight: .semibold)
        /// A routine's time, the hero of its alarm-style card — "7:30" —
        /// `.largeTitle` regular, 34pt, proportional. Regular, like a clock
        /// face: the time is read, not announced. Set "AM"/"PM" beside it in
        /// `secondary`.
        static let timeHero = Font.system(.largeTitle)
        /// The status word on a `VerdictTile`: "Rested", "1 overdue", an event
        /// title — `.title3`, 20pt, regular. The colour carries the meaning;
        /// weight would only shout it.
        static let verdict = Font.system(.title3)
        /// Code, a file path, a key — `.footnote` monospaced, 13pt. Not for
        /// labels (those are `label`) and not for values in a list (those are
        /// `monoValue`).
        static let code = Font.system(.footnote, design: .monospaced)
        /// The chevron or arrow at the end of a row or a link —
        /// `.footnote` semibold, 13pt, so it grows with the row it ends.
        static let chevron = Font.system(.footnote, weight: .semibold)
        /// A tick, a minus or a plus inside a small line of text —
        /// `.caption2` semibold, 11pt.
        static let tick = Font.system(.caption2, weight: .semibold)
    }
}

extension Text {
    /// The hero line: `.largeTitle` bold, tracked in, the leading opened a
    /// little.
    ///
    /// A method on `Text` rather than a `Font` token because tracking and line
    /// spacing are not part of a font — they are text layout, and putting them
    /// here is what stops every caller reinventing the two numbers.
    func pdHero() -> some View {
        font(Font.pd.hero)
            .tracking(-0.6)
            // A slightly looser line than the face's own default: a two-line
            // hero ending in "." reads as one statement rather than two.
            .modifier(PDLineSpacing(2, relativeTo: .largeTitle))
    }

    /// The home screen's day name.
    func pdTitle() -> some View {
        font(Font.pd.title).tracking(-0.4)
    }

    /// A page subtitle: `.body` secondary with the measured 5pt leading.
    func pdSubtitle() -> some View {
        font(Font.pd.subtitle)
            .foregroundStyle(Color.pd.inkSecondary)
            .modifier(PDLineSpacing(5, relativeTo: .body))
    }

    /// Body copy in a card: `.body` secondary with the measured 5pt leading.
    func pdBody() -> some View {
        font(Font.pd.body)
            .foregroundStyle(Color.pd.inkSecondary)
            .modifier(PDLineSpacing(5, relativeTo: .body))
    }

    /// The lead sentence — the brief, an answer: `.title3` in ink, with the
    /// ≈1.5× line height the reference sets its 20pt leads at.
    func pdLead() -> some View {
        font(Font.pd.lead)
            .foregroundStyle(Color.pd.ink)
            .modifier(PDLineSpacing(6, relativeTo: .title3))
    }
}

/// Leading that grows with the text it spaces.
///
/// `lineSpacing(5)` is right at 17pt and cramped at 40: the gap is a
/// proportion of the line, not a constant. `@ScaledMetric` scales it with the
/// same text style the font uses, so the paragraph keeps its colour at every
/// size.
struct PDLineSpacing: ViewModifier {
    @ScaledMetric private var spacing: CGFloat

    // Nonisolated so the `Text` helpers above, which are not main-actor
    // methods, can build it; it only stores a value.
    nonisolated init(_ base: CGFloat, relativeTo style: Font.TextStyle) {
        _spacing = ScaledMetric(wrappedValue: base, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content.lineSpacing(spacing)
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

    /// The distance from the edge of the screen to anything in it.
    static let gutter: CGFloat = 16
    /// The wider margin the onboarding run and any hero page use.
    static let heroGutter: CGFloat = 24
    /// The inside of a `PDCard`.
    static let cardPadding: CGFloat = 20
    /// Between two stacked cards.
    static let cardGap: CGFloat = 16
    /// Between two cards side by side, and between the rows of a tile grid.
    static let tileGap: CGFloat = 12
}

/// Corner radii. Every one of them `.continuous`; a circular corner next to a
/// continuous one is visible even when nobody can say why.
///
/// Capsules have no token: write `Capsule(style: .continuous)`.
enum PDRadius {
    /// A content card.
    static let card: CGFloat = 26
    /// A small card in a two-up row — a `VerdictTile`.
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
}

/// Fixed dimensions the design depends on, named so that the tab bar's height
/// and the space a screen leaves for it cannot drift apart.
///
/// The control heights are *minimums*. Since the type scale follows Dynamic
/// Type, a control that pins its height clips its own label at the larger
/// sizes; every component here uses `frame(minHeight:)`.
enum PDMetric {
    /// The smallest thing a finger is asked to hit, in both directions —
    /// Apple's 44×44. A control may *look* smaller (a 24pt link pill, a 32pt
    /// thumb); its tappable frame may not. See `View.pdHitTarget()`.
    static let minHitTarget: CGFloat = 44
    /// The pinned call to action.
    static let primaryButtonHeight: CGFloat = 54
    /// A pill that performs an action on this screen. The visible capsule;
    /// the tappable frame around it is `minHitTarget`.
    static let pillHeight: CGFloat = 37
    /// A pill that is really a link. The visible capsule, as above.
    static let linkPillHeight: CGFloat = 24
    /// A circular icon button. The visible circle, as above.
    static let circleButton: CGFloat = 40
    /// The composer.
    static let askBarHeight: CGFloat = 52
    /// The onboarding-sized icon tile.
    static let iconTile: CGFloat = 52
    /// The in-card icon tile.
    static let iconTileSmall: CGFloat = 30
}

// MARK: - Surfaces

extension View {
    /// The flat page colour, under everything including the safe areas.
    func pdCanvas() -> some View {
        background(Color.pd.canvas.ignoresSafeArea())
    }

    /// At least 44×44 to a finger, whatever it looks like.
    ///
    /// Grows the *frame* — so the row around a small control gets the room
    /// too — and makes the whole of it tappable, while everything drawn stays
    /// the size it was. Apply it to a `Button`'s label after the visible
    /// background, so the capsule keeps its size and only the hit area grows.
    func pdHitTarget(alignment: Alignment = .center) -> some View {
        frame(minWidth: PDMetric.minHitTarget, minHeight: PDMetric.minHitTarget, alignment: alignment)
            .contentShape(Rectangle())
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
        ("fillPill", .pd.fillPill), ("floatSurface", .pd.floatSurface),
        ("ink", .pd.ink), ("inkSecondary", .pd.inkSecondary), ("inkTertiary", .pd.inkTertiary),
        ("inkSecondaryWarm", .pd.inkSecondaryWarm), ("onAvatar", .pd.onAvatar),
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
