import SwiftUI

/// WHAT POCKETD CAN SEE. LAST 7 NIGHTS. ABOUT.
///
/// `.caption2` monospaced (11pt at the default size), uppercased, tracked out
/// to 1.4. The mono face is doing real work: outside right-aligned values in a
/// list, this is the only place the app uses it, so a line set in it is
/// recognisable as structure before a single word is read, and it can never be
/// mistaken for content. It grows with Dynamic Type and wraps rather than
/// truncating.
///
/// Uppercasing happens here rather than in the call site's string so that the
/// accessibility label keeps the readable casing — VoiceOver reading
/// "W H A T  I T  C A N  S E E" is what happens when a shouted string is passed
/// straight through.
struct SectionLabel: View {
    let text: String
    var tint: Color = .pd.inkSecondary

    init(_ text: String, tint: Color = .pd.inkSecondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(Font.pd.label)
            .tracking(1.4)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The same idea set tighter, for an eyebrow inside a card or a tile.
struct MiniLabel: View {
    let text: String
    var tint: Color = .pd.inkSecondary

    init(_ text: String, tint: Color = .pd.inkSecondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(Font.pd.miniLabel)
            .tracking(1.2)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }
}

#Preview("Section label light") {
    SectionLabelPreview()
}

#Preview("Section label dark") {
    SectionLabelPreview().preferredColorScheme(.dark)
}

private struct SectionLabelPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.l) {
            SectionLabel("What Pocketd can see")
            SectionLabel("Today's brief")
            SectionLabel("Other devices")
            MiniLabel("Up next")
            MiniLabel("Connected", tint: .pd.positive)
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pdCanvas()
    }
}
