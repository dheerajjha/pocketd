import PocketdKit
import SwiftUI

/// Screen two: how Pocketd thinks.
///
/// Both brains are first-class choices. Where Apple Intelligence is ready the
/// screen offers "Built into iPhone" — nothing to download, recommended and
/// selected — beside a private download that works on any iPhone. Where it is
/// not, the screen is the one recommended download, with its size, its time
/// and a word about the connection, and the download starts on Continue. Only
/// brains that can read your day are offered: the old "Quick" option was a
/// brain that answered "what's on today?" by inventing a day.
///
/// What the rows say, which one starts selected and what Continue does are all
/// `Intro.BrainPlan`'s, read fresh from the phone every time this screen draws.
/// That is the fix for the walkthrough's worst intro bug: Back to this screen
/// after the download had finished offered "Download and continue · 386 MB"
/// again, and tapping it fetched the whole file a second time. A brain that is
/// on the phone now says "Ready", and Continue moves on.
///
/// The only screen of the intro that names a size, and — with the readiness
/// line at the end — the only place outside You › Brain that says "brain".
struct OnboardingBrainStep: View {
    @Environment(AppModel.self) private var model

    /// Held by the flow, not by this screen: `.id(step)` destroys this view's
    /// own state on the way out, and a choice that Back and Next silently undo
    /// is worse than no choice. `nil` until somebody taps a row, so the plan's
    /// pre-selection — which can change while Apple's availability is still
    /// being read — is followed until then.
    @Binding var selection: Intro.BrainPlan.Option?

    var onContinue: () -> Void

    @State private var reach = OnboardingReach()

    var body: some View {
        let plan = model.introBrainPlan
        let selected = selection ?? plan.preselected

        Group {
            switch plan.layout {
            case .choice: choice(plan, selected: selected)
            case .downloadOnly: downloadOnly(plan)
            case .nothingFits: nothingFits
            }
        }
        // The first launch reads Apple's availability in the background, and
        // a quick tap on Get started can land here before it has. Asking again
        // costs nothing when it has already been read.
        .task { await model.refreshBuiltInAvailability() }
    }

    private func proceed(_ plan: Intro.BrainPlan, selected: Intro.BrainPlan.Option?) {
        model.applyIntroBrain(plan.action(for: selected))
        onContinue()
    }

    // MARK: - Both options

    private func choice(_ plan: Intro.BrainPlan, selected: Intro.BrainPlan.Option?) -> some View {
        OnboardingPage(
            ornament: .icon("brain"),
            headline: Intro.Copy.brainTitle,
            secondary: Intro.Copy.brainLine,
            primary: .init("Continue") { proceed(plan, selected: selected) }
        ) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                if let builtIn = plan.builtIn {
                    BrainOptionCard(
                        title: BuiltInBrainOffer.title,
                        isRecommended: plan.recommended == .builtIn,
                        isSelected: selected == .builtIn,
                        status: builtInStatus(builtIn, inUse: plan.inUse == .builtIn)
                    ) { select(.builtIn) }
                }
                if let download = plan.download {
                    BrainOptionCard(
                        title: Intro.Copy.downloadTitle,
                        isRecommended: plan.recommended == .download,
                        isSelected: selected == .download,
                        status: downloadStatus(download, inUse: plan.inUse == .download, alongsideBuiltIn: true)
                    ) { select(.download) }
                }
                if selected == .download, case let .offer(record)? = plan.download, reach.isOnMobileData {
                    mobileDataNote(record)
                }
            }
        }
    }

    private func select(_ option: Intro.BrainPlan.Option) {
        guard selection != option else { return }
        Haptics.tap()
        selection = option
    }

    // MARK: - The download alone

    /// No built-in option on this phone. One brain, no choice to make, so no
    /// radio buttons — the card says what is coming and Continue starts it.
    private func downloadOnly(_ plan: Intro.BrainPlan) -> some View {
        let download = plan.download
        let isHere: Bool = if case .onPhone? = download { true } else { false }
        return OnboardingPage(
            ornament: .icon(isHere ? "checkmark" : "arrow.down"),
            headline: isHere ? Intro.Copy.hasBrainTitle : Intro.Copy.gettingBrainTitle,
            secondary: isHere ? Intro.Copy.hasBrainLine : Intro.Copy.gettingBrainLine,
            primary: .init("Continue") { proceed(plan, selected: .download) }
        ) {
            if let download {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    PDCard(warm: true) {
                        VStack(alignment: .leading, spacing: PDSpacing.xs) {
                            Text(Intro.Copy.downloadTitle)
                                .font(Font.pd.rowTitle)
                                .foregroundStyle(Color.pd.ink)
                            downloadStatus(download, inUse: plan.inUse == .download, alongsideBuiltIn: false)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    if case let .offer(record) = download, reach.isOnMobileData {
                        mobileDataNote(record)
                    }
                }
            }
        }
    }

    // MARK: - Nothing fits

    private var nothingFits: some View {
        OnboardingPage(
            ornament: .icon("brain"),
            headline: Intro.Copy.nothingFitsTitle,
            secondary: Intro.Copy.nothingFitsLine,
            primary: .init("Continue", run: onContinue)
        ) {
            EmptyView()
        }
    }

    // MARK: - What each row says

    @ViewBuilder
    private func builtInStatus(_ state: Intro.BrainPlan.BuiltIn, inUse: Bool) -> some View {
        switch state {
        case .ready:
            if inUse {
                readyLine
            } else {
                detailLine(BuiltInBrainOffer.onboardingDetail)
            }
        case .gettingReady:
            detailLine(Intro.Copy.builtInGettingReady)
        }
    }

    @ViewBuilder
    private func downloadStatus(
        _ download: Intro.BrainPlan.Download,
        inUse: Bool,
        alongsideBuiltIn: Bool
    ) -> some View {
        switch download {
        case let .offer(record):
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                detailLine(pdDownloadLine(record.totalDownloadBytes))
                if alongsideBuiltIn {
                    detailLine(Intro.Copy.downloadWorksAnywhere)
                } else if !reach.isOnMobileData {
                    detailLine(Intro.Copy.downloadInBackground)
                }
            }
        case let .arriving(record):
            arriving(record)
        case .onPhone:
            if inUse {
                readyLine
            } else {
                detailLine(Intro.Copy.onPhoneDetail)
            }
        }
    }

    /// "Getting ready · 34%" over a stripe, from the live transfer.
    private func arriving(_ record: ModelRecord) -> some View {
        let fraction = model.introTransfer(for: record)?.fraction ?? 0
        return VStack(alignment: .leading, spacing: PDSpacing.xs) {
            detailLine("\(Intro.Copy.builtInGettingReady) · \(Int((fraction * 100).rounded(.down)))%")
                .monospacedDigit()
            ProgressStripe(fraction: fraction)
                .accessibilityHidden(true)
            detailLine(Intro.Copy.downloadInBackground)
        }
    }

    private var readyLine: some View {
        Label {
            Text(Intro.Copy.ready)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
        }
        .font(Font.pd.secondary.weight(.semibold))
        .foregroundStyle(Color.pd.positive)
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(Font.pd.secondary)
            .foregroundStyle(Color.pd.inkSecondaryWarm)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A sentence, not a wall. Somebody who knows they are on data and wants
    /// it anyway taps the same button; somebody who did not know now does,
    /// before the meter starts.
    private func mobileDataNote(_ record: ModelRecord) -> some View {
        Primer(
            Intro.Copy.mobileData(size: pdBytes(record.totalDownloadBytes)),
            symbol: "antenna.radiowaves.left.and.right",
            warm: true
        )
    }
}

