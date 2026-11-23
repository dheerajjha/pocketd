import PocketdKit
import SwiftUI

/// Screen two: how Pocketd thinks.
///
/// The local choices come first. Where Apple offers private cloud processing,
/// its row explains what leaves the phone before either of the two taps
/// needed to use it. A row tap alone never changes the brain.
struct OnboardingBrainStep: View {
    @Environment(AppModel.self) private var model

    /// The flow remembers the draft; Continue applies the displayed option,
    /// never whichever option might be recommended after a status refresh.
    @Binding var selection: Intro.BrainPlan.Option?

    var onContinue: () -> Void

    @State private var reach = OnboardingReach()
    @State private var applying: Task<Void, Never>?
    @State private var confirmationNotice: String?

    var body: some View {
        let plan = model.introBrainPlan
        let selected = plan.selection(forDraft: selection)
        let heading = header(for: plan)
        return OnboardingPage(
            ornament: .icon(heading.symbol),
            headline: heading.title,
            secondary: heading.detail,
            primer: confirmationNotice,
            primary: .init(
                plan.primaryTitle(for: selected), isEnabled: plan.action(for: selected) != nil,
                isLoading: applying != nil, identifier: "intro.brain.continue"
            ) { proceed(with: selected) }
        ) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                if let builtIn = plan.builtIn {
                    option(.builtIn, title: BuiltInBrainOffer.title, in: plan, selected: selected) {
                        if plan.cloud.isListed { detailLine(Intro.Copy.localProcessing) }
                        builtInStatus(builtIn, inUse: plan.inUse == .builtIn)
                    }
                }
                if let download = plan.download {
                    option(.download, title: Intro.Copy.downloadTitle, in: plan, selected: selected) {
                        if plan.cloud.isListed { detailLine(Intro.Copy.localProcessing) }
                        downloadStatus(download, inUse: plan.inUse == .download, alongsideBuiltIn: plan.builtIn != nil)
                    }
                    if case let .offer(record) = download, reach.isOnMobileData,
                       selected == .download || plan.layout == .downloadOnly {
                        mobileDataNote(record)
                    }
                }
                if plan.cloud.isListed {
                    option(.privateCloudCompute, title: AppleCloudStatus.title, in: plan, selected: selected) {
                        detailLine(AppleCloudStatus.detail)
                        detailLine(plan.inUse == .privateCloudCompute
                                   ? "Current choice · \(plan.cloud.statusLine)" : plan.cloud.statusLine)
                    }
                } else if plan.inUse == .privateCloudCompute {
                    // Not an offer: a previously chosen cloud brain is still
                    // the preference while Apple's service is getting ready.
                    PDCard(warm: true) {
                        VStack(alignment: .leading, spacing: PDSpacing.xs) {
                            Text("Current choice")
                                .font(Font.pd.rowTitle)
                                .foregroundStyle(Color.pd.ink)
                            detailLine(plan.cloud.statusLine)
                                .accessibilityIdentifier("intro.brain.savedCloud.status")
                            if selected != .privateCloudCompute {
                                TextLink("Keep current choice") {
                                    selection = nil
                                    confirmationNotice = nil
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { _ = await model.refreshBuiltInAvailability() }
        .task { await model.watchCloudStatus() }
        .onDisappear { applying?.cancel() }
    }

    private func header(for plan: Intro.BrainPlan) -> (symbol: String, title: String, detail: String) {
        switch plan.layout {
        case .choice:
            ("brain", Intro.Copy.brainTitle, plan.cloud.isListed ? Intro.Copy.brainLineWithCloud
                : (plan.inUse == .privateCloudCompute ? Intro.Copy.pausedCloudLine : Intro.Copy.brainLine))
        case .downloadOnly:
            switch plan.download {
            case .onPhone?: ("checkmark", Intro.Copy.hasBrainTitle, Intro.Copy.hasBrainLine)
            case .arriving?: ("arrow.down", Intro.Copy.gettingBrainTitle, Intro.Copy.gettingBrainLine)
            default: ("arrow.down", Intro.Copy.getBrainTitle, Intro.Copy.gettingBrainLine)
            }
        case .nothingFits:
            ("brain", Intro.Copy.nothingFitsTitle, Intro.Copy.nothingFitsLine)
        }
    }

    private func option<Status: View>(
        _ option: Intro.BrainPlan.Option, title: String, in plan: Intro.BrainPlan,
        selected: Intro.BrainPlan.Option?, @ViewBuilder status: () -> Status
    ) -> some View {
        BrainOptionCard(
            title: title, isRecommended: plan.layout == .choice && plan.recommended == option,
            isSelected: selected == option, showsRadio: plan.layout != .downloadOnly || selected == nil, status: status()
        ) {
            guard applying == nil, model.introBrainPlan.canSelect(option) else { return }
            Haptics.tap()
            confirmationNotice = nil
            selection = option
        }
        .disabled(!plan.canSelect(option) || applying != nil)
        .accessibilityIdentifier(option == .privateCloudCompute ? "intro.brain.cloud" : "intro.brain.\(option.rawValue)")
    }

    private func proceed(with selected: Intro.BrainPlan.Option?) {
        guard applying == nil else { return }
        applying = Task {
            let applied = await model.applyIntroBrain(selected)
            guard !Task.isCancelled else { return }
            applying = nil
            if applied {
                selection = nil // The confirmed BrainChoice now survives Back and relaunch.
                onContinue()
            } else if selected == .privateCloudCompute, model.isUsingPrivateCloudCompute,
                      case let .failed(reason) = model.brainStatus {
                confirmationNotice = reason
            } else {
                confirmationNotice = "That choice isn’t available right now. Review your options before continuing."
            }
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
    /// An already selected download on a phone with no other option keeps
    /// the original plain card; Continue starts it without a second tap.
    let showsRadio: Bool
    /// The grey lines under the title: what it costs, or where it stands.
    let status: Status
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                if showsRadio {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(Font.pd.lead)
                        .foregroundStyle(isSelected ? Color.pd.accentWarm : Color.pd.inkTertiary)
                        .accessibilityHidden(true)
                }

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
                stroke: showsRadio && isSelected ? .pd.accentWarm : .pd.cardStrokeWarm
            )
            .overlay {
                // A second hairline inside the first, for the selected card
                // only: the edge has to say "this one" in grayscale too.
                if showsRadio && isSelected {
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
