import PocketdKit
import SwiftUI

/// The pieces every screen under You is built from.
///
/// One grammar: a mono section label, a white card, rows inside it with a
/// hairline between them, and — only where a row cannot carry it — a short
/// footnote under the card.
///
/// Written here rather than in `Design/Components` because none of it is
/// general — a `NavRow` is a row in a settings card, not a component another
/// screen would want. The moment one does, it moves.

// MARK: - A pushed screen

/// Every screen under You that is not the root.
///
/// The system navigation bar and the system back button, with the in-page
/// heading `DetailPage` draws — the bar's own title fades in once the heading
/// has scrolled under it. These screens used to hide the bar and draw their
/// own back circle, which left scrolled content running into the status bar
/// with no backdrop, and a hand-made back button that VoiceOver, the swipe
/// and the long-press history menu all treated as a stranger. A detail page
/// on Today and a page under You are now the same thing, so they are drawn by
/// the same shell.
struct YouDetailScreen<Content: View>: View {
    let title: String
    /// One grey sentence under the heading. One — a second is a footnote.
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        DetailPage(title: title, summary: subtitle) {
            content()
        }
    }
}

// MARK: - A section

/// A mono label, a card of rows, and the footnote under it.
///
/// The footnote is a parameter rather than something the caller appends,
/// because "under the card, small, grey" is the whole reason those sentences
/// read as annotations instead of as more rows. Keep it to one sentence.
struct YouSection<Content: View>: View {
    let title: String
    var footnote: String?
    /// The card's inner padding. Rows carry their own vertical padding, so the
    /// default is the tighter one — 20 on top of a row's own 12 is a gap.
    var padding: CGFloat = PDSpacing.m
    @ViewBuilder var content: () -> Content

    init(
        _ title: String,
        footnote: String? = nil,
        padding: CGFloat = PDSpacing.m,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.padding = padding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            SectionLabel(title)
                .padding(.horizontal, PDSpacing.xxs)
            PDCard(padding: padding) {
                VStack(spacing: 0) { content() }
            }
            if let footnote {
                Text(footnote)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .modifier(PDLineSpacing(3, relativeTo: .footnote))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PDSpacing.xxs)
            }
        }
    }
}

/// The hairline between two rows in a card.
///
/// Inset to the text column by default, which is what stops the rule cutting
/// through the icon tiles and makes a card read as one list rather than as
/// stacked bands.
struct RowDivider: View {
    var inset: CGFloat = PDMetric.iconTileSmall + PDSpacing.s