// MARK: - One option

/// A choosable card: a radio mark, the brain's name in benefit words, an
/// optional "Recommended", and what it costs or where it stands.
///
/// A button with the selected trait rather than a `Picker`, because each row
/// carries two lines of explanation and a progress stripe a picker row cannot
/// hold, and a whole card is a far easier target than a radio dot.
private struct BrainOptionCard<Status: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    let title: String
    let isRecommended: Bool
    let isSelected: Bool
    /// The grey lines under the title: what it costs, or where it stands.
    let status: Status
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(Font.pd.lead)
                    .foregroundStyle(isSelected ? Color.pd.accentWarm : Color.pd.inkTertiary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    // Side by side while the title fits whole; the badge goes
                    // under it at the accessibility sizes.
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                            titleText
                            if isRecommended { badge }
                        }
                    } else {
                        HStack(spacing: PDSpacing.xs) {
                            titleText
                            if isRecommended { badge }
                        }
                    }
                    status
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(PDSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pdCardSurface(
                fill: .pd.cardWarm,
                stroke: isSelected ? .pd.accentWarm : .pd.cardStrokeWarm
            )
            .overlay {
                // A second hairline inside the first, for the selected card
                // only: the edge has to say "this one" in grayscale too.
                if isSelected {
                    RoundedRectangle(cornerRadius: PDRadius.card, style: .continuous)
                        .strokeBorder(Color.pd.accentWarm, lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PDRadius.card, style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var titleText: some View {
        Text(title)
            .font(Font.pd.rowTitle)
            .foregroundStyle(Color.pd.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var badge: some View {
        Text(Intro.Copy.recommended)
            .font(Font.pd.footnote.weight(.semibold))
            .foregroundStyle(Color.pd.accentWarm)
            .padding(.horizontal, PDSpacing.xs)
            .padding(.vertical, 2)
            .background(Color.pd.accentSoft, in: Capsule(style: .continuous))
    }
}

#Preview("Brain light") {
    OnboardingBrainStepPreview()
}

#Preview("Brain dark") {
    OnboardingBrainStepPreview().preferredColorScheme(.dark)
}

private struct OnboardingBrainStepPreview: View {
    @State private var selection: Intro.BrainPlan.Option?

    var body: some View {
        OnboardingStepPreview {
            OnboardingBrainStep(selection: $selection, onContinue: {})
        }
        .environment(AppModel())
    }
}
