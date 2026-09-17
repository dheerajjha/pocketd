import PocketdKit
import SwiftUI

/// Draws what a tool found.
///
/// Everything here is a rendering of `AnswerCard`, which was built from a tool
/// payload and never from a token the model produced — so nothing on screen can
/// disagree with what the phone actually read. The model's sentence is the card
/// above; this is the part that is true.
///
/// Two layout rules run through the whole file, both of them about text that
/// does not fit. Anything in a right-hand track wraps and shrinks rather than
/// truncating, and at accessibility sizes those tracks collapse into stacked
/// rows instead of fighting for a width that is no longer there. The specific
/// failure being designed against is a metric tile narrow enough to break
/// "Conversational" across lines as "Convers/ational", which no amount of
/// careful copy prevents and one `minimumScaleFactor` does.
///
/// Two of the shapes below are live rather than drawn. A reminder row carries a
/// circle that ticks it off, and a card that reports a write carries an Undo for
/// five minutes. Both go through `AppModel`, never EventKit directly — see
/// `AppModel+Reminders`.
struct AnswerCardView: View {
    let card: AnswerCard

    /// Ticking a reminder off from its own row. `nil` in a preview or anywhere
    /// the transcript is being read rather than used, which is what removes the
    /// circles rather than leaving dead ones on screen.
    var onCompleteReminder: ((String) -> Void)?

    /// The write this card reports, while it can still be taken back.
    var undo: UndoOffer?

