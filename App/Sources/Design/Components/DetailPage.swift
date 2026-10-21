import SwiftUI

/// The shell every pushed detail page shares — Your day, Reminders, Sleep,
/// Activity, a routine's result.
///
///     DetailPage(
///         title: "Sleep",
///         summary: "6h 36m — 29 minutes under your usual.",
///         composer: ContextComposer(
///             suggestion: .init("Was this week better than last?") { ask(…) },
///             placeholder: "Ask anything else",
///             onAsk: { openConversation() }
///         )
///     ) {
///         PDCard { ComparisonTiles(…) }
///         SectionLabel("Last 7 nights")
///         PDCard { DataRow(…) … }
///     }
///
/// One grammar, top to bottom: the title, one grey sentence that *is* the
/// verdict (written by rules, not by the model — it is there on the first
/// frame), the data in white cards, and the composer pinned at the bottom
/// asking "anything else", because the page above is already one answer.
///
/// The system navigation bar stays — the back button is the system's, and so
/// is the scroll-edge treatment — but its title is empty while the page's own
/// `.title` heading is on screen, and fades in once that heading has scrolled
/// under the bar. One title on screen at a time.
///
/// Push it inside a `NavigationStack`; it sets its own navigation title, so
/// the next page's back button says where it goes.
struct DetailPage<Content: View>: View {
    let title: String
    /// The verdict in one grey sentence. Nil only while there is truly
    /// nothing to say.
    var summary: String?
    /// The composer pinned to the bottom. Nil for a page with nothing to ask.
    var composer: ContextComposer?
    @ViewBuilder var content: Content

    /// Whether the in-page heading has scrolled under the bar.
    @State private var headingIsHidden = false

    var body: some View {
        page
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                        .opacity(headingIsHidden ? 1 : 0)
                        .animation(PDMotion.gentle, value: headingIsHidden)
                        .accessibilityHidden(!headingIsHidden)
                }
            }
    }

    @ViewBuilder
    private var page: some View {
        if let composer {
            scroll.contextComposer(composer)
        } else {
            scroll
        }
    }

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                VStack(alignment: .leading, spacing: PDSpacing.xs) {
                    Text(title)
                        .font(Font.pd.titleDetail)
                        .tracking(-0.3)
                        .foregroundStyle(Color.pd.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let summary {
                        Text(summary)
                            .pdSubtitle()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, PDSpacing.xs)

                content
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.top, PDSpacing.xs)
            .padding(.bottom, PDSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The offset itself rather than a Bool: a Bool reports nothing for a
        // page that is already past the heading when it is first measured,
        // where any movement of the offset settles it either way.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // Past roughly the heading's height: it is under the bar now.
            let hidden = offset > 44
            if hidden != headingIsHidden {
                headingIsHidden = hidden
            }
        }
        .pdCanvas()
    }
}

#Preview("Detail page light") {
    NavigationStack {
        DetailPagePreview()
    }
}

#Preview("Detail page dark") {
    NavigationStack {
        DetailPagePreview()
    }
    .preferredColorScheme(.dark)
}

private struct DetailPagePreview: View {
    var body: some View {
        DetailPage(
            title: "Sleep",
            summary: "6h 36m last night — 34 minutes under your usual.",
            composer: ContextComposer(
                suggestion: .init("Was this week better than last?") {},
                placeholder: "Ask anything else",
                onAsk: {}
            )
        ) {
            PDCard {
                ComparisonTiles(
                    usual: .init("Usual", value: "7h 10m"),
                    current: .init("Last night", value: "6h 36m")
                )
            }
            SectionLabel("Last 7 nights")
            PDCard {
                VStack(spacing: PDSpacing.s) {
                    ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { day in
                        DataRow(title: day, value: "7h 0\(day.count)m")
                        if day != "Sun" {
                            Divider().overlay(Color.pd.divider)
                        }
                    }
                }
            }
        }
    }
}
