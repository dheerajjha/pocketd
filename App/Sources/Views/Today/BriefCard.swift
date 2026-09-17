import PocketdKit
import SwiftUI

/// The paragraph about your day, and the two things you can do to it.
///
/// One card with four states behind it — no brain, a brain arriving, a brain
/// writing, and nothing connected to write about — and in every one of them the
/// body prints something true. That is the rule this card is built around: the
/// template brief always exists, so there is no state here that shows a
/// spinner, an empty box, or an apology where the sentence should be.
struct BriefCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Owned by `TodayView`, passed in rather than made here: one synthesizer
    /// per screen, and the button has to know whether it is the thing speaking.
    let reader: ReadAloud

    @State private var caretVisible = true

    private var briefing: BriefingState { model.briefing }

    private var isStreaming: Bool { briefing.phase == .streaming }

    /// A download that is running right now, for the progress line.
    private var arriving: ModelTransfer? {
        model.visibleTransfers.first { $0.isActive }
    }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.m) {
                header
                body(for: briefing.displayText)
                extras
                actions
            }
        }
        .task(id: isStreaming) {
            guard isStreaming, !reduceMotion else {
                caretVisible = true
                return
            }
            // A caret that does not blink reads as a typo. 550ms is the rate
            // every text field on the platform uses.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(550))
                caretVisible.toggle()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
            HStack(spacing: PDSpacing.xxs) {
                SectionLabel("Today's brief")
                // Positive only when a brain actually wrote these words. The
                // template is not a degraded state and does not get a warning
                // colour for being one — it gets the quiet dot.
                Circle()
                    .fill(briefing.isModelWritten ? Color.pd.positive : Color.pd.inkTertiary)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: PDSpacing.xs)
            if let written = briefing.brief?.generatedAt {
                Text(written.formatted(.dateTime.hour().minute()))
                    .font(Font.pd.label)
                    .foregroundStyle(Color.pd.inkTertiary)
                    .monospacedDigit()
                    .accessibilityLabel("Written at \(written.formatted(.dateTime.hour().minute()))")
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for text: String) -> some View {
        if text.isEmpty {
            // The first launch, for the second EventKit takes to answer. Three
            // bars rather than a spinner: a spinner says "wait", a bar says
            // "this will fill in".
            VStack(alignment: .leading, spacing: PDSpacing.xs) {
                ForEach([1.0, 0.92, 0.55], id: \.self) { fraction in
                    Capsule()
                        .fill(Color.pd.fillTile)
                        .frame(height: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Scaled rather than measured: three bars of different
                        // lengths read as a paragraph, and a `GeometryReader`
                        // to get there would be three of them.
                        .scaleEffect(x: fraction, anchor: .leading)
                }
            }
            .pdShimmer()
            .accessibilityLabel("Writing your brief")
        } else {
            paragraph(text)
                .font(Font.pd.lead)
                .foregroundStyle(Color.pd.ink)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
        }
    }

    /// The greeting in semibold, the rest in regular, and a caret while a model
    /// is still writing.
    ///
    /// Built by concatenating `Text` rather than by stacking two views, because
    /// it is one paragraph: two `Text`s in a `VStack` break the line after the
    /// greeting on every width, which is not how the sentence reads.
    private func paragraph(_ text: String) -> Text {
        let split = Self.firstSentence(of: text)
        var line = Text(split.head).font(Font.pd.lead.weight(.semibold)) + Text(split.tail)
        if isStreaming {
            // A figure space, not an empty string, on the off beat: swapping a
            // glyph for nothing reflows the last line twice a second.
            line = line + Text(verbatim: caretVisible ? "\u{258D}" : "\u{2007}")
                .foregroundStyle(Color.pd.accent)
        }
        return line
    }

    /// Splits "Good morning, Sam. The rest of it." at the first full stop.
    ///
    /// The greeting is the one part of a brief whose shape is known in advance
    /// — every path through `BriefPrompt` opens with one — so this is a split
    /// rather than a parse. A paragraph with no full stop, which a truncated
    /// generation can be, comes back whole and unemphasised rather than half
    /// bold.
    static func firstSentence(of text: String) -> (head: String, tail: String) {
        guard let stop = text.firstIndex(of: "."), text.index(after: stop) < text.endIndex else {
            return (text, "")
        }
        let head = text[...stop]
        // The leading space belongs to the tail, so the bold run does not end
        // in one — a bold trailing space is visible at 20pt.
        let tail = text[text.index(after: stop)...]
        return (String(head), String(tail))
    }

    // MARK: - What is missing

    @ViewBuilder
    private var extras: some View {
        if case let .failed(reason) = briefing.phase {
            Callout(symbol: "exclamationmark.triangle", text: reason, tint: .pd.caution, fill: .pd.cautionSoft) {
                LinkPill(title: "Try again", symbol: "arrow.clockwise") {
                    Task { await model.refreshBrief(force: true) }
                }
            }
        } else if let arriving {
            Callout(
                symbol: "arrow.down.circle",
                text: "Your brain is on its way. Downloading · \(Self.percent(arriving.fraction))"
            )
        } else if model.loadedModelID == nil {
            Callout(symbol: "lightbulb", text: "Give it a brain and it will write this in its own words.") {
                LinkPill(title: "Choose a brain", symbol: "chevron.right") {
                    navigator.openYou(.brain)
                }
            }
        } else if BrainUpgrade.cannotReadYourDay(model) {
            // The brief itself is safe — the day is written into the prompt,
            // so no tool is needed to produce it — but every chip under this
            // card hands a question to a brain that cannot look anything up,
            // and this card is where the way out already lives.
            BrainUpgradeCallout()
        }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: PDSpacing.xs) {
            PillButton(
                title: reader.isSpeaking ? "Stop" : "Read aloud",
                symbol: reader.isSpeaking ? "stop.fill" : "speaker.wave.2",
                isOn: reader.isSpeaking
            ) {
                if reader.isSpeaking {
                    reader.stop()
                } else {
                    model.markReadAloud()
                    reader.speak(briefing.displayText)
                }
            }
            .disabled(briefing.displayText.isEmpty)

            PillButton(title: "Refresh", symbol: "arrow.clockwise") {
                Task { await model.refreshBrief(force: true) }
            }
            .disabled(briefing.isBusy)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Previews

#Preview("Brief card light") {
    BriefCardPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief
    ))
}

#Preview("Brief card dark") {
    BriefCardPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief
    ))
    .preferredColorScheme(.dark)
}

#Preview("Brief card streaming") {
    BriefCardPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief,
        phase: .streaming,
        streaming: "Good morning, Sam. Standup is at half nine and the dentist has you at half four"
    ))
}

#Preview("Brief card failed") {
    BriefCardPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief,
        phase: .failed("The brief could not be written.")
    ))
}

private struct BriefCardPreview: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.cardGap) {
                BriefCard(reader: ReadAloud())
            }
            .padding(PDSpacing.gutter)
        }
        .pdHeroWash()
        .pdCanvas()
        .environment(model)
        .environment(Navigator())
    }
}