    /// What an Undo needs to know: when it stops being offered, and what it
    /// does. The decision about *whether* there is one belongs to `WriteUndo`,
    /// not to a view.
    struct UndoOffer {
        let expiresAt: Date
        let action: () -> Void
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Titles ticked off in this view's lifetime.
    ///
    /// View-local on purpose. The card is a rendering of a payload that was true
    /// when the tool ran, and re-reading EventKit to redraw it would make the
    /// transcript disagree with itself as the day went on. What a tap changes is
    /// the reminders list; what it changes *here* is only the mark beside the
    /// row the finger landed on.
    @State private var completed: Set<String> = []

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.m) {
                header
                lede
                sections
                undoRow
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title.map { "\($0), from your device" } ?? "From your device")
    }

    // MARK: - Head

    /// The mono line, the icon tile, and — only where there is no eyebrow to
    /// carry it — the title.
    ///
    /// The title folds into the eyebrow when the first block has one, because
    /// "Tomorrow" over "3 EVENTS" is the same fact written twice and the
    /// reference sets it as one line: `TOMORROW · 3 EVENTS`.
    @ViewBuilder
    private var header: some View {
        let head = headline
        if head.eyebrow != nil || head.title != nil || card.symbol != nil {
            HStack(spacing: PDSpacing.s) {
                if let symbol = card.symbol {
                    // Decoration: the line beside it already says what this is,
                    // and a second announcement of "calendar" is noise in the
                    // rotor.
                    IconTile.small(symbol)
                }
                if let eyebrow = head.eyebrow {
                    SectionLabel(eyebrow)
                } else if let title = head.title {
                    Text(title)
                        .font(Font.pd.headline)
                        .foregroundStyle(Color.pd.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var headline: (eyebrow: String?, title: String?) {
        let first = card.sections.first.flatMap(Self.eyebrow(of:))
        guard let title = card.title else { return (first, nil) }
        guard let first else { return (nil, title) }
        return ("\(title) · \(first)", nil)
    }

    /// One short sentence — the only part of a card a model is trusted with, and
    /// on a write card the whole answer.
    @ViewBuilder
    private var lede: some View {
        if let text = card.lede, !text.isEmpty {
            Text(text)
                .font(Font.pd.lead)
                .foregroundStyle(Color.pd.ink)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Blocks

    @ViewBuilder
    private var sections: some View {
        // Nothing at all rather than an empty stack: a `VStack` with no children
        // is still a view, and the enclosing stack puts its 16pt gap around it —
        // which is the dead band under the sentence on a write card, whose only
        // content is a lede.
        if !card.sections.isEmpty {
            // The first block's eyebrow is already in the header when the card
            // had a title to fold it into; drawing it again is the same words
            // twice.
            let foldedFirst = headline.eyebrow != nil
            VStack(alignment: .leading, spacing: PDSpacing.m) {
                ForEach(Array(card.sections.enumerated()), id: \.offset) { index, section in
                    block(section, showsEyebrow: !(index == 0 && foldedFirst))
                }
            }
        }
    }

    @ViewBuilder
    private func block(_ section: AnswerCard.Section, showsEyebrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            if showsEyebrow, let eyebrow = Self.eyebrow(of: section) {
                SectionLabel(eyebrow)
            }
            content(of: section)
        }
    }

    @ViewBuilder
    private func content(of section: AnswerCard.Section) -> some View {
        switch section {
        case .facts(let body):
            ruled(body.rows.indices) { fact(body.rows[$0]) }
        case .list(let body):
            list(body.items)
        case .metrics(let body):
            metrics(body.tiles)
        case .steps(let body):
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                ForEach(Array(body.steps.enumerated()), id: \.offset) { index, step in
                    self.step(step, number: index + 1)
                }
            }
        case .note(let body):
            Callout(
                symbol: body.symbol ?? Self.defaultSymbol(for: body.tone),
                text: body.text,
                tint: Self.colour(for: body.tone),
                fill: body.tone == .caution ? .pd.cautionSoft : .pd.callout
            )
        case .empty(let body):
            // Nothing found, drawn. Deliberately not a smaller, greyer version
            // of a row: an answer with no data in it is the one a reader is most
            // likely to mistrust, so it gets a shape of its own rather than an
            // absence.
            Callout(
                symbol: body.symbol ?? "tray",
                text: body.text,
                tint: .pd.inkSecondary,
                fill: .pd.fillTile
            )
        }
    }

    /// Hairline-separated rows, which is how the eye finds the row it wants
    /// without a border around every one.
    @ViewBuilder
    private func ruled(_ indices: Range<Int>, @ViewBuilder row: @escaping (Int) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(indices), id: \.self) { index in
                if index != indices.lowerBound {
                    Rectangle()
                        .fill(Color.pd.divider)
                        .frame(height: 1)
                        .padding(.vertical, PDSpacing.s)
                }
                row(index)
            }
        }
    }

    // MARK: - Lists, three ways

    /// A list of the same thing, drawn as whatever that thing is.
    ///
    /// The tool that produced the card decides the shape, not the section:
    /// events are a day and want a rail with times on it, reminders are a list
    /// of things to do and want something to tick, and anything else is a row.
    @ViewBuilder
    private func list(_ items: [AnswerCard.Item]) -> some View {
        switch card.source {
        case PersonalDataToolNames.calendar:
            EventRow.timeline(of: items)
        case PersonalDataToolNames.reminders:
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    checkRow(item)
                }
            }
        default:
            ruled(items.indices) { plainItem(items[$0]) }
        }
    }

    /// A reminder, with the circle that ticks it off.
    private func checkRow(_ item: AnswerCard.Item) -> some View {
        let isDone = completed.contains(item.text)
        return HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
            circle(for: item.text, isDone: isDone)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(isDone ? Color.pd.inkTertiary : Color.pd.ink)
                    .strikethrough(isDone, color: Color.pd.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let accent = item.accent {
                accentText(accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func circle(for title: String, isDone: Bool) -> some View {
        if let onCompleteReminder {
            Button {
                guard !isDone else { return }
                Haptics.success()
                // Optimistic, and it stays optimistic. What a failure produces
                // is a sentence worth reading — an ambiguous title, a permission
                // that is off — and that belongs in the toast the screen raises,
                // not as a third line under a row.
                completed.insert(title)
                onCompleteReminder(title)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(isDone ? Color.pd.positive : Color.pd.inkTertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(PDPressStyle())
            .disabled(isDone)
            .accessibilityLabel(isDone ? "Done" : "Tick off \(title)")
        } else {
            Image(systemName: "circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color.pd.inkTertiary)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
        }
    }

    private func plainItem(_ item: AnswerCard.Item) -> some View {
        track(
            leading: {
                HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
                    if let symbol = item.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.pd.accent)
                            // firstTextBaseline keeps a marker on the line it
                            // belongs to; at accessibility sizes a top-aligned
                            // one floats above its own text.
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text)
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(Font.pd.secondary)
                                .foregroundStyle(Color.pd.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            },
            accent: item.accent
        )
        .accessibilityElement(children: .combine)
    }

    private func fact(_ row: AnswerCard.Fact) -> some View {
        track(
            leading: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let value = row.value {
                        Text(value)
                            .font(Font.pd.secondary)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            },
            accent: row.accent
        )
        .accessibilityElement(children: .combine)
    }

    /// The one shape every row shares: content on the left, a short value on
    /// the right — until the right-hand track stops being affordable, at which
    /// point it goes underneath rather than squeezing the content to nothing.
    @ViewBuilder
    private func track(@ViewBuilder leading: () -> some View, accent: String?) -> some View {
        if let accent, !typeSize.isAccessibilitySize {
            HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                leading()
                    .frame(maxWidth: .infinity, alignment: .leading)
                accentText(accent)
            }
        } else if let accent {
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
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
            .font(Font.pd.monoValue)
            .foregroundStyle(Color.pd.accent)
            .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            // Wrap, then shrink, and never truncate: an accent is a time or a
            // count, and half of either is worse than a smaller whole one.
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    /// Numbers that deserve size, two across.
    ///
    /// `.adaptive` drops to one column as the width runs out, and the minimum
    /// grows at accessibility sizes so the strip becomes a single column instead
    /// of two unreadable ones. `StatTile` shrinks rather than breaking a long
    /// figure mid-word.
    private func metrics(_ tiles: [AnswerCard.Tile]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 130), spacing: PDSpacing.tileGap)],
            alignment: .leading,
            spacing: PDSpacing.tileGap
        ) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                StatTile(label: tile.caption, value: tile.value)
            }
        }
    }

    private func step(_ step: AnswerCard.Step, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
            Text("\(number)")
                .font(Font.pd.monoValue)
                .foregroundStyle(Color.pd.accent)
                .frame(minWidth: 20, alignment: .trailing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = step.detail {
                    Text(detail)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(step.title). \(step.detail ?? "")")
    }

    // MARK: - Undo

    @ViewBuilder
    private var undoRow: some View {
        if let undo {
            UndoPill(expiresAt: undo.expiresAt, action: undo.action)
        }
    }

    // MARK: - Small decisions

    private static func eyebrow(of section: AnswerCard.Section) -> String? {
        switch section {
        case .facts(let body): body.eyebrow
        case .list(let body): body.eyebrow
        case .metrics(let body): body.eyebrow
        case .steps(let body): body.eyebrow
        case .note, .empty: nil
        }
    }

    private static func colour(for tone: AnswerCard.Tone) -> Color {
        switch tone {
        case .info: .pd.accent
        case .caution: .pd.caution
        }
    }

    private static func defaultSymbol(for tone: AnswerCard.Tone) -> String {
        switch tone {
        case .info: "info.circle"
        case .caution: "exclamationmark.triangle"
        }
    }
}

// MARK: - Undo

/// "Undo", for as long as undoing is a correction rather than a surprise.
///
/// It disappears by itself rather than by a timer somewhere else deciding to
/// redraw the screen: one sleep per pill, woken exactly when the window closes.
/// The five minutes is `WriteUndo.window`, which is also what stops the action
/// working — so a pill that somehow outlived its sleep would still be refused
/// rather than deleting something an hour later.
private struct UndoPill: View {
    let expiresAt: Date
    let action: () -> Void

    @State private var expired = false

    var body: some View {
        Group {
            if !expired {
                PillButton(title: "Undo", symbol: "arrow.uturn.backward") {
                    action()
                }
                .transition(.opacity)
            }
        }
        .task(id: expiresAt) {
            let remaining = expiresAt.timeIntervalSinceNow
            expired = remaining <= 0
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            withAnimation(PDMotion.gentle) { expired = true }
        }
    }
}

// MARK: - Events, as a day

/// Turning calendar rows into a rail with times on it.
///
/// `AnswerCardBuilders.calendar` writes each row as a title plus a detail of
/// `"<when> · <location>"`, where `when` came from `AnswerCard.span` — something
/// like `Fri, 18 Sep at 2:30 PM – 3:30 PM`. What the rail needs out of that is
/// the clock and nothing else.
///
/// Nothing here parses a date, and that is the whole design. `when` was written
/// by `Date.FormatStyle` in the user's own locale, where the piece between the
/// day and the hour is "at" in English, a comma in German, nothing at all in
/// Japanese and a different word again in Hindi — so splitting on any of them is
/// a bug in every locale but one. This finds the clock instead, which is the one
/// token whose shape is the same everywhere digits are: one or two digits, a
/// separator, two digits, and sometimes AM or PM.
///
/// The date in front of the clock is then dropped only when every row carries
/// the same one, which is exactly when it is noise — a card headed "Tomorrow"
/// repeating "Fri, 18 Sep" on all three rows. On a card that spans days each row
/// keeps its own `when` underneath, because there the date is the answer.
///
/// Where no clock is found — an all-day event, or a locale whose digits this
/// scanner does not know — the row keeps its original detail whole. The worst
/// case is a row that reads exactly as it did before.
enum EventRow {

    static func timeline(of items: [AnswerCard.Item]) -> some View {
        let rows = items.map(parse(_:))
        let shared = sharedPrefix(of: rows)
        let built = rows.enumerated().map { index, row in
            TimelineItem(
                id: stableID(index),
                time: row.time ?? "",
                title: row.title,
                detail: detail(of: row, droppingPrefix: shared)
            )
        }
        return TimelineList(items: built, timeWidth: width(of: built))
    }

    /// A row's identity, from its position and nothing else.
    ///
    /// `TimelineItem` mints a fresh `UUID` when it is built, and these are built
    /// inside a view body — so a redraw would hand every row a new identity and
    /// `ForEach` would tear the whole rail down and put it back. That happens on
    /// every token while an answer streams under a card.
    static func stableID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID()
    }

    // MARK: One row

    struct Row {
        var title: String
        /// When it starts, and only that. One line, because `TimelineList` sizes
        /// a row from its content column — a two-line time overflows a one-line
        /// row and runs straight into the next row's time.
        var time: String?
        /// When it ends, as a clause for underneath. `nil` where the row carries
        /// no second clock, or where the two are the same.
        var endClause: String?
        /// Everything in `when` before the first clock, verbatim.
        var datePrefix: String?
        /// `when` whole, for the rows that have to keep it.
        var when: String?
        var location: String?
    }

    static func parse(_ item: AnswerCard.Item) -> Row {
        // The accent is the builder's own word for a row with no clock at all.
        let pieces = (item.detail ?? "").components(separatedBy: " · ")
        let when = pieces.first.flatMap { $0.isEmpty ? nil : $0 }
        let place = pieces.dropFirst().joined(separator: " · ")
        let location = place.isEmpty ? nil : place

        guard let when else {
            return Row(title: item.text, time: item.accent, location: location)
        }

        let clocks = clockRanges(in: when)
        guard let first = clocks.first else {
            return Row(title: item.text, time: item.accent, when: when, location: location)
        }
        let start = String(when[first])
        let finish = clocks.count > 1 ? String(when[clocks[1]]) : nil
        return Row(
            title: item.text,
            time: item.accent ?? start,
            // Plain words rather than a dash, because a dash on its own line
            // under a title reads as a bullet that lost its text.
            endClause: finish.flatMap { $0 == start ? nil : "until \($0)" },
            datePrefix: String(when[when.startIndex..<first.lowerBound]),
            when: when,
            location: location
        )
    }

    /// The date every clocked row starts with, when they all start with the same
    /// one. Rows with no clock are left out of the vote: an all-day event's
    /// detail is a date and nothing else, and counting it would always split
    /// the decision.
    static func sharedPrefix(of rows: [Row]) -> String? {
        let prefixes = Set(rows.compactMap(\.datePrefix))
        guard prefixes.count == 1, let only = prefixes.first, !only.isEmpty else { return nil }
        return only
    }

    static func detail(of row: Row, droppingPrefix shared: String?) -> String? {
        let date: String?
        if row.datePrefix == nil {
            // No clock was found, so there is nothing to have cut: the detail is
            // whatever the builder wrote.
            date = row.when
        } else {
            // The date is dropped only where every row repeats the same one.
            // Where they differ it is the answer, so the whole `when` stays and
            // the end clause is already inside it.
            date = shared == nil ? row.when : nil
        }
        let end = date == row.when ? nil : row.endClause
        let parts = [date, end, row.location].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Wide enough for the longest clock line, and no wider.
    ///
    /// `2:30 PM` is half again as long as `14:30`, and a column sized for the
    /// shorter one wraps every row in a twelve-hour locale. Measured in
    /// characters because the column is monospaced, which is the one case where
    /// counting characters is the same as measuring.
    static func width(of items: [TimelineItem]) -> CGFloat {
        let longest = items
            .flatMap { $0.time.components(separatedBy: "\n") }
            .map(\.count)
            .max() ?? 5
        // 9.7pt per character at the 16pt monospaced face `TimelineList` uses,
        // clamped so one odd string cannot eat the row.
        return CGFloat(min(max(longest, 5), 9)) * 9.7 + 4
    }

    // MARK: Finding a clock

    /// Every clock token in `text`, in order.
    ///
    /// Hand-rolled rather than a regex so there is no pattern to get subtly
    /// wrong and no `Regex` to make `Sendable`. A token is: a run of one or two
    /// digits not preceded by a digit, then `:` or `.`, then exactly two digits,
    /// then — only if it is genuinely there — a space and an AM or PM marker.
    static func clockRanges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var index = text.startIndex
        var previousWasDigit = false

        while index < text.endIndex {
            let character = text[index]
            if character.isNumber, !previousWasDigit, let range = clock(at: index, in: text) {
                found.append(range)
                // Resume past the token, so its own minutes cannot start a
                // second match.
                index = range.upperBound
                previousWasDigit = false
                continue
            }
            previousWasDigit = character.isNumber
            index = text.index(after: index)
        }
        return found
    }

    private static func clock(at start: String.Index, in text: String) -> Range<String.Index>? {
        var cursor = start
        var digits = 0
        while cursor < text.endIndex, text[cursor].isNumber, digits < 2 {
            cursor = text.index(after: cursor)
            digits += 1
        }
        guard digits >= 1, cursor < text.endIndex, text[cursor] == ":" || text[cursor] == "." else { return nil }
        cursor = text.index(after: cursor)

        var minuteDigits = 0
        while cursor < text.endIndex, text[cursor].isNumber, minuteDigits < 2 {
            cursor = text.index(after: cursor)
            minuteDigits += 1
        }
        guard minuteDigits == 2 else { return nil }
        // A third digit means this was not a clock — a version number, say.
        if cursor < text.endIndex, text[cursor].isNumber { return nil }

        return start..<(meridiemEnd(after: cursor, in: text) ?? cursor)
    }

    /// The end of an `AM`/`PM` marker sitting just after a clock, or `nil`.
    ///
    /// Only ASCII AM and PM, with or without the stops and the space. A locale
    /// that writes something else simply keeps its clock without one, which is
    /// what a 24-hour locale does anyway.
    private static func meridiemEnd(after cursor: String.Index, in text: String) -> String.Index? {
        var scan = cursor
        if scan < text.endIndex, text[scan] == " " || text[scan] == "\u{202F}" || text[scan] == "\u{00A0}" {
            scan = text.index(after: scan)
        }
        var letters = ""
        var end = scan
        while end < text.endIndex, letters.count < 4 {
            let character = text[end]
            if character.isLetter { letters.append(character) } else if character != "." { break }
            end = text.index(after: end)
        }
        let marker = letters.uppercased()
        guard marker == "AM" || marker == "PM" else { return nil }
        return end
    }
}

// MARK: - Previews

private let sampleEvents = AnswerCard(
    source: "calendar",
    symbol: "calendar",
    title: "Tomorrow",
    sections: [
        .list(AnswerCard.Items(eyebrow: "3 events", items: [
            AnswerCard.Item(
                text: "Design review with the platform team",
                detail: "Thu 11 Sep, 14:30 – 15:30 · Conference room B",
                symbol: "circle.fill"
            ),
            AnswerCard.Item(text: "Offsite", detail: "Thu 11 Sep", accent: "All day", symbol: "circle.fill"),
            AnswerCard.Item(text: "Dentist", detail: "Thu 11 Sep, 17:15 – 18:00", symbol: "circle.fill"),
        ])),
        .note(AnswerCard.Note(text: "Only the first 20 events are listed; there are more.", symbol: "ellipsis")),
    ]
)

private let sampleReminders = AnswerCard(
    source: "reminders",
    symbol: "checklist",
    title: "Overdue",
    sections: [
        .list(AnswerCard.Items(eyebrow: "2 reminders", items: [
            AnswerCard.Item(text: "Call the dentist", detail: "Due yesterday, 16:00", accent: "P1", symbol: "circle"),
            AnswerCard.Item(text: "Send the invoice", detail: "Due Mon 8 Sep", symbol: "circle"),
        ])),
        .note(AnswerCard.Note(text: "Priority: 1 is highest, 9 is lowest.", symbol: "exclamationmark.circle")),
    ]
)

private let sampleWrite = AnswerCard(
    source: "reminders",
    symbol: "checklist",
    title: "Reminders",
    lede: "Reminder set: \"Call the dentist\" for 4:00 PM."
)

/// The shape `AnswerCardBuilders.health` produces, with the longest figure the
/// tool can put in a tile. `13.5 breaths/min` is the value that decides whether
/// the strip works: it is nearly three times the width of a step count, and the
/// tile shrinks it rather than breaking or truncating it.
private let sampleHealth = AnswerCard(
    source: "get_health_summary",
    symbol: "bed.double",
    title: "Sleep",
    sections: [
        .metrics(AnswerCard.Metrics(eyebrow: "Latest whole day", tiles: [
            AnswerCard.Tile(value: "7 h 45 m", caption: "Sleep"),
            AnswerCard.Tile(value: "13.5 breaths/min", caption: "Respiratory rate"),
        ])),
        .facts(AnswerCard.Facts(eyebrow: "Against your own baseline", rows: [
            AnswerCard.Fact(
                label: "Sleep",
                value: "on Wed, Sep 10 — 12% below your 28-day average of 8 h 48 m, below your usual range."
            ),
            AnswerCard.Fact(
                label: "Respiratory rate",
                value: "on Wed, Sep 10, against a 28-day average of 13.6 breaths/min — in your usual range."
            ),
        ])),
        .list(AnswerCard.Items(eyebrow: "Worth noting", items: [
            AnswerCard.Item(text: "Highest sleep since May 2025.", symbol: "sparkles"),
        ])),
    ]
)

private struct CardGallery: View {
    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.cardGap) {
                AnswerCardView(card: sampleEvents)
                AnswerCardView(card: sampleReminders, onCompleteReminder: { _ in })
                AnswerCardView(
                    card: sampleWrite,
                    undo: AnswerCardView.UndoOffer(expiresAt: .now.addingTimeInterval(300)) {}
                )
                AnswerCardView(card: sampleHealth)
                AnswerCardView(card: .nothing("No events next week.", title: "Next week", symbol: "calendar"))
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}

#Preview("Cards light") { CardGallery() }

#Preview("Cards dark") { CardGallery().preferredColorScheme(.dark) }

#Preview("Cards at accessibility3") {
    CardGallery().dynamicTypeSize(.accessibility3)
}

#Preview("Every other section") {
    ScrollView {
        VStack(spacing: PDSpacing.cardGap) {
            AnswerCardView(card: AnswerCard(
                symbol: "chart.bar",
                title: "This week",
                sections: [
                    // "Conversational" is the exact caption a competitor's own
                    // metric strip breaks as "Convers/ational". It stays here as
                    // the thing this layout has to survive.
                    .metrics(AnswerCard.Metrics(eyebrow: "At a glance", tiles: [
                        AnswerCard.Tile(value: "12", caption: "Meetings"),
                        AnswerCard.Tile(value: "4h 20m", caption: "Conversational"),
                        AnswerCard.Tile(value: "3", caption: "Free afternoons"),
                    ])),
                    .facts(AnswerCard.Facts(eyebrow: "Where to find it", rows: [
                        AnswerCard.Fact(
                            label: "Address",
                            value: "Shop 20, Gyandeep Apartments, Sector 3–4, Vashi",
                            accent: "Vashi"
                        ),
                        AnswerCard.Fact(label: "Closed", value: "Monday", accent: "Monday"),
                    ])),
                    .steps(AnswerCard.Steps(eyebrow: "To turn it on", steps: [
                        AnswerCard.Step(title: "Open Settings", detail: "Privacy & Security"),
                        AnswerCard.Step(title: "Tap Calendars, then Pocketd"),
                        AnswerCard.Step(title: "Choose Full Access"),
                    ])),
                    .note(AnswerCard.Note(
                        text: "Pocketd can only add to your calendar, not read it.",
                        symbol: "lock",
                        tone: .caution
                    )),
                ]
            ))
        }
        .padding(PDSpacing.gutter)
    }
    .pdCanvas()
}
