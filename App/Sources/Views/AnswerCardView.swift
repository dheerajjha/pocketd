import SwiftUI
import PocketdKit

/// Draws what a tool found.
///
/// Everything here is a rendering of `AnswerCard`, which was built from a tool
/// payload and never from a token the model produced — so nothing on screen can
/// disagree with what the phone actually read. The model's sentence is the
/// bubble above; this is the part that is true.
///
/// Two layout rules run through the whole file, both of them about text that
/// does not fit. Anything in a right-hand track wraps and shrinks rather than
/// truncating, and at accessibility sizes those tracks collapse into stacked
/// rows instead of fighting for a width that is no longer there. The specific
/// failure being designed against is a metric tile narrow enough to break
/// "Conversational" across lines as "Convers/ational", which no amount of
/// careful copy prevents and one `minimumScaleFactor` does.
struct AnswerCardView: View {
    let card: AnswerCard

    @Environment(\.dynamicTypeSize) private var typeSize

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let lede = card.lede {
                Text(lede)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(card.sections.enumerated()), id: \.offset) { _, section in
                view(for: section)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: shape)
        .overlay(shape.strokeBorder(Color(.separator).opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title.map { "\($0), from your device" } ?? "From your device")
    }

    @ViewBuilder
    private var header: some View {
        if card.title != nil || card.symbol != nil {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let symbol = card.symbol {
                    Image(systemName: symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(7)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        // Decoration: the title beside it already says what
                        // this is, and a second announcement of "calendar" is
                        // noise in the rotor.
                        .accessibilityHidden(true)
                }
                if let title = card.title {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func view(for section: AnswerCard.Section) -> some View {
        switch section {
        case .facts(let body):
            block(body.eyebrow) {
                rows(body.rows.indices) { index in
                    fact(body.rows[index])
                }
            }

        case .list(let body):
            block(body.eyebrow) {
                rows(body.items.indices) { index in
                    item(body.items[index])
                }
            }

        case .metrics(let body):
            block(body.eyebrow) {
                metrics(body.tiles)
            }

        case .steps(let body):
            block(body.eyebrow) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(body.steps.enumerated()), id: \.offset) { index, step in
                        self.step(step, number: index + 1)
                    }
                }
            }

        case .note(let body):
            note(body)

        case .empty(let body):
            empty(body)
        }
    }

    // MARK: - Blocks

    /// An eyebrow and the thing it labels.
    @ViewBuilder
    private func block(_ eyebrow: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let eyebrow {
                Text(eyebrow)
                    .font(.caption2.weight(.semibold))
                    .monospaced()
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    /// Hairline-separated rows, which is how a native list reads and how the
    /// eye finds the row it wants without a border around every one.
    @ViewBuilder
    private func rows(_ indices: Range<Int>, @ViewBuilder row: @escaping (Int) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(indices), id: \.self) { index in
                if index != indices.lowerBound {
                    Divider().padding(.vertical, 8)
                }
                row(index)
            }
        }
    }

    private func fact(_ row: AnswerCard.Fact) -> some View {
        track(
            leading: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let value = row.value {
                        Text(value)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            },
            accent: row.accent
        )
        .accessibilityElement(children: .combine)
    }

    private func item(_ item: AnswerCard.Item) -> some View {
        track(
            leading: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let symbol = item.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 7))
                            .foregroundStyle(Color.accentColor)
                            // firstTextBaseline keeps a marker on the line it
                            // belongs to; at accessibility sizes a top-aligned
                            // one floats above its own text.
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            },
            accent: item.accent
        )
        .accessibilityElement(children: .combine)
    }

    /// The one shape every row shares: content on the left, a short value on
    /// the right — until the right-hand track stops being affordable, at which
    /// point it goes underneath rather than squeezing the content to nothing.
    @ViewBuilder
    private func track(@ViewBuilder leading: () -> some View, accent: String?) -> some View {
        if let accent, !typeSize.isAccessibilitySize {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                leading()
                    .frame(maxWidth: .infinity, alignment: .leading)
                accentText(accent)
            }
        } else if let accent {
            VStack(alignment: .leading, spacing: 4) {
                leading()
                accentText(accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accentText(_ accent: String) -> some View {
        Text(accent)
            .font(.footnote.weight(.semibold))
            .monospaced()
            .foregroundStyle(Color.accentColor)
            .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            // Wrap, then shrink, and never truncate: an accent is a time or a
            // count, and half of either is worse than a smaller whole one.
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    /// Tiles that reflow rather than compress.
    ///
    /// `.adaptive` drops to fewer columns as the width runs out, and the
    /// minimum grows at accessibility sizes so the strip becomes a single
    /// column instead of four unreadable ones. The scale factors are what stop
    /// a long single word breaking mid-word inside a tile it nearly fits.
    private func metrics(_ tiles: [AnswerCard.Tile]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 220 : 100), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(tile.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func step(_ step: AnswerCard.Step, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = step.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(step.title). \(step.detail ?? "")")
    }

    private func note(_ note: AnswerCard.Note) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: note.symbol ?? defaultSymbol(for: note.tone))
                .font(.footnote)
                .foregroundStyle(colour(for: note.tone))
                .accessibilityHidden(true)
            Text(note.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            colour(for: note.tone).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    /// Nothing found, drawn.
    ///
    /// Deliberately not a smaller, greyer version of a row. An answer with no
    /// data in it is the one a reader is most likely to mistrust, so it gets
    /// the same weight as one that found something.
    private func empty(_ state: AnswerCard.Empty) -> some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol ?? "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(state.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func colour(for tone: AnswerCard.Tone) -> Color {
        switch tone {
        case .info: Color.accentColor
        case .caution: Color.orange
        }
    }

    private func defaultSymbol(for tone: AnswerCard.Tone) -> String {
        switch tone {
        case .info: "info.circle"
        case .caution: "exclamationmark.triangle"
        }
    }
}

// MARK: - Previews

private let sampleEvents = AnswerCard(
    source: "get_calendar_events",
    symbol: "calendar",
    title: "Today",
    sections: [
        .list(AnswerCard.Items(eyebrow: "3 events", items: [
            AnswerCard.Item(
                text: "Design review with the platform team",
                detail: "Thu 11 Sep, 14:30 – 15:30 · Conference room B",
                symbol: "circle.fill"
            ),
            AnswerCard.Item(text: "Offsite", detail: "Thu 11 Sep", accent: "All day", symbol: "circle.fill"),
            AnswerCard.Item(text: "Dentist", detail: "Thu 11 Sep, 17:15 – 18:00", symbol: "circle.fill")
        ])),
        .note(AnswerCard.Note(text: "Only the first 20 events are listed; there are more.", symbol: "ellipsis"))
    ]
)

#Preview("Events") {
    ScrollView {
        AnswerCardView(card: sampleEvents).padding()
    }
}

#Preview("Every section, and the words that break") {
    ScrollView {
        VStack(spacing: 12) {
            AnswerCardView(card: AnswerCard(
                symbol: "chart.bar",
                title: "This week",
                sections: [
                    // "Conversational" is the exact caption a competitor's own
                    // metric strip breaks as "Convers/ational". It stays here
                    // as the thing this layout has to survive.
                    .metrics(AnswerCard.Metrics(eyebrow: "At a glance", tiles: [
                        AnswerCard.Tile(value: "12", caption: "Meetings"),
                        AnswerCard.Tile(value: "4h 20m", caption: "Conversational"),
                        AnswerCard.Tile(value: "3", caption: "Free afternoons")
                    ])),
                    .facts(AnswerCard.Facts(eyebrow: "Where to find it", rows: [
                        AnswerCard.Fact(
                            label: "Address",
                            value: "Shop 20, Gyandeep Apartments, Sector 3–4, Vashi",
                            accent: "Vashi"
                        ),
                        AnswerCard.Fact(label: "Closed", value: "Monday", accent: "Monday")
                    ])),
                    .steps(AnswerCard.Steps(eyebrow: "To turn it on", steps: [
                        AnswerCard.Step(title: "Open Settings", detail: "Privacy & Security"),
                        AnswerCard.Step(title: "Tap Calendars, then Pocketd"),
                        AnswerCard.Step(title: "Choose Full Access")
                    ])),
                    .note(AnswerCard.Note(
                        text: "Pocketd can only add to your calendar, not read it.",
                        symbol: "lock",
                        tone: .caution
                    ))
                ]
            ))
            AnswerCardView(card: .nothing("No events next week.", title: "Next week", symbol: "calendar"))
        }
        .padding()
    }
}

#Preview("At accessibility3") {
    ScrollView {
        VStack(spacing: 12) {
            AnswerCardView(card: sampleEvents)
            AnswerCardView(card: AnswerCard(
                symbol: "chart.bar",
                title: "This week",
                sections: [.metrics(AnswerCard.Metrics(tiles: [
                    AnswerCard.Tile(value: "12", caption: "Meetings"),
                    AnswerCard.Tile(value: "4h 20m", caption: "Conversational")
                ]))]
            ))
        }
        .padding()
    }
    .dynamicTypeSize(.accessibility3)
}
