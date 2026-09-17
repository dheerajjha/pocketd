import PocketdKit
import SwiftUI

/// The pieces every screen in You is built from.
///
/// Six screens live under this tab and in v1 they were six different list
/// styles, three navigation bars and two ideas of what a row is. They are one
/// thing now: a mono section label, a card, rows inside it with a hairline
/// between them, and a footnote under the card for the sentence the rows are
/// not big enough to carry.
///
/// Written here rather than in `Design/Components` because none of it is
/// general — a `NavRow` is a row in a settings card, not a component another
/// tab would want. The moment a second tab wants one, it moves.

// MARK: - A pushed screen

/// Every screen under You that is not the root.
///
/// Its own back button and its own 27pt title rather than the system bar, for
/// the reason the tab bar is not a `TabView`: the system bar ends a screen with
/// an opaque strip and a hard rule, and these screens are meant to run off the
/// top and bottom of the phone. The swipe-back gesture is untouched — hiding
/// the bar in a `NavigationStack` does not disable it.
struct YouDetailScreen<Content: View>: View {
    let title: String
    var subtitle: String?
    /// One optional circular button at the top right.
    var actionSymbol: String?
    var actionLabel: String = ""
    var action: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                header
                content()
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.top, PDSpacing.xs)
        }
        .scrollIndicators(.hidden)
        // The floating bar's space as a safe-area inset rather than padding,
        // so content scrolls *under* the capsule and the last row still clears
        // it. See `PDMetric.tabBarClearance`.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: PDMetric.tabBarClearance)
        }
        .pdCanvas()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            HStack {
                CircleIconButton(symbol: "chevron.left", label: "Back") { dismiss() }
                Spacer(minLength: 0)
                if let actionSymbol, let action {
                    CircleIconButton(symbol: actionSymbol, label: actionLabel, action: action)
                }
            }
            Text(title)
                .font(Font.pd.titleDetail)
                .foregroundStyle(Color.pd.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).pdSubtitle()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, PDSpacing.xs)
    }
}

// MARK: - A section

/// A mono label, a card of rows, and the footnote under it.
///
/// The footnote is a parameter rather than something the caller appends,
/// because "under the card, 13pt, secondary" is the whole reason those
/// sentences read as annotations instead of as more rows.
struct YouSection<Content: View>: View {
    let title: String
    var footnote: String?
    /// The card's inner padding. Rows carry their own vertical padding, so the
    /// default is the tighter one — 20 on top of a row's own 10 is a gap.
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
            PDCard(padding: padding) {
                VStack(spacing: 0) { content() }
            }
            if let footnote {
                Text(footnote)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .lineSpacing(3)
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
    }
}

// MARK: - Rows

/// The shared skeleton of every row: an optional icon tile, a title, a detail
/// line, and whatever sits at the trailing edge.
struct RowShell<Trailing: View>: View {
    var symbol: String?
    var symbolTint: Color = .pd.accent
    var symbolFill: Color = .pd.accentSoft
    let title: String
    var detail: String?
    var detailTint: Color = .pd.inkSecondary
    /// Wrapped rather than truncated. A detail line that says why a row needs
    /// attention is the line most worth reading and the one most likely to be
    /// long.
    var detailLines: Int?
    /// A pill beside the title rather than at the trailing edge.
    ///
    /// At the trailing edge it competes with the chevron for the same space and
    /// what gives way is the detail line, which then wraps to three. Beside the
    /// title it is on the row's short line, where there is room.
    var status: (kind: StatusPill.Kind, text: String)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: PDSpacing.s) {
            if let symbol {
                IconTile.small(symbol, fill: symbolFill, tint: symbolTint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: PDSpacing.xs) {
                    Text(title)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                        .multilineTextAlignment(.leading)
                    if let status {
                        StatusPill(status.kind, status.text)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(Font.pd.secondary)
                        .foregroundStyle(detailTint)
                        .multilineTextAlignment(.leading)
                        .lineLimit(detailLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PDSpacing.xs)
            trailing()
        }
        .padding(.vertical, PDSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The trailing chevron, at the weight the reference draws it.
struct RowChevron: View {
    var symbol: String = "chevron.right"

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.pd.inkSecondary)
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
            RowShell(symbol: symbol, title: title, detail: detail, status: status) {
                RowChevron()
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(announcement)
        .accessibilityAddTraits(.isButton)
    }

    private var announcement: String {
        [title, detail, status?.text].compactMap { $0 }.joined(separator: ". ")
    }
}

/// A row that leaves the app — iOS Settings, Safari, the App Store sheet.
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
            RowShell(symbol: symbol, title: title, detail: detail) {
                RowChevron(symbol: "arrow.up.right")
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(.isButton)
    }
}

/// A row whose whole content is a switch.
struct ToggleRow: View {
    var symbol: String?
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        RowShell(symbol: symbol, title: title, detail: detail) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color.pd.accent)
                .accessibilityLabel(title)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A row that shows a number rather than a destination.
///
/// The value is monospaced and right-aligned, which is the one typographic rule
/// this whole design rests on: every unit, size and count is mono, every human
/// sentence is proportional.
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                .padding(.horizontal, PDSpacing.s)
                .frame(height: PDMetric.linkPillHeight + 8)
                .background(Color.pd.chip, in: Capsule(style: .continuous))
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

/// The dot beside whatever is loaded right now.
struct LoadedDot: View {
    var label: String = "Loaded"

    var body: some View {
        Circle()
            .fill(Color.pd.positive)
            .frame(width: 7, height: 7)
            .accessibilityLabel(label)
    }
}

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
                    Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                }
                Text(title).font(Font.pd.secondary.weight(.semibold))
            }
            .foregroundStyle(isEnabled ? Color.pd.danger : Color.pd.inkTertiary)
            .padding(.horizontal, PDSpacing.m)
            .frame(maxWidth: .infinity, minHeight: PDMetric.pillHeight)
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

/// A block of monospaced text that is meant to be read character by character —
/// a log, a code snippet, a path.
struct MonoBlock: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
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

/// A disclosure that matches the rest of the card.
///
/// The system `DisclosureGroup` brings its own font, its own chevron placement
/// and a label that cannot be a row, so a card with one in it has two ideas of
/// what a row looks like.
struct RowDisclosure<Content: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.tap()
                withAnimation(PDMotion.standard) { isExpanded.toggle() }
            } label: {
                RowShell(symbol: symbol, title: title, detail: detail) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.pd.inkSecondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                VStack(spacing: 0) { content() }
                    .padding(.bottom, PDSpacing.xs)
            }
        }
    }
}

// MARK: - Formatting

// MARK: - Pushing inside You

extension Navigator {
    /// Push a route onto the You stack without resetting it.
    ///
    /// `openYou(_:)` is for arriving from another tab: it replaces the stack,
    /// because landing on Brain from a card on Today should leave one screen
    /// behind it and not whatever somebody was looking at three days ago. From
    /// inside You that is exactly wrong — it would make Back from "Add a brain"
    /// go to the profile rather than to Brain.
    func push(_ route: YouRoute) {
        youPath.append(route)
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

/// The pill beside a model in a list, from the same verdict.
func pdFitPill(_ fit: DeviceBudget.Fit) -> (kind: StatusPill.Kind, text: String) {
    switch fit {
    case .comfortable: (.positive, "Fits well")
    case .tight: (.caution, "Tight fit")
    case .willNotFit: (.caution, "Too big")
    }
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
