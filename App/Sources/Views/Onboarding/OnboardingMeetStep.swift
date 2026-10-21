import PocketdKit
import SwiftUI

/// Screen one: what Pocketd is, and the three promises that back it up.
///
/// The orb rather than an icon tile because there is no ability to name yet —
/// what is being introduced is the thing itself.
///
/// The usage-counts sentence is here, on the first screen, because the old
/// welcome said "No cloud" while anonymous usage counts were on by default and
/// mentioned nowhere in the intro. Both are true; saying only one of them was
/// the problem. It is one grey line, it says what is never counted, and it
/// says where the switch is.
struct OnboardingMeetStep: View {
    var onContinue: () -> Void

    var body: some View {
        OnboardingPage(
            ornament: .orb,
            headline: Intro.Copy.meetTitle,
            secondary: Intro.Copy.meetLine,
            primary: .init(Intro.Copy.getStarted, run: onContinue)
        ) {
            VStack(alignment: .leading, spacing: PDSpacing.xl) {
                VStack(alignment: .leading, spacing: PDSpacing.m) {
                    ForEach(Intro.Copy.promises, id: \.text) { promise in
                        // Top-aligned, as PromoSheet's benefit rows are: at the
                        // accessibility sizes a promise takes three lines, and
                        // a tile centred against them floats beside nothing.
                        HStack(alignment: .top, spacing: PDSpacing.m) {
                            IconTile.small(promise.symbol, fill: .pd.fillWarm, tint: .pd.ink)
                            Text(promise.text)
                                .font(Font.pd.rowTitle)
                                .foregroundStyle(Color.pd.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Text(Intro.Copy.usageCounts)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondaryWarm)
                    .modifier(PDLineSpacing(2, relativeTo: .footnote))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Meet light") {
    OnboardingStepPreview { OnboardingMeetStep(onContinue: {}) }
}

#Preview("Meet dark") {
    OnboardingStepPreview { OnboardingMeetStep(onContinue: {}) }
        .preferredColorScheme(.dark)
}

#Preview("Meet AX") {
    OnboardingStepPreview { OnboardingMeetStep(onContinue: {}) }
        .dynamicTypeSize(.accessibility3)
}