    var body: some View {
        Rectangle()
            .fill(Color.pd.divider)
            .frame(height: 1)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// Where a row's trailing control goes when the words need the room.
enum RowTrailing {
    /// Beside the title while the title fits on one line next to it; under the
    /// words otherwise (`AccessoryRowLayout`). For switches, values, menus and
    /// pills — anything wide enough to squeeze a title into "Remind / ers".
    case adaptive
    /// Always at the trailing edge, centred on the row. For a chevron or an ↗,
    /// which are narrow, and which mean nothing anywhere else.
    case pinned
}

/// The shared skeleton of every row: an optional icon tile, a title, a detail
/// line, and whatever sits at the trailing edge.
///
/// At least 44pt tall, every word in a text style, and nothing truncated: the
/// detail wraps, and a wide trailing control moves under the words rather
/// than squeezing them.
struct RowShell<Trailing: View>: View {
    var symbol: String?
    var symbolTint: Color = .pd.accent
    var symbolFill: Color = .pd.accentSoft
    let title: String
    var detail: String?
    /// A pill beside the title. Prefer plain words in `detail` — a coloured
    /// pill on a settings row is the "Needs attention" look this app left
    /// behind (ideal-ui §1.7).
    var status: (kind: StatusPill.Kind, text: String)?
    var trailingPlacement: RowTrailing = .adaptive
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: PDSpacing.s) {
            if let symbol {
                IconTile.small(symbol, fill: symbolFill, tint: symbolTint)
            }
            words
        }
        .padding(.vertical, PDSpacing.s)
        .frame(maxWidth: .infinity, minHeight: PDMetric.minHitTarget, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var words: some View {
        if Trailing.self == EmptyView.self {
            textColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if trailingPlacement == .pinned {
            HStack(spacing: PDSpacing.xs) {
                textColumn
                Spacer(minLength: PDSpacing.xs)
                trailing()
            }
        } else {
            // Each part wrapped in one container, so the layout always sees
            // exactly title, detail and accessory — a trailing builder that
            // produced two views would otherwise be read as a missing part.
            AccessoryRowLayout(spacing: PDSpacing.s) {
                titleLine
                if let detail { detailText(detail) }
                HStack(spacing: PDSpacing.xs) { trailing() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleLine
            if let detail { detailText(detail) }
        }
    }

    private var titleLine: some View {
        HStack(spacing: PDSpacing.xs) {
            Text(title)
                .font(Font.pd.rowTitle)
                .foregroundStyle(Color.pd.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                StatusPill(status.kind, status.text)
            }
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(Font.pd.secondary)
            .foregroundStyle(Color.pd.inkSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The trailing chevron: decoration, so tertiary ink, in the chevron token
/// that grows with the row's text.
struct RowChevron: View {
    var symbol: String = "chevron.right"

    var body: some View {
        Image(systemName: symbol)
            .font(Font.pd.chevron)
            .foregroundStyle(Color.pd.inkTertiary)
            .accessibilityHidden(true)
    }
}

/// A row that goes somewhere in this app.
struct NavRow: View {
    var symbol: String?
    let title: String
    var detail: String?
    var status: (kind: StatusPill.Kind, text: String)?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            RowShell(symbol: symbol, title: title, detail: detail, status: status, trailingPlacement: .pinned) {
                RowChevron()
            }
        }
        .buttonStyle(PDPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(announcement)
        .accessibilityAddTraits(.isButton)
    }

    private var announcement: String {
        [title, detail, status?.text].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A row that does something here and now.
///
/// No chevron and no arrow, because neither is true: nothing is pushed and
/// nothing is opened. "Copy the key" and "Clear the log" happen where you are
/// standing, and a chevron beside them promises a screen that never arrives.
struct ActionRow: View {
    var symbol: String?
    let title: String
    var detail: String?
    var tint: Color = .pd.accent
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button {
            isDestructive ? Haptics.warning() : Haptics.tap()
            action()
        } label: {
            RowShell(
                symbol: symbol,
                symbolTint: isDestructive ? .pd.danger : tint,
                symbolFill: isDestructive ? .pd.dangerSoft : .pd.accentSoft,
                title: title,
                detail: detail
            ) {
                EmptyView()
            }
        }
        .buttonStyle(PDPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// A row that leaves the app — iOS Settings, Safari, the App Store.
///
/// `arrow.up.right` rather than a chevron, because the two mean different
/// things and a reader who has learned one has learned the other.
struct LinkRow: View {
    var symbol: String?
    let title: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            RowShell(symbol: symbol, title: title, detail: detail, trailingPlacement: .pinned) {
                RowChevron(symbol: "arrow.up.right")
            }
        }
        .buttonStyle(PDPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens outside Pocketd")
        .accessibilityAddTraits(.isButton)
    }
}

/// A row whose whole content is a switch.
///
/// The switch is the one accessibility element and carries the row's words,
/// so VoiceOver reads "Require an API key, switch, on" once rather than the
/// title, then the detail, then an unlabelled switch.
struct ToggleRow: View {
    var symbol: String?
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        RowShell(symbol: symbol, title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(Color.pd.accent)
        }
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .accessibilityHint(detail ?? "")
        }
    }
}

/// A row that shows a number rather than a destination.
///
/// The value is monospaced and right-aligned — a column of these is a column
/// of figures, and the reason to put them in a column is so they line up.
/// At the accessibility sizes it moves under the title instead of squeezing
/// it.
struct ValueRow: View {
    var symbol: String?
    let title: String
    var detail: String?
    let value: String
    var valueTint: Color = .pd.ink

    var body: some View {
        RowShell(symbol: symbol, title: title, detail: detail) {
            Text(value)
                .font(Font.pd.monoValue)
                .foregroundStyle(valueTint)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, value, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A row that chooses one of a short list.
///
/// A `Menu` rather than a segmented control or a wheel: the options are words
/// of different lengths, and this is the only control iOS has that shows the
/// current one without spending a row on it.
struct MenuRow<Value: Hashable>: View {
    var symbol: String?
    let title: String
    var detail: String?
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        RowShell(symbol: symbol, title: title, detail: detail) {
            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection = option.value
                    } label: {
                        if option.value == selection {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: PDSpacing.xxs) {
                    Text(currentLabel)
                        .font(Font.pd.secondary.weight(.medium))
                        .foregroundStyle(Color.pd.ink)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Font.pd.tick)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                .padding(.horizontal, PDSpacing.s)
                .padding(.vertical, PDSpacing.xxs)
                .frame(minHeight: PDMetric.linkPillHeight + PDSpacing.xs)
                .background(Color.pd.chip, in: Capsule(style: .continuous))
                .pdHitTarget()
            }
            .accessibilityLabel(title)
            .accessibilityValue(currentLabel)
        }
    }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }
}

// MARK: - Small pieces

/// A destructive control that does not look like a warning until it is read.
///
/// Danger text on a soft danger fill rather than a filled red button: a screen
/// with a red slab on it reads as an error state, and this is an ordinary
/// control that happens to be irreversible.
struct DangerButton: View {
    let title: String
    var symbol: String?
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.warning()
            action()
        } label: {
            HStack(spacing: PDSpacing.xs) {
                if let symbol {
                    Image(systemName: symbol).font(Font.pd.secondary)
                }
                Text(title)
                    .font(Font.pd.secondary.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isEnabled ? Color.pd.danger : Color.pd.inkSecondary)
            .padding(.horizontal, PDSpacing.m)
            .padding(.vertical, PDSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: PDMetric.minHitTarget)
            .background(
                isEnabled ? Color.pd.dangerSoft : Color.pd.chip,
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

/// A word you can tap, at the leading edge of whatever it belongs to.
///
/// Not `SecondaryLink`: that one takes the full width and centres itself,
/// because it is the escape hatch under a full-width primary button. Inside a
/// card, "Cancel" under a download has to start where the sentence above it
/// starts, or it floats in the middle of the row with nothing explaining what
/// it cancels. Drawn as tall as its line, tappable at 44.
struct InlineLink: View {
    let title: String
    var tint: Color = .pd.accent
    let action: () -> Void

    init(_ title: String, tint: Color = .pd.accent, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(Font.pd.secondary.weight(.semibold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.leading)
                .pdHitTarget(alignment: .leading)
        }
        .buttonStyle(PDPressStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(title)
    }
}

/// A block of monospaced text that is meant to be read character by character —
/// a log, a code snippet, a key.
///
/// `size` picks between the two mono text styles rather than a point size, so
/// the block grows with Dynamic Type: 11 or less is `caption2`, anything else
/// the `code` token (`footnote`).
struct MonoBlock: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(size <= 11 ? .system(.caption2, design: .monospaced) : Font.pd.code)
            .foregroundStyle(Color.pd.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PDSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous)
                    .fill(Color.pd.fillTile)
            )
    }
}

// MARK: - Pushing inside You

extension Navigator {
    /// Push a page one level deeper than the one on screen.
    ///
    /// `openYou(_:)` is for arriving from somewhere else: it lands on
    /// Today › You › the page, because arriving at Brain from a notice should
    /// leave You behind it and nothing else. From inside You that is exactly
    /// wrong — it would make Back from "More brains" go to You rather than to
    /// Brain.
    func push(_ route: YouRoute) {
        path.append(.youPage(route))
    }
}

// MARK: - Formatting

/// Bytes, the way every screen in this app says them.
func pdBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// How a fit verdict is said to somebody who has never heard the word "model".
///
/// "Comfortable" and "will not fit" are the engine's words for a memory
/// estimate. These are the same three facts in words that tell a reader what
/// happens to them rather than what happens to the heap.
func pdFitWords(_ fit: DeviceBudget.Fit) -> String {
    switch fit {
    case .comfortable: "Fits well"
    case .tight: "Tight fit"
    case .willNotFit: "Too big for this iPhone"
    }
}

/// A "·"-joined line that wraps after a separator, never before one.
///
/// "Nothing to download · Ready" broke as "Nothing to download / · Ready",
/// starting a line with a dot. A no-break space before each dot ties it to
/// the word it follows, so the line ends on the dot and the next starts with
/// a word.
func pdSeparated(_ line: String) -> String {
    line.replacingOccurrences(of: " · ", with: "\u{00A0}· ")
}

/// "1.1 GB · about 4 minutes on Wi-Fi".
///
/// Five megabytes a second, which is a slow home connection rather than an
/// optimistic one: a download that finishes early is a pleasant surprise and a
/// download that takes twice the promised time is the last thing this app ever
/// gets to say to somebody.
func pdDownloadLine(_ bytes: Int64) -> String {
    let minutes = max(1, Int((Double(bytes) / 5_000_000 / 60).rounded()))
    let time = minutes == 1 ? "about a minute" : "about \(minutes) minutes"
    return "\(pdBytes(bytes)) · \(time) on Wi-Fi"
}
