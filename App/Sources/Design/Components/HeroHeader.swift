import SwiftUI

/// The top of the home screen, instead of a navigation bar.
///
/// "Thursday" in `.largeTitle` bold with "17 SEP" in mono under it, and the
/// screen's header controls — a `HeaderCapsule` — floating on the right.
/// There is no navigation bar behind this on the home screen: a system bar
/// would spend 96pt saying the word "Today" over a screen whose first line
/// already says what day it is.
///
/// The wash is the other half of the effect. A cool gradient over the top
/// ~240pt, fading into the canvas before the first card, which is what stops a
/// flat near-white page reading as a form.
///
/// At the accessibility text sizes the day name alone fills the width, so the
/// controls move onto their own line above it rather than squeezing it into
/// "Wednes-day".
struct HeroHeader<Trailing: View>: View {
    let dayName: String
    /// Already formatted, uppercased here. "17 SEP".
    let date: String
    /// Draw the wash behind the header. Off when the screen draws its own.
    var wash: Bool = true
    @ViewBuilder var trailing: Trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xxs) {
            Text(dayName)
                .pdTitle()
                .foregroundStyle(Color.pd.ink)
                // One word, never broken: it shrinks a little before it would
                // wrap inside itself.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Text(date.uppercased())
                .font(Font.pd.label)
                .tracking(1.4)
                .foregroundStyle(Color.pd.inkSecondary)
                .accessibilityLabel(date)
        }
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    HStack(spacing: PDSpacing.xs) {
                        Spacer(minLength: 0)
                        trailing
                    }
                    titleBlock
                }
            } else {
                HStack(alignment: .top, spacing: PDSpacing.m) {
                    titleBlock
                    Spacer(minLength: 0)
                    HStack(spacing: PDSpacing.xs) {
                        trailing
                    }
                }
            }
        }
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.top, PDSpacing.xs)
        .padding(.bottom, PDSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            if wash {
                // 240pt tall and allowed to overflow the header's own bounds,
                // because the wash is about the top of the *page* and the
                // header is only the first thing in it.
                PDGradient.canvasWash
                    .frame(height: 240)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension HeroHeader where Trailing == EmptyView {
    init(dayName: String, date: String, wash: Bool = true) {
        self.init(dayName: dayName, date: date, wash: wash) { EmptyView() }
    }
}

extension HeroHeader {
    /// The common case: today, in the phone's own locale.
    ///
    /// Formatting lives here rather than at the call site so that every screen
    /// showing a date shows the same one. `.wide` weekday and an abbreviated
    /// month are both locale-aware, so a French phone gets "jeudi" and
    /// "17 SEPT." without anybody writing a second format.
    init(date: Date, wash: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.init(
            dayName: date.formatted(.dateTime.weekday(.wide)),
            date: date.formatted(.dateTime.day().month(.abbreviated)),
            wash: wash,
            trailing: trailing
        )
    }
}

extension View {
    /// The hero wash, pinned to the top of a whole screen.
    ///
    /// For screens that scroll: put it here rather than on the header, or the
    /// gradient scrolls away and the top of the page turns flat white as soon
    /// as anybody moves.
    func pdHeroWash(height: CGFloat = 240) -> some View {
        background(alignment: .top) {
            PDGradient.canvasWash
                .frame(height: height)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
}

#Preview("Hero header light") {
    HeroHeaderPreview()
}

#Preview("Hero header dark") {
    HeroHeaderPreview().preferredColorScheme(.dark)
}

private struct HeroHeaderPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            HeroHeader(date: Date()) {
                HeaderCapsule(initial: "D", showsBadge: true, onRoutines: {}, onYou: {})
            }
            ScrollView {
                VStack(spacing: PDSpacing.cardGap) {
                    Text("Your brief will appear here, on the canvas.")
                        .pdLead()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.m)
            }
        }
        .pdCanvas()
    }
}
