import SwiftUI

/// WHAT IT CAN SEE. TODAY'S BRIEF. OTHER DEVICES.
///
/// 11pt monospaced, uppercased, tracked out to 1.4. The mono face is doing real
/// work: it is the only place in the app that uses one, so a line set in it is
/// recognisable as structure before a single word is read, and it can never be
/// mistaken for content.
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
            .accessibilityLabel(text)
    }
}

/// The same idea one step smaller, for an eyebrow inside a card.
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
            SectionLabel("What it can see")
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
