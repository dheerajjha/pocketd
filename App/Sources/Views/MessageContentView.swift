import SwiftUI

/// Draws a model's reply: prose through `AttributedString`, code through
/// `CodeBlockView`.
///
/// Re-parsing on every token is deliberate and cheap — `MessageMarkdown` is a
/// single pass over a few kilobytes, and SwiftUI only re-runs this body for the
/// one message whose text changed.
struct MessageContentView: View {
    let text: String

    var body: some View {
        let blocks = MessageMarkdown.blocks(of: text)

        if blocks.isEmpty {
            // Either nothing has arrived yet, or all that has arrived is half a
            // delimiter. Both mean the same thing to a reader.
            Text("…")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Replying")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
        }
    }

    @ViewBuilder
    private func view(for block: MessageBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(inline(text))
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            Text(inline(text, style: headingStyle(level)))
                .font(.system(headingStyle(level), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(inline(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .list(_, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // firstTextBaseline, not top: at accessibility sizes a
                        // top-aligned marker floats above the line it belongs to.
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                        Text(inline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }

        case let .code(language, code):
            CodeBlockView(language: language, code: code)

        case .rule:
            Divider()
        }
    }

    private func inline(_ markdown: String, style: Font.TextStyle = .body) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            // .full parses block syntax into presentation intents that Text
            // drops, taking the line breaks with them; the inline-only mode
            // that preserves whitespace is the one that leaves a paragraph
            // looking like a paragraph.
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let source = MessageMarkdown.closingUnfinishedCode(markdown)
        var attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(markdown)

        // Bold, italic and links come out of the parse already carrying what
        // Text needs. Code does not, and a span that reads as prose is a span
        // the reader has to guess at, so it is given the font here rather than
        // left to whatever Text decides to do with a presentation intent. The
        // size follows the block it sits in, so code in a heading stays a
        // heading.
        var monospaced = AttributeContainer()
        monospaced[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(style, design: .monospaced)
        let spans = attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for span in spans {
            attributed[span].mergeAttributes(monospaced)
        }
        return attributed
    }

    private func headingStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }
}

/// A fenced code block, with the one control a chat with a coding model needs
/// most sitting in the open rather than behind a long press.
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false
    @State private var copyTick = 0

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Code scrolls sideways instead of wrapping: a wrapped line of code
            // is a line of code that lies about where it ends, and at the
            // accessibility text sizes almost every line is too wide to fit.
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.footnote, design: .monospaced))
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background(Color(.tertiarySystemBackground), in: shape)
        .overlay(shape.strokeBorder(Color.secondary.opacity(0.25)))
        .sensoryFeedback(.success, trigger: copyTick)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(copied ? "COPIED" : (language?.uppercased() ?? ""))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .frame(minWidth: 44, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .accessibilityLabel(copied ? "Code copied" : language.map { "Copy \($0) code" } ?? "Copy code")
        }
        // The block's own text is left to scale as far as the reader needs it
        // to; capping the chrome around it is what keeps a label and a button
        // from filling the bubble at accessibility3.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.top, 2)
    }

    private func copy() {
        UIPasteboard.general.string = code
        copied = true
        copyTick += 1
        let tick = copyTick
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            // Guarded so a second copy while the first is still counting down
            // does not clear the confirmation out from under it.
            if copyTick == tick { copied = false }
        }
    }
}

#Preview("Blocks") {
    ScrollView {
        MessageContentView(text: """
        # Reading a file

        Use `String(contentsOf:)`, but **check the encoding** — the *default* is UTF-8.

        1. Open the file
        2. Read it
           watch for a BOM

        - Foundation ships this
          - and it throws

        > It throws on invalid UTF-8, which is what you want.

        ```swift
        let text = try String(contentsOf: url, encoding: .utf8)  // this line is deliberately long enough to need sideways scrolling
        ```

        ---

        ```
        no language on this one
        ```
        """)
        .padding()
    }
}

#Preview("Streaming, at accessibility3") {
    ScrollView {
        MessageContentView(text: """
        Here is the fix:

        ```swift
        func load() throws -> String {
            try String(contentsOf: url, encoding
        """)
        .padding()
    }
    .dynamicTypeSize(.accessibility3)
}
