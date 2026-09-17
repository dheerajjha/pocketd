import SwiftUI

/// The top of a screen, instead of a navigation bar.
///
/// "Thursday" at 30pt with "17 SEP" in mono under it, and the screen's one or
/// two circular controls floating on the right. There is no navigation bar
/// behind this: a system bar would spend 96pt saying the word "Today" over a
/// screen whose first line already says what day it is.
///
/// The wash is the other half of the effect. A cool gradient over the top
/// ~240pt, fading into the canvas before the first card, which is what stops a
/// flat near-white page reading as a form.
struct HeroHeader<Trailing: View>: View {
    let dayName: String
    /// Already formatted, uppercased here. "17 SEP".
    let date: String
    /// Draw the wash behind the header. Off when the screen draws its own.
    var wash: Bool = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: PDSpacing.m) {
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                Text(dayName)
                    .pdTitle()
                    .foregroundStyle(Color.pd.ink)
                Text(date.uppercased())
                    .font(Font.pd.label)
                    .tracking(1.4)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .accessibilityLabel(date)
            }
            Spacer(minLength: 0)
            HStack(spacing: PDSpacing.xs) {
                trailing
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
                CircleIconButton(symbol: "bell", label: "Routines", badge: 2) {}
                AvatarButton(initial: "D") {}
            }
            ScrollView {
                VStack(spacing: PDSpacing.cardGap) {
                    PDCard {
                        VStack(alignment: .leading, spacing: PDSpacing.s) {
                            SectionLabel("Today's brief")
                            Text("Your brief will appear here.")
                                .font(Font.pd.lead)
                                .foregroundStyle(Color.pd.ink)
                        }
                    }
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.m)
            }
        }
        .pdCanvas()
    }
}
