import SwiftUI

/// "Get your day every morning →"
///
/// A call to action that is a line of text, not a button: semibold ink with
/// the arrow in the accent. It is how a card asks for something without
/// competing with the screen's one black button, and how a page offers its
/// quiet alternative ("Not now →").
///
/// → means "goes somewhere in the app"; pass `arrow.up.right` (↗) when it
/// leaves the app. The visible text is as tall as its line; the button is at
/// least 44pt.
struct TextLink: View {
    let title: String
    var symbol: String = "arrow.right"
    /// The words' colour. Ink; `inkSecondary` for an escape like "Not now".
    var tint: Color = .pd.ink
    let action: () -> Void

    init(_ title: String, symbol: String = "arrow.right", tint: Color = .pd.ink, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    /// The arrow is the accent beside ink words, and the words' own colour
    /// beside anything quieter.
    private var arrowTint: Color {
        tint == .pd.ink ? .pd.accent : tint
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            // One Text, the arrow inline, so a link that wraps at a large
            // text size keeps its arrow after the last word instead of
            // stranding it at the end of the first line. No-break spaces, so
            // the arrow never starts a line on its own.
            Text("\(Text(title).foregroundStyle(tint))\u{00A0}\u{00A0}\(Text(Image(systemName: symbol)).foregroundStyle(arrowTint))")
                .font(Font.pd.secondary.weight(.semibold))
                .multilineTextAlignment(.leading)
                .pdHitTarget(alignment: .leading)
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(title)
    }
}

/// One thing worth knowing, and the one thing to do about it.
///
///     NoticeCard(
///         symbol: "sun.horizon",
///         text: "Get your day every morning, before you pick up the phone.",
///         linkTitle: "Set it up"
///     ) { openRoutines() }
///
/// Today's feed cards (a morning-brief setup, the latest routine result,
/// "Calendar is off in iOS Settings") and the conversation's notices ("This
/// brain can't read your calendar.") are both this: a sentence of at most ~25
/// words and one text link, on a white card. Never two links, never a
/// full-width button, never a stack of them — a screen shows at most two, and
/// the conversation one at a time.
///
/// `onDismiss` adds a ✕ for a notice that can be put away; the caller persists
/// that it was.
struct NoticeCard: View {
    var symbol: String?
    /// The glyph's colour. Ink; amber only for a notice that is a problem.
    var tint: Color = .pd.ink
    /// A short heading, for a feed card that introduces something. Most
    /// notices are one sentence and need none.
    var title: String?
    let text: String
    var linkTitle: String?
    var linkSymbol: String = "arrow.right"
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        PDCard {
            HStack(alignment: .top, spacing: PDSpacing.s) {
                if let symbol {
                    IconTile.small(
                        symbol,
                        fill: tint == .pd.ink ? .pd.fillWarm : .pd.cautionSoft,
                        tint: tint
                    )
                }
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    if let title {
                        Text(title)
                            .font(Font.pd.headline)
                            .foregroundStyle(Color.pd.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(text)
                        .font(Font.pd.secondary)
                        .foregroundStyle(title == nil ? Color.pd.ink : Color.pd.inkSecondary)
                        .modifier(PDLineSpacing(3, relativeTo: .subheadline))
                        .fixedSize(horizontal: false, vertical: true)
                    if let linkTitle, let action {
                        TextLink(linkTitle, symbol: linkSymbol, action: action)
                            // The link's 44pt target overhangs the text above
                            // it rather than pushing the card taller.
                            .padding(.vertical, -PDSpacing.xs)
                            .padding(.top, PDSpacing.xxs)
                    }
                }
                .padding(.top, symbol == nil ? 0 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let onDismiss {
                    Button {
                        Haptics.tap()
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(Font.pd.chevron)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .pdHitTarget()
                    }
                    .buttonStyle(PDPressStyle())
                    // Pulled into the card's padding so its target does not
                    // push the text in.
                    .padding(.top, -PDSpacing.s)
                    .padding(.trailing, -PDSpacing.s)
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Notice card light") {
    NoticeCardPreview()
}

#Preview("Notice card dark") {
    NoticeCardPreview().preferredColorScheme(.dark)
}

private struct NoticeCardPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.cardGap) {
                NoticeCard(
                    symbol: "sun.horizon",
                    text: "Get your day every morning, before you pick up the phone.",
                    linkTitle: "Set it up"
                ) {}
                NoticeCard(
                    symbol: "calendar",
                    tint: .pd.caution,
                    text: "Calendar is off in iOS Settings.",
                    linkTitle: "Open Settings",
                    linkSymbol: "arrow.up.right",
                    action: {},
                    onDismiss: {}
                )
                NoticeCard(
                    symbol: "tray.full",
                    title: "Overdue · 2 reminders slipped",
                    text: "Send the invoice and Book the dentist are past their dates.",
                    linkTitle: "See them"
                ) {}
                TextLink("Not now", tint: .pd.inkSecondary) {}
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}
