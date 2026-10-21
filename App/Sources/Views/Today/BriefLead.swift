import PocketdKit
import SwiftUI

/// The brief, on the canvas: today in a few true sentences, and a quiet way to
/// hear them.
///
/// No card. The paragraph is the page's lead, the way a newspaper's first
/// paragraph is not in a box: a card around it was one more border saying
/// "this is content" on a screen made of content, and the tiles under it are
/// cards already. No eyebrow and no time stamp either — "TODAY'S BRIEF ●
/// 11:57 AM" was two facts about the paragraph and none about the day.
///
/// The greeting is grey and the facts after it are ink, so the eye lands on
/// "Lunch at The Arches", not on "Good morning". A paragraph whose opening is
/// not the template's greeting — a brain's own wording — is ink throughout:
/// greying a first sentence nobody recognised as a greeting could grey a fact.
///
/// While a brain rewrites it, the paragraph on screen stays where it is — the
/// template, or what was written last — and the line under it says "Writing…".
/// The new words replace it in one crossfade when they are finished, instead
/// of streaming in under the reader's eyes or shimmering over an empty space.
struct BriefLead: View {
    let text: String
    /// The name the greeting was written with, so the greeting can be found.
    let name: String?
    /// "Writing…", "Getting ready · about 2 min", or nothing.
    let status: String?
    let reader: ReadAloud
    /// The speaker was used, for the count of how often it is.
    var onReadAloud: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            paragraph
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The paragraph

    private var paragraph: some View {
        let parts = Self.split(text, name: name)
        return Text("\(Text(parts.greeting).foregroundStyle(Color.pd.inkSecondary))\(Text(parts.rest))")
            .pdLead()
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : PDMotion.enter, value: text)
            .textSelection(.enabled)
            .accessibilityLabel(text)
    }

    /// "Good morning, Sam." and the rest, or no greeting and the whole text.
    ///
    /// Matched against the greetings the template writes — `TimeOfDayKind`'s
    /// three, with and without the name — rather than split at the first full
    /// stop, which would grey "Good morning, Dr." and leave "Sam." in ink.
    static func split(_ text: String, name: String?) -> (greeting: String, rest: String) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for kind in TimeOfDayKind.allCases {
            var openings = ["\(kind.greeting)."]
            if !trimmedName.isEmpty {
                openings.insert("\(kind.greeting), \(trimmedName).", at: 0)
            }
            for opening in openings where text.hasPrefix(opening) {
                return (opening, String(text.dropFirst(opening.count)))
            }
        }
        return ("", text)
    }

    // MARK: - Read aloud, and what is happening to the paragraph

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: PDSpacing.s) {
                readAloud
                Spacer(minLength: 0)
                statusText
            }
            VStack(alignment: .leading, spacing: 0) {
                readAloud
                statusText
            }
        }
    }

    /// A quiet link rather than a pill: it is the paragraph's own control,
    /// and a button-shaped thing here would be the loudest object on a screen
    /// that has none.
    private var readAloud: some View {
        Button {
            Haptics.tap()
            if reader.isSpeaking {
                reader.stop()
            } else {
                onReadAloud()
                reader.speak(text)
            }
        } label: {
            HStack(spacing: PDSpacing.xs) {
                Image(systemName: reader.isSpeaking ? "stop.fill" : "speaker.wave.2")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.accent)
                    .contentTransition(.symbolEffect(.replace))
                Text(reader.isSpeaking ? "Stop" : "Read aloud")
                    .font(Font.pd.secondary.weight(.semibold))
                    .foregroundStyle(Color.pd.inkSecondary)
            }
            .pdHitTarget(alignment: .leading)
        }
        .buttonStyle(PDPressStyle())
        .disabled(text.isEmpty)
        .accessibilityLabel(reader.isSpeaking ? "Stop reading" : "Read your brief aloud")
    }

    @ViewBuilder
    private var statusText: some View {
        if let status {
            Text(status)
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Previews

#Preview("Brief lead light") {
    BriefLeadPreview()
}

#Preview("Brief lead dark") {
    BriefLeadPreview().preferredColorScheme(.dark)
}

#Preview("Brief lead AX") {
    BriefLeadPreview().dynamicTypeSize(.accessibility3)
}

private struct BriefLeadPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.xl) {
                BriefLead(
                    text: TodayPreviewData.templateBrief.text,
                    name: "Sam",
                    status: nil,
                    reader: ReadAloud()
                )
                BriefLead(
                    text: TodayPreviewData.templateBrief.text,
                    name: "Sam",
                    status: "Writing…",
                    reader: ReadAloud()
                )
                BriefLead(
                    text: "Sam, the dentist moved to 4:30 PM, so lunch at The Arches is the only thing before it.",
                    name: "Sam",
                    status: "Getting ready · about 2 min",
                    reader: ReadAloud()
                )
            }
            .padding(PDSpacing.gutter)
        }
        .pdHeroWash()
        .pdCanvas()
    }
}
