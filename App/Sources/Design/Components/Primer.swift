import SwiftUI

/// "ⓘ iOS may ask next. Pocketd works either way, and you can change this in Settings."
///
/// The line that prepares somebody for an iOS permission sheet, which is the
/// screen people actually decline on: it uses words nobody has been prepared
/// for. The primer says iOS may ask next and why ("so Pocketd can…"). It
/// never names a button on iOS's sheet: App Review rejected 1.1.3 under
/// guideline 5.1.1(iv) on 24 Nov 2026 for steering people to grant access.
///
/// An accent ⓘ and a grey sentence, and no box. A filled bubble — what v2's
/// `Callout` drew here — makes a hint look like a warning, and this is help.
///
/// The text is a Markdown string so a word can be marked where it is
/// written: `Primer("iOS asks about notifications next, so Pocketd can remind you.")`. Bold
/// runs are drawn in ink and the rest in the secondary grey; nothing else in
/// Markdown is interpreted beyond the inline styles.
struct Primer: View {
    let text: AttributedString
    var symbol: String = "info.circle"
    /// The beige onboarding canvas, where the cool grey and accent are swapped
    /// for their warm pair — the same rule `PDCard(warm:)` follows.
    var warm: Bool = false

    /// - Parameter markdown: One or two sentences. Never name a button on
    ///   iOS's sheet (guideline 5.1.1(iv)).
    init(_ markdown: String, symbol: String = "info.circle", warm: Bool = false) {
        self.text = Self.styled(markdown)
        self.symbol = symbol
        self.warm = warm
    }

    /// For text built in code — a name that has to be inserted, say. Bold runs
    /// (`inlinePresentationIntent` `.stronglyEmphasized`) are inked here too.
    init(attributed: AttributedString, symbol: String = "info.circle", warm: Bool = false) {
        self.text = Self.inked(attributed)
        self.symbol = symbol
        self.warm = warm
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
            Image(systemName: symbol)
                .font(Font.pd.secondary)
                .foregroundStyle(warm ? Color.pd.accentWarm : Color.pd.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(Font.pd.secondary)
                .foregroundStyle(warm ? Color.pd.inkSecondaryWarm : Color.pd.inkSecondary)
                .modifier(PDLineSpacing(3, relativeTo: .subheadline))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Styling

    private static func styled(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let parsed = (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
        return inked(parsed)
    }

    /// Bold runs in ink — the same ink on either canvas; everything else
    /// keeps the view's grey.
    private static func inked(_ source: AttributedString) -> AttributedString {
        var text = source
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            text[run.range][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.pd.ink
        }
        return text
    }
}

#Preview("Primer light") {
    PrimerPreview()
}

#Preview("Primer dark") {
    PrimerPreview().preferredColorScheme(.dark)
}

private struct PrimerPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.l) {
            Primer("iOS may ask next. Pocketd works either way, and you can change this in Settings.")
            Primer("iOS asks about notifications next. You can change this in Settings.")
            PDCard(warm: true) {
                Primer("iOS lists each kind of health data next. Pocketd works either way.", warm: true)
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pdCanvas()
    }
}
