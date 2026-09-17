import PocketdKit
import SwiftUI

/// Screen two: the one download this app needs, chosen for you.
///
/// v1 opened with three radio buttons and a byte count, which asks a person who
/// has owned the app for forty seconds to have an opinion about gigabytes. The
/// catalogue already knows which one fits this phone — `recommendedStarter` is
/// the middle tier deliberately, because the smallest is fast and barely
/// coherent — so the screen leads with that one and keeps the list one tap away
/// for anybody who wants it.
///
/// Two edges survive from v1 and both are real: somebody replaying the intro
/// from Settings already has a model and must not be offered another, and a
/// phone that nothing in the catalogue fits has to be told so and handed the
/// search screen rather than a button that cannot work.
struct OnboardingBrainStep: View {
    @Environment(AppModel.self) private var model

    /// Held by the flow, not by this screen. See the note on
    /// `OnboardingFlow.chosenBrain`: `.id(step)` destroys this view's own state
    /// on the way out, and a choice that a Back and a Next silently undoes is
    /// worse than no choice at all.
    @Binding var chosen: ModelRecord?

    var onContinue: () -> Void
    var onFindSmaller: () -> Void

    @State private var showingOptions = false
    @State private var reach = OnboardingReach()

    /// What the download button will actually fetch.
    private var offered: ModelRecord? { chosen ?? model.recommendedStarter }

    var body: some View {
        if let offered {
            recommended(offered)
        } else if !model.installed.isEmpty {
            alreadyHaveOne
        } else {
            nothingFits
        }
    }

    // MARK: - The normal case

    private func recommended(_ record: ModelRecord) -> some View {
        OnboardingPage(
            ornament: .icon("brain"),
            headline: "Give it a brain.",
            secondary: """
            Pocketd runs a small language model on this iPhone. This one fits \
            your phone best.
            """,
            primary: .init("Download and continue") {
                model.download(record)
                onContinue()
            },
            escape: .init("See other options") { showingOptions = true }
        ) {
            PDCard(warm: true) {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    Text(record.displayName)
                        .font(Font.pd.headline)
                        .foregroundStyle(Color.pd.ink)

                    // "Recommended" only while it is the recommendation. Once
                    // somebody has picked a different one from the sheet, the
                    // useful sentence is the fit, not a claim about a choice
                    // they overrode.
                    Text(subtitle(for: record))
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondaryWarm)

                    Text(OnboardingDownloadWords.sizeAndTime(record))
                        .font(Font.pd.monoValue)
                        .foregroundStyle(Color.pd.ink)
                        .padding(.top, PDSpacing.xxs)

                    VStack(alignment: .leading, spacing: PDSpacing.xs) {
                        check(OnboardingDownloadWords.strength(record))
                        check("Works with no signal")
                    }
                    .padding(.top, PDSpacing.xxs)
                }
            }

            // A sentence, not a wall. Somebody who knows they are on data and
            // wants it anyway taps the same button; somebody who did not know
            // now does, before the meter starts.
            if reach.isOnMobileData {
                Callout(
                    symbol: "antenna.radiowaves.left.and.right",
                    text: OnboardingDownloadWords.mobileDataWarning(record),
                    tint: .pd.caution,
                    fill: .pd.cautionSoft
                )
            }
        }
        .sheet(isPresented: $showingOptions) {
            OnboardingBrainOptions(chosen: $chosen)
        }
    }

    private func subtitle(for record: ModelRecord) -> String {
        guard record.id != model.recommendedStarter?.id else {
            return "Recommended for this iPhone"
        }
        switch model.fit(for: record) {
        case .comfortable: return "Fits well on this iPhone"
        case .tight: return "A tight fit on this iPhone"
        case .willNotFit: return "Too big for this iPhone"
        }
    }

    private func check(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.pd.positive)
            Text(text)
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The two edges

    /// Replaying the intro from Settings. Offering a download here would be
    /// answering a question nobody asked.
    private var alreadyHaveOne: some View {
        OnboardingPage(
            ornament: .icon("brain"),
            headline: "It already has a brain.",
            secondary: OnboardingDownloadWords.alreadyInstalled(model.installed),
            primary: .init("Continue", run: onContinue)
        ) {
            EmptyView()
        }
    }

    /// Nothing in the catalogue fits. An honest dead end with a door in it.
    private var nothingFits: some View {
        OnboardingPage(
            ornament: .icon("brain"),
            headline: "Nothing here fits.",
            secondary: """
            Every brain in the built-in list is too big for this iPhone's \
            memory. Pocketd can search for a smaller one instead.
            """,
            primary: .init("Find a smaller one", run: onFindSmaller),
            escape: .init("Not now", run: onContinue)
        ) {
            EmptyView()
        }
    }
}

