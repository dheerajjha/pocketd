import PocketdKit
import SwiftUI

/// The first two minutes of owning this app.
///
/// v1's intro was six screens of prose that named the three abilities and asked
/// for none of them, offered a download, and finished on a menu. Nobody saw the
/// assistant do anything, and the differentiator — that it can read your day —
/// stayed off until somebody went looking for it in Settings.
///
/// This one asks. Eight screens, each with exactly one decision on it, and the
/// three permissions are requested in the order the product actually uses them,
/// each behind a sentence that says what the iOS sheet is about to ask. It ends
/// on the aha: a paragraph about the reader's own day, assembled on the phone
/// from what they just connected, with the brain still downloading behind it.
///
/// The steps are `PocketdKit.OnboardingStep` rather than an `Int`, so that the
/// screen on the analytics funnel and the screen on the phone cannot disagree,
/// and so that inserting a screen is a compiler error in the one place that
/// switches over them rather than an off-by-one in three.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where to leave the person standing. The intro's whole job is to end
    /// somewhere useful, so the destination is the last thing it decides.
    var finish: (AppTab) -> Void

    @State private var step: OnboardingStep = .welcome
    /// Which way the next transition should travel. Held rather than derived
    /// because by the time the transition runs, `step` is already the new one.
    @State private var goingBack = false

    // The decisions, held here rather than on the screens that collect them.
    //
    // Each step is `.id(step)`, which is what makes the slide a slide — and it
    // also destroys the step's own `@State` on the way out. The first build
    // kept the chosen brain on the brain screen, so tapping Back and Next
    // silently reverted somebody's choice of a 386 MB model to the 2 GB
    // recommendation. A decision belongs to the flow, not to the frame it was
    // made in.
    @State private var chosenBrain: ModelRecord?
    @State private var briefTime = RoutineTemplate.morningBrief.defaultTime
    @State private var briefWeekdaysOnly = true

    private static let order = OnboardingStep.allCases

    private var index: Int { Self.order.firstIndex(of: step) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            page
                .id(step)
                .transition(slide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The warm page colour with the onboarding wash over its top
            // ~400pt, which is where the hero block sits. Written here rather
            // than as a Theme helper because this is the only screen in the app
            // that stands on the warm canvas.
            ZStack(alignment: .top) {
                Color.pd.canvasWarm
                PDGradient.canvasWashWarm
                    .frame(height: 400)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
        .animation(reduceMotion ? PDMotion.gentle : PDMotion.standard, value: step)
        .onAppear { model.record(.onboardingStepViewed(step: step)) }
        .onChange(of: step) { _, now in model.record(.onboardingStepViewed(step: now)) }
    }

    // MARK: - Chrome

    /// Back, the stripe, Skip — and, from the calendar screen on, a line
    /// saying the download the brain screen started is still running.
    ///
    /// The stripe shares a row with the two controls rather than sitting under
    /// them, which is what the reference does: with no back button it runs the
    /// full width, and it shortens by exactly the chrome that appears beside it.
    private var chrome: some View {
        VStack(spacing: PDSpacing.s) {
            HStack(spacing: PDSpacing.m) {
                if index > 0 {
                    CircleIconButton(symbol: "chevron.left", label: "Back") { back() }
                }

                ProgressStripe(fraction: Double(index + 1) / Double(Self.order.count))
                    .accessibilityLabel("Step \(index + 1) of \(Self.order.count)")

                if index > 0 {
                    Button { skip() } label: {
                        Text("Skip")
                            .font(Font.pd.caption)
                            .foregroundStyle(Color.pd.inkSecondaryWarm)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PDPressStyle())
                }
            }

            if let downloading, showsDownloadLine {
                MiniLabel(downloading, tint: downloadNeedsAttention ? .pd.caution : .pd.inkSecondaryWarm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, PDSpacing.heroGutter)
        .padding(.top, PDSpacing.xs)
        .animation(PDMotion.gentle, value: downloading)
    }

    /// The transfer the line is about.
    ///
    /// `visibleTransfers` rather than `transfers`, so that a download somebody
    /// dismissed elsewhere stays dismissed and the line goes a few seconds
    /// after it finishes instead of sitting there saying 100%.
    private var bannerTransfer: ModelTransfer? {
        #if DEBUG
        if let staged = OnboardingDownloadStage.transfer { return staged }
        #endif
        return model.visibleTransfers.first
    }

    private var bannerPace: AppModel.DownloadPace? {
        #if DEBUG
        if let staged = OnboardingDownloadStage.pace { return staged }
        #endif
        guard let bannerTransfer else { return nil }
        return model.pace(for: bannerTransfer.id)
    }

    /// "Downloading brain · 34% · about 4 min left", or nothing.
    ///
    /// The estimate is the measured rate, padded — see
    /// `OnboardingDownloadWords.remaining`. A percentage on its own answers
    /// "how far", which is the question people ask once they have decided to
    /// wait; "how long" is the one they ask before deciding, and v1 answered it
    /// nowhere. The audit measured twenty-six minutes on a slow link with
    /// nothing on screen saying so.
    private var downloading: String? {
        guard let transfer = bannerTransfer else { return nil }
        switch transfer.state {
        case .waiting:
            return "Downloading brain · starting"
        case .stopping:
            return "Stopping the download"
        case .running:
            var line = "Downloading brain · \(Int((transfer.fraction * 100).rounded(.down)))%"
            if let left = OnboardingDownloadWords.remaining(bannerPace) {
                line += " · \(left)"
            }
            return line
        // Said here rather than saved for the last screen. The first build
        // showed only active transfers, so a download that failed on the
        // calendar screen went unmentioned for five screens and then appeared
        // as a surprise at the end — which is the opposite of what a status
        // line is for.
        case .paused:
            return "Brain download paused · it can resume later"
        case .failed:
            return "Brain download failed · there is a Try again at the end"
        case .finished:
            return model.loadedModelID == nil ? "Brain downloaded · loading it" : nil
        }
    }

    /// The banner's tint. Amber when something needs a person, grey otherwise.
    private var downloadNeedsAttention: Bool {
        guard let transfer = bannerTransfer else { return false }
        switch transfer.state {
        case .paused, .failed: return true
        case .waiting, .running, .stopping, .finished: return false
        }
    }

    /// The middle of the run. Not on Welcome or Brain, where no download has
    /// been started yet, and not on the last screen, which shows the whole card.
    private var showsDownloadLine: Bool {
        switch step {
        case .calendar, .reminders, .health, .name, .morningBrief: true
        case .welcome, .brain, .ready: false
        }
    }

    private var slide: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let entering: Edge = goingBack ? .leading : .trailing
        let leaving: Edge = goingBack ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: entering).combined(with: .opacity),
            removal: .move(edge: leaving).combined(with: .opacity)
        )
    }

    // MARK: - The screens

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep(onContinue: advance)
        case .brain:
            OnboardingBrainStep(
                chosen: $chosenBrain,
                onContinue: advance,
                onFindSmaller: findSmaller
            )
        case .calendar:
            OnboardingConnectStep(ability: .calendar, onContinue: advance)
        case .reminders:
            OnboardingConnectStep(ability: .reminders, onContinue: advance)
        case .health:
            OnboardingConnectStep(ability: .health, onContinue: advance)
        case .name:
            OnboardingNameStep(onContinue: advance)
        case .morningBrief:
            OnboardingMorningBriefStep(
                time: $briefTime,
                weekdaysOnly: $briefWeekdaysOnly,
                onContinue: advance
            )
        case .ready:
            OnboardingDayStep(onOpen: open)
        }
    }

    // MARK: - Moving

    private func advance() {
        guard index + 1 < Self.order.count else { return }
        goingBack = false
        Haptics.tap()
        step = Self.order[index + 1]
    }

    private func back() {
        guard index > 0 else { return }
        goingBack = true
        Haptics.tap()
        step = Self.order[index - 1]
    }

    // MARK: - Leaving

    /// Every exit goes through here, which is what makes the flag flip and the
    /// analytics event impossible to forget. v1 had the same choke point and
    /// never fired the event; this one is the reason it now does.
    private func leave(via exit: OnboardingExit, to destination: OnboardingDestination, tab: AppTab) {
        model.record(.onboardingCompleted(via: exit, destination: destination))
        model.completeOnboarding()
        finish(tab)
    }

    private func skip() {
        leave(via: .skipped, to: .today, tab: .today)
    }

    private func open() {
        Haptics.success()
        leave(via: .finished, to: .today, tab: .today)
    }

    /// Nothing in the built-in list fits this phone, so the intro hands over to
    /// the one screen that can search for something smaller.
    private func findSmaller() {
        leave(via: .finished, to: .models, tab: .you)
        navigator.openYou(.addBrain)
    }
}

/// The name `RootView` still calls this by.
///
/// The container is `OnboardingFlow` because that is what the spec names and
/// what every other file in this folder is written against; the alias is what
/// keeps the rename out of a file another workstream owns. Delete it when
/// `RootView` is next touched for a reason of its own.
typealias OnboardingView = OnboardingFlow
