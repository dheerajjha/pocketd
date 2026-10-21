import SwiftUI

/// One item on a timeline: a time, a title, and optionally a line about it.
struct TimelineItem: Identifiable, Hashable {
    var id = UUID()
    /// Already formatted — "09:30", "All day". The list does no date maths; the
    /// caller knows the locale and the calendar and this does not.
    var time: String
    var title: String
    var detail: String?
    /// The dot's colour. Defaults to the accent; a past item can pass tertiary.
    var tint: Color = .pd.accent

    static func == (lhs: TimelineItem, rhs: TimelineItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The day, as a rail with dots on it.
///
/// Times are monospaced and right-aligned in a fixed column so the rail is
/// straight — proportional digits put "9:30" and "11:00" at different distances
/// from the dots and the whole thing wobbles.
///
/// At the accessibility text sizes a time column wide enough for "10:30 PM"
/// would leave the titles a few letters a line, so each time moves above its
/// title instead and the rail runs beside both.
struct TimelineList: View {
    let items: [TimelineItem]
    /// The width of the time column at the default text size. Fixed rather
    /// than intrinsic for the reason above; it is scaled with the time's own
    /// text style, so a caller measuring in default-size characters stays
    /// right at every size.
    var timeWidth: CGFloat = 54

    @Environment(\.dynamicTypeSize) private var typeSize
    /// How much the time's text style has grown from its default size.
    @ScaledMetric(relativeTo: .callout) private var timeScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item, isFirst: index == 0, isLast: index == items.count - 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ item: TimelineItem, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: PDSpacing.s) {
            if !typeSize.isAccessibilitySize {
                Text(item.time)
                    .font(Font.pd.monoValue)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .frame(width: timeWidth * timeScale, alignment: .trailing)
            }

            // The rail. Drawn per row rather than as one line behind
            // everything, so a row of any height still joins up with its
            // neighbours.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.pd.divider)
                    .frame(width: 1, height: 6)
                Circle()
                    .fill(item.tint)
                    .frame(width: 7, height: 7)
                Rectangle()
                    .fill(isLast ? Color.clear : Color.pd.divider)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 7)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                if typeSize.isAccessibilitySize {
                    Text(item.time)
                        .font(Font.pd.monoValue)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                Text(item.title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail {
                    Text(detail)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, isLast ? 0 : PDSpacing.m)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.time). \(item.title). \(item.detail ?? "")")
    }
}

#Preview("Timeline light") {
    TimelineListPreview()
}

#Preview("Timeline dark") {
    TimelineListPreview().preferredColorScheme(.dark)
}

private struct TimelineListPreview: View {
    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.m) {
                SectionLabel("Today")
                TimelineList(items: [
                    TimelineItem(time: "09:30", title: "Standup", detail: "15 minutes"),
                    TimelineItem(time: "11:00", title: "Design review with the team"),
                    TimelineItem(time: "14:15", title: "Dentist", detail: "Wellington Street"),
                    TimelineItem(time: "All day", title: "Anna's birthday", tint: .pd.inkTertiary),
                ])
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .pdCanvas()
    }
}