// MARK: - The options sheet

/// The list v1 led with, demoted to one tap away.
///
/// Three tiers and a plain fit word, because "how much of this phone do you
/// want to spend" is the only real question here and a column of byte counts
/// does not ask it.
struct OnboardingBrainOptions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @Binding var chosen: ModelRecord?

    var body: some View {
        let starters = model.starterModels

        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.m) {
                Text("Other options.")
                    .pdTitle()
                    .foregroundStyle(Color.pd.ink)
                Text("A bigger brain answers better and takes longer to fetch.")
                    .pdSubtitle()
                    .padding(.bottom, PDSpacing.xxs)

                ForEach(Array(starters.enumerated()), id: \.element.id) { position, record in
                    option(record, tier: OnboardingDownloadWords.tier(position, of: starters.count))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.vertical, PDSpacing.l)
        }
        .scrollIndicators(.hidden)
        .background(Color.pd.canvasWarm.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private func option(_ record: ModelRecord, tier: String) -> some View {
        let isChosen = (chosen ?? model.recommendedStarter)?.id == record.id
        return Button {
            Haptics.tap()
            chosen = record
            dismiss()
        } label: {
            PDCard(warm: true) {
                VStack(alignment: .leading, spacing: PDSpacing.xs) {
                    HStack(spacing: PDSpacing.xs) {
                        MiniLabel(tier, tint: .pd.accentWarm)
                        Spacer(minLength: 0)
                        if isChosen {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(Color.pd.accentWarm)
                        }
                    }
                    Text(record.displayName)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                    Text(OnboardingDownloadWords.sizeAndTime(record))
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondaryWarm)
                    StatusPill(
                        OnboardingDownloadWords.fitKind(model.fit(for: record)),
                        OnboardingDownloadWords.fitWord(model.fit(for: record))
                    )
                    .padding(.top, PDSpacing.xxs)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PDRadius.card, style: .continuous))
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel("\(record.displayName), \(tier)")
        .accessibilityValue(OnboardingDownloadWords.fitWord(model.fit(for: record)))
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }
}

// MARK: - The words

/// Everything on these two screens that turns a number into a sentence.
///
/// Its own type because the same three phrasings are needed by the recommended
/// card, the options sheet and the transfer card on the last screen, and three
/// copies of a rounding rule is how "about 4 minutes" and "about 5 minutes"
/// end up on screen at the same time.
enum OnboardingDownloadWords {
    /// Wi-Fi, as a number that does not flatter.
    ///
    /// 5 MB/s is a pessimistic-but-common home connection. Over-promising a
    /// download is the one estimate error people remember, so this rounds *up*
    /// and never speaks in seconds: "about 1 min" is a promise a slow router
    /// can keep, "about 40 seconds" is not.
    static let assumedBytesPerSecond: Double = 5_000_000

