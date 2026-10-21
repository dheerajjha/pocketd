// `Combine` for `WaitingIndicator`'s `Timer.publish`. Implicit through SwiftUI
// until Swift 6, which warns that a stored property's type comes from a module
// this file never imported.
import Combine
import PocketdKit
import SwiftUI

/// Draws a model's reply: prose through `AttributedString`, code through
/// `CodeBlockView`.
///
/// Re-parsing on every token is deliberate and cheap — `MessageMarkdown` is a
/// single pass over a few kilobytes, and SwiftUI only re-runs this body for the
/// one message whose text changed.
struct MessageContentView: View {
    let text: String

    @State private var isReasoningExpanded = false

    var body: some View {
        let split = MessageMarkdown.splitReasoning(from: text)
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            if let reasoning = split.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasoningBlock(reasoning, isComplete: split.isComplete)
            }
            answer(of: split.answer, hadReasoning: split.reasoning != nil, isComplete: split.isComplete)
        }
    }

    /// Collapsed by default, and it stays collapsed once the answer starts.
    ///
    /// Deliberately not auto-expanding while the model thinks: a block that
    /// unfurls and then snaps shut moves the answer under the reader's eyes at
    /// the exact moment it becomes worth reading.
    ///
    /// "Show working" rather than "reasoning" or "chain of thought". It is what
    /// a teacher asks for, it is plain words, and it says what is behind the
    /// chevron without teaching anybody a term they did not need.
    @ViewBuilder
    private func reasoningBlock(_ reasoning: String, isComplete: Bool) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            Button {
                withAnimation(PDMotion.standard) { isReasoningExpanded.toggle() }
            } label: {
                HStack(spacing: PDSpacing.xs) {
                    Text(disclosureLabel(isComplete: isComplete))
                    Image(systemName: "chevron.down")
                        .font(Font.pd.tick)
                        .rotationEffect(.degrees(isReasoningExpanded ? 0 : -90))
                }
                .font(Font.pd.caption.weight(.medium))
                .foregroundStyle(Color.pd.inkSecondary)
                .padding(.horizontal, PDSpacing.s)
                .padding(.vertical, PDSpacing.xxs)
                .frame(minHeight: PDMetric.linkPillHeight + 4)
                .background(Color.pd.chip, in: Capsule(style: .continuous))
                .pdHitTarget(alignment: .leading)
            }
            .buttonStyle(PDPressStyle())
            .accessibilityLabel(isComplete ? "Show working" : "Still working")
            .accessibilityValue(isReasoningExpanded ? "Expanded" : "Collapsed")

            if isReasoningExpanded {
                Text(reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .modifier(PDLineSpacing(4, relativeTo: .subheadline))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, PDSpacing.s)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.pd.divider).frame(width: 2)
                    }
            }
        }
    }

    private func disclosureLabel(isComplete: Bool) -> String {
        if !isComplete { return "Working…" }
        return isReasoningExpanded ? "Hide working" : "Show working"
    }

    @ViewBuilder
    private func answer(of text: String, hadReasoning: Bool, isComplete: Bool) -> some View {
        let blocks = MessageMarkdown.blocks(of: text)

        if blocks.isEmpty {
            // Either nothing has arrived yet, or all that has arrived is half a
            // delimiter. Both mean the same thing to a reader — except while a
            // reasoning block is still open, where "Thinking…" above already
            // says it and a second placeholder is just noise.
            if !hadReasoning || isComplete {
                WaitingIndicator()
            }
        } else {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
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
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.ink)
                .modifier(PDLineSpacing(5, relativeTo: .body))
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            Text(inline(text, style: headingStyle(level)))
                .font(.system(headingStyle(level), weight: .semibold))
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

        case let .quote(text):
            HStack(alignment: .top, spacing: PDSpacing.xs) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.pd.divider)
                    .frame(width: 3)
                Text(inline(text))
                    .font(Font.pd.body)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .modifier(PDLineSpacing(5, relativeTo: .body))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .list(_, items):
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
                        // firstTextBaseline, not top: at accessibility sizes a
                        // top-aligned marker floats above the line it belongs to.
                        Text(item.marker)
                            .font(Font.pd.body)
                            .foregroundStyle(Color.pd.inkTertiary)
                            .monospacedDigit()
                            .fixedSize()
                        Text(inline(item.text))
                            .font(Font.pd.body)
                            .foregroundStyle(Color.pd.ink)
                            .modifier(PDLineSpacing(5, relativeTo: .body))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }

        case let .code(language, code):
            CodeBlockView(language: language, code: code)

        case .rule:
            Rectangle()
                .fill(Color.pd.divider)
                .frame(height: 1)
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

    /// Text styles, so a heading grows with the reader's text size like
    /// everything around it: 22 / 20 / 17 / 17 at the default size, the
    /// sizes this design was drawn at.
    private func headingStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: .title2
        case 2: .title3
        default: .headline
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

    private let shape = RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Code scrolls sideways instead of wrapping: a wrapped line of code
            // is a line of code that lies about where it ends, and at the
            // accessibility text sizes almost every line is too wide to fit.
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(Font.pd.code)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize()
                    .padding(.horizontal, PDSpacing.s)
                    .padding(.bottom, PDSpacing.s)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background(Color.pd.fillTile, in: shape)
        .overlay(shape.strokeBorder(Color.pd.cardStroke, lineWidth: 1))
        .sensoryFeedback(.success, trigger: copyTick)
    }

    private var header: some View {
        HStack(spacing: PDSpacing.xs) {
            MiniLabel(copied ? "Copied" : (language ?? ""), tint: copied ? .pd.positive : .pd.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(Font.pd.footnote)
                    .pdHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Color.pd.positive : Color.pd.inkSecondary)
            .accessibilityLabel(copied ? "Code copied" : language.map { "Copy \($0) code" } ?? "Copy code")
        }
        // The block's own text is left to scale as far as the reader needs it
        // to; capping the chrome around it is what keeps a label and a button
        // from filling the bubble at accessibility3.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.leading, PDSpacing.s)
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
    .pdCanvas()
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
    .pdCanvas()
    .dynamicTypeSize(.accessibility3)
}


/// What the reader looks at while a phone thinks.
///
/// It was a static "…" with two modifiers and no animation, on a screen where
/// nothing else moves for sixty to ninety seconds. That is indistinguishable
/// from a hang — and one of the testers who stared at it for forty-eight
/// seconds reported it as "the animated typing indicator" and concluded the app
/// was slow rather than frozen. Reading motion into a still glyph is exactly
/// what a person does when they need reassurance the thing is alive, and it is
/// not the app's job to make them.
///
/// So: dots that actually move, and after five seconds the elapsed count, which
/// is the difference between "this is taking a while" and "this is broken".
private struct WaitingIndicator: View {
    @State private var lit = 0
    @State private var elapsed = 0
    private let tick = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 5, height: 5)
                        .opacity(lit == index ? 1 : 0.3)
                }
            }
            if elapsed >= 5 {
                Text("\(elapsed)s")
                    .font(Font.pd.miniLabel)
                    .monospacedDigit()
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Color.pd.inkTertiary)
        .onReceive(tick) { _ in
            lit = (lit + 1) % 3
            // 0.4s a tick, so every third is a second. Counting ticks rather
            // than holding a start Date keeps this correct if the view is
            // rebuilt mid-reply, which it is, often.
            if lit == 0 { withAnimation { elapsed += 1 } }
        }
        .accessibilityLabel(elapsed >= 5 ? "Replying, \(elapsed) seconds" : "Replying")
    }
}
