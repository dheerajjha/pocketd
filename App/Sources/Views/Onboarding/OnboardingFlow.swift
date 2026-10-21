import PocketdKit
import SwiftUI
import UserNotifications

/// The first minute of owning this app.
///
/// Five screens, each with one thing on it, and nothing technical asked:
///
/// 1. **Meet Pocketd** — what it is, three promises, and the one sentence
///    about anonymous usage counts.
/// 2. **Choose how Pocketd thinks** — built into iPhone, or a private
///    download; the recommended one is already selected.
/// 3. **Connect your day** — Calendar, Reminders and Health, each optional,
///    each asked from its own row.
/// 4. **Get your day every morning** — a time and a switch, or "Not now".
/// 5. **You're all set** — the tally, an optional name, one line saying
///    whether Pocketd is ready — and Today.
///
/// It replaces eight screens: three of them permission pages with a Connect, a
/// Continue and a Skip each; a top-right Skip that silently ended everything;
/// a gigabyte decision with model names on screen two; and a last screen that
/// queued a question for a brain it said was already there. A first run has no
/// Skip at all. Every optional screen has its own quiet way past ("Not now", or
/// a Continue that never waits on anything), and whatever was skipped is
/// offered again in context by Today's Off tiles. A replay from You has a Close
/// on every screen, because somebody looking again has nothing to finish.
///
/// A complete run is nine taps of Pocketd's own, plus whatever iOS's sheets
/// ask and the name.
///
/// The screens are `Intro.Screen` rather than an `Int`, so that inserting one
/// is a compiler error in the one switch below rather than an off-by-one in
/// three places, and each reports the funnel step it took the place of.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where to leave the person standing — Today, always, now. Kept as a
    /// closure taking a destination because that is the seam `RootView` calls.
    var finish: (AppTab) -> Void

    @State private var screen: Intro.Screen = .meet
    /// Which way the next transition travels. Held rather than derived,
    /// because by the time the transition runs `screen` is already the new one.
    @State private var goingBack = false

    // The decisions, held here rather than on the screens that collect them.
    //
    // Each screen is `.id(screen)`, which is what makes the slide a slide — and
    // it also destroys that screen's own `@State` on the way out. A choice kept
    // on the screen that made it is silently reverted by Back and Next, so
    // anything somebody chose or typed belongs to the flow.
    @State private var brainSelection: Intro.BrainPlan.Option?
    @State private var briefTime = RoutineTemplate.morningBrief.defaultTime
    @State private var briefWeekdaysOnly = true
    @State private var name = ""
    /// Whether iOS has never been asked about notifications. Read once, when
    /// the intro opens, for the morning screen's primer — see there.
    @State private var notificationsUndecided: Bool?

    private static let order = Intro.Screen.allCases

    private var index: Int { Self.order.firstIndex(of: screen) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            page
                .id(screen)
                .transition(slide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The warm page colour with the onboarding wash over its top
            // ~400pt, where the hero block sits. The only screen in the app
            // that stands on the warm canvas.
            ZStack(alignment: .top) {
                Color.pd.canvasWarm
                PDGradient.canvasWashWarm
                    .frame(height: 400)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
        .animation(reduceMotion ? PDMotion.gentle : PDMotion.standard, value: screen)
        .onAppear {
            model.record(.onboardingStepViewed(step: screen.analyticsStep))
            // A replay starts from what is already true: the name somebody
            // gave, and the morning brief they already have.
            name = model.profile.name
            if let existing = model.introExistingMorningBrief {
                briefTime = existing.time
                briefWeekdaysOnly = existing.weekdaysOnly
            }
        }
        .onChange(of: screen) { _, now in
            model.record(.onboardingStepViewed(step: now.analyticsStep))
        }
        .task {
            notificationsUndecided = await NotificationCentre.shared.authorizationStatus() == .notDetermined
        }
    }

    // MARK: - Chrome

    /// Back and the stripe. The stripe runs the full width on the first
    /// screen and shortens by exactly the back button beside it after that.
    private var chrome: some View {
        HStack(spacing: PDSpacing.m) {
            if index > 0 {
                CircleIconButton(symbol: "chevron.left", label: "Back") { back() }
            }
            ProgressStripe(fraction: Double(index + 1) / Double(Self.order.count))
                .accessibilityLabel("Step \(index + 1) of \(Self.order.count)")
                .accessibilityValue("")
            // A replay from You can be closed from any screen, the first one
            // included. A first run cannot: it has no Skip.
            if model.introIsReplay {
                CircleIconButton(symbol: "xmark", label: "Close") { close() }
            }
        }
        .frame(minHeight: PDMetric.minHitTarget)
        .padding(.horizontal, PDSpacing.heroGutter)
        .padding(.top, PDSpacing.xs)
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
        switch screen {
        case .meet:
            OnboardingMeetStep(onContinue: advance)
        case .brain:
            OnboardingBrainStep(selection: $brainSelection, onContinue: advance)
        case .connect:
            OnboardingConnectStep(onContinue: advance)
        case .everyMorning:
            OnboardingMorningBriefStep(
                time: $briefTime,
                weekdaysOnly: $briefWeekdaysOnly,
                notificationsUndecided: notificationsUndecided,
                onContinue: advance
            )
        case .allSet:
            OnboardingAllSetStep(name: $name, onOpen: open)
        }
    }

    // MARK: - Moving

    private func advance() {
        guard index + 1 < Self.order.count else { return }
        goingBack = false
        // No haptic here: every button that moves on already taps once.
        screen = Self.order[index + 1]
    }

    private func back() {
        guard index > 0 else { return }
        goingBack = true
        screen = Self.order[index - 1]
    }

    /// Closes a replay where it was opened, under You.
    private func close() {
        model.leaveIntroReplay()
        finish(.you)
    }

    /// The way out of a first run. Saves the name, records the funnel's last
    /// event, flips the flag and lands on Today.
    private func open() {
        Haptics.success()
        model.finishIntro(name: name)
        finish(.today)
    }
}

/// The name `RootView` calls this by. Kept so the shell's call site does not
/// have to change in step with this folder.
typealias OnboardingView = OnboardingFlow

#Preview("Intro light") {
    OnboardingFlow(finish: { _ in })
        .environment(AppModel())
}

#Preview("Intro dark") {
    OnboardingFlow(finish: { _ in })
        .environment(AppModel())
        .preferredColorScheme(.dark)
}