    static func sizeAndTime(_ record: ModelRecord) -> String {
        "\(size(record.totalDownloadBytes)) · about \(minutes(record.totalDownloadBytes)) min on Wi-Fi"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func minutes(_ bytes: Int64) -> Int {
        max(1, Int((Double(bytes) / assumedBytesPerSecond / 60).rounded(.up)))
    }

    /// "about 4 min left", from the measured rate rather than the assumed one.
    ///
    /// Padded by a fifth before rounding up, which is the whole trick: an
    /// estimate that runs a little long shrinks as the download proceeds, and
    /// people forgive a download that finishes early. The opposite — a
    /// confident countdown that has to grow — is the single thing research
    /// finds users rate worst in a progress indicator, so the padding is what
    /// makes "revise upward rarely" true without any state to remember.
    ///
    /// Never seconds. "About 40 seconds" is a promise a slow router cannot
    /// keep, and the floor of one minute is cheaper than being wrong.
    static func remaining(_ pace: AppModel.DownloadPace?) -> String? {
        guard let seconds = pace?.secondsRemaining, seconds > 0 else { return nil }
        let padded = seconds * 1.2 / 60
        // An hour and a half of download is a number nobody reads as a
        // countdown, so past an hour it stops pretending to be one.
        guard padded <= 90 else { return "over an hour left" }
        return "about \(max(1, Int(padded.rounded(.up)))) min left"
    }

    /// The one sentence that turns a download somebody was given into one they
    /// chose. Never a block: the button underneath still works.
    static func mobileDataWarning(_ record: ModelRecord) -> String {
        "On mobile data. This is about \(size(record.totalDownloadBytes)); Wi-Fi is quicker and cheaper."
    }

    /// The one claim a brain earns by being big enough to use tools.
    ///
    /// Asked of the catalogue rather than of the loaded engine, because at this
    /// point nothing is loaded — the file is not even on the phone. The
    /// declaration is the only evidence that exists, and the size test is the
    /// same one `ToolGate` applies later when the weights are actually here.
    static func strength(_ record: ModelRecord) -> String {
        canUseTools(record)
            ? "Understands your calendar and reminders"
            : "Answers questions and drafts text"
    }

    static func canUseTools(_ record: ModelRecord) -> Bool {
        switch ToolGate.declaredSupport(for: record) {
        case .yes:
            true
        case .no:
            false
        case .unknown:
            (ToolGate.parameterCount(fromSizeLabel: record.parameters) ?? 0)
                > ToolGate.minimumParametersInBillions
        }
    }

    /// Quick, Balanced, Smart — the axis, in words rather than in gigabytes.
    static func tier(_ position: Int, of count: Int) -> String {
        guard count > 1 else { return "Recommended" }
        switch position {
        case 0: return "Quick"
        case count - 1: return "Smart"
        default: return "Balanced"
        }
    }

    static func fitWord(_ fit: DeviceBudget.Fit) -> String {
        switch fit {
        case .comfortable: "Fits well"
        case .tight: "Tight fit"
        case .willNotFit: "Too big for this iPhone"
        }
    }

    static func fitKind(_ fit: DeviceBudget.Fit) -> StatusPill.Kind {
        switch fit {
        case .comfortable: .positive
        case .tight: .caution
        case .willNotFit: .neutral
        }
    }

    /// "You already have Qwen3 1.7B on this phone." — the replay case.
    static func alreadyInstalled(_ installed: [ModelRecord]) -> String {
        guard let first = installed.first else {
            return "There is already one on this phone, so there is nothing to fetch."
        }
        if installed.count == 1 {
            return "You already have \(first.displayName) on this phone, so there is nothing to fetch."
        }
        return "You already have \(installed.count) on this phone, so there is nothing to fetch."
    }
}

#Preview("Brain light") {
    OnboardingBrainStepPreview()
}

#Preview("Brain dark") {
    OnboardingBrainStepPreview().preferredColorScheme(.dark)
}

private struct OnboardingBrainStepPreview: View {
    @State private var chosen: ModelRecord?

    var body: some View {
        OnboardingStepPreview {
            OnboardingBrainStep(chosen: $chosen, onContinue: {}, onFindSmaller: {})
        }
        .environment(AppModel())
    }
}
