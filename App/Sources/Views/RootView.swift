import PocketdKit
import StoreKit
import SwiftUI
#if DEBUG
import UserNotifications
#endif

/// The intro, desk mode, or the app.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var analyticsStarted = false
    @State private var needsForegroundEvent = false

    var body: some View {
        content
            .onChange(of: IntentInbox.questions.awaitingPresentation(in: model.currentConversationID)?.id, initial: true) { _, _ in
                // There is no composer during setup or Desk Mode. Preserve the
                // words as an ordinary draft if the app is closed here; never
                // persist the permission to submit the Shortcut on relaunch.
                guard model.needsOnboarding || model.deskMode,
                      let question = IntentInbox.questions.awaitingPresentation(in: model.currentConversationID) else { return }
                Task { await model.preserveSetupShortcut(question) }
            }
        #if DEBUG
        .onAppear { IntentInbox.stageLaunchQuestionOnce() }
        #endif
        .onAppear {
            // Group can appear again when the intro or Desk Mode replaces the shell.
            guard !analyticsStarted else { return }
            analyticsStarted = true
            updateAnalyticsContext()
            foreground()
            recordNavigationScreen(analyticsScreen)
        }
        .onChange(of: analyticsScreen) { _, screen in
            updateAnalyticsContext()
            recordNavigationScreen(screen)
        }
        .onChange(of: colorScheme) { _, _ in updateAnalyticsContext() }
        .onChange(of: typeSize) { _, _ in updateAnalyticsContext() }
        .onChange(of: model.deskMode) { _, on in
            updateAnalyticsContext()
            if on { model.record(.featureUsed(feature: .deskMode, surface: .app)) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { needsForegroundEvent = true }
            if phase == .active, needsForegroundEvent {
                needsForegroundEvent = false
                updateAnalyticsContext()
                foreground()
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { _ = await NotificationCentre.shared.authorizationStatus() }
        }
    }

    @ViewBuilder private var content: some View {
        if model.needsOnboarding {
            OnboardingViewBridge().transition(.opacity)
        } else if model.deskMode {
            DeskModeView().transition(.opacity)
        } else {
            Shell().transition(.opacity)
        }
    }

    private func updateAnalyticsContext() {
        // Desk Mode uses a black canvas and fixed pale ink, regardless of system appearance.
        model.productAnalytics.context.appearance = model.deskMode && !model.needsOnboarding
            ? .dark : (colorScheme == .dark ? .dark : .light)
        model.productAnalytics.context.typeSize = typeSize.isAccessibilitySize ? .accessibility
            : (typeSize >= .xxxLarge ? .large : .standard)
    }

    private func foreground() {
        NotificationCentre.shared.invalidateAnalyticsStatus()
        model.record(.appForegrounded)
    }

    private func recordNavigationScreen(_ screen: AnalyticsScreen) {
        // These screens also have ordinary local-state entry points. Their
        // actual views count appearances, once regardless of the routing door.
        guard screen != .privacyDetails, screen != .routineResult else { return }
        model.record(.screenViewed(screen: screen))
    }

    private var analyticsScreen: AnalyticsScreen {
        if model.needsOnboarding { return .onboarding }
        if model.deskMode { return .deskMode }
        if navigator.isAskPresented { return .ask }
        guard let route = navigator.path.last else { return .today }
        switch route {
        case .routines: return .routines
        case .you: return .you
        case let .detail(detail):
            return switch detail {
            case .day: .day
            case .reminders: .reminders
            case .sleep: .sleep
            case .activity: .activity
            case .routineResult: .routineResult
            }
        case let .youPage(page):
            return switch page {
            case .brain: .brain
            case .addBrain: .addBrain
            case .brainAdvanced: .brainAdvanced
            case .devices: .devices
            case .deskMode: .devices // this legacy route renders OtherDevicesView
            case .privacy: .privacy
            case .privacyDetails: .privacyDetails
            case .settings: .settings
            case .instructions: .instructions
            case .diagnostics: .diagnostics
            }
        }
    }
}

/// Hands the intro a destination in the `Navigator`'s vocabulary.
///
/// A separate view so `RootView` does not have to hold a `Navigator` it only
/// needs in one branch, and so the seam where the intro's `(AppTab) -> Void`
/// meets the `Navigator` is one line.
private struct OnboardingViewBridge: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        OnboardingView(finish: { navigator.go($0) })
    }
}

// MARK: - The shell

/// One home: Today at the root of a single stack, everything else pushed onto
/// it, and the conversation in a sheet over whatever is showing.
///
/// There is no tab bar, and that removed most of what used to live here. The
/// floating capsule needed a 96pt clearance on every scrolling screen, a
/// reserved strip under every screen that ended in a control, and a keyboard
/// watcher so that strip could give way to the keys — and it still sat on top
/// of tiles, routine footers and "Try asking". Pushed screens get the system's
/// navigation bar instead, which is also what keeps scrolled content out from
/// under the status bar.
///
/// What is left is the plumbing that has to sit above every screen: the toasts,
/// the review prompt, and the four ways something outside the app can move it —
/// a URL, a Siri question, the Control Center button, a notification tap.
private struct Shell: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    /// Apple's own prompt. There is no way to ask for it outside a view, and no
    /// way to find out whether it was shown — see `reviewPromptShown()`.
    @Environment(\.requestReview) private var requestReview

    @State private var toasts = ToastCenter()
    @State private var askToasts = ToastCenter()

    /// How far above the bottom of the screen a toast sits.
    ///
    /// Clear of a pinned composer — a suggestion chip, the gap under it, the
    /// field, and the bar's own padding — because Today and every detail page
    /// end in one, and a toast saying "Ticked off · Undo" on top of the field is
    /// a toast nobody can reach. Built from the same tokens the composer is, so
    /// the two move together.
    private static let toastClearance: CGFloat =
        PDMetric.minHitTarget + PDSpacing.s + PDMetric.askBarHeight + PDSpacing.xs * 3

    var body: some View {
        @Bindable var navigation = navigator

        NavigationStack(path: $navigation.path) {
            TodayView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .sheet(isPresented: $navigation.isAskPresented) {
            conversation
        }
        .environment(toasts)
        .toast(toasts, bottomInset: Self.toastClearance)
        // A question left by `AskPocketdIntent`, a tap on the "Ask Pocketd"
        // control, or a tap on a routine's notification. Collected here and not
        // where each one arrives, because on a cold launch every one of them
        // arrives before this view exists, so there is nowhere to put it yet.
        //
        // On appearance AND on becoming active: the first covers a launch that
        // one of them caused, the second covers the app already being in
        // memory. Each source clears itself as it is read, which is what stops
        // a scene that becomes active twice from acting twice.
        .onAppear { collectArrivals() }
        .onChange(of: navigator.isAskPresented) { _, shown in
            if !shown { model.askComposerFocusRequested = false; askToasts.dismiss() }
        }
        .task(id: readyAskID) {
            if let request = navigator.pendingAsk, readyAskID == request.id { await openAsk(request) }
        }
        .onChange(of: navigator.pendingAsk?.id) { _, _ in
            if model.isGenerating { explainWaitingAsk() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { collectArrivals() }
            if phase == .background, let request = navigator.pendingAsk {
                switch request.action {
                case .shortcut: break
                default: navigator.pendingAsk = nil
                }
            }
        }
        // An intent can also arrive with the scene already active, or before
        // its saved conversation is restored. All paths claim the same ID.
        .onChange(of: IntentInbox.questions.awaitingPresentation(in: model.currentConversationID)?.id) { _, id in
            if id != nil, scenePhase == .active { collectIntentQuestion() }
        }
        .onChange(of: model.isGenerating) { _, busy in
            if busy { explainWaitingAsk() } else if scenePhase == .active { model.sendShortcutIfReady() }
        }
        .onChange(of: IntentInbox.questions.isWaiting ? model.brainStatus : nil) { _, _ in
            if scenePhase == .active { model.sendShortcutIfReady() }
        }
        // A notification tapped while the app is already on screen: the
        // delegate sets this and nothing else would notice.
        .onChange(of: NotificationCentre.shared.requestedTask) { _, task in
            if task != nil { collectRoutineTap() }
        }
        // A widget tap, or a Shortcut. `DeepLink` is the whole parser and
        // anything it does not recognise is `nil`, so an unknown URL does
        // nothing at all rather than landing somewhere surprising.
        .onOpenURL { url in
            guard let link = DeepLink(url: url) else { return }
            model.record(.featureUsed(feature: .deepLink, surface: .link))
            navigator.follow(link)
        }
        // Asked from here rather than from the model, because a review request
        // is a SwiftUI environment action and only a view holds one. The model
        // decides WHEN — see `ReviewMoment` — and this is only the hand that
        // raises it.
        .onChange(of: model.wantsReviewPrompt) { _, wants in
            guard wants else { return }
            requestReview()
            model.reviewPromptShown()
        }
        #if DEBUG
        .task {
            await ArrivalStage.stageIfRequested(model)
            await TourStage.runIfRequested(model: model, navigator: navigator) // -pocketd.tour: Diagnostics/TourStage.swift
        }
        #endif
    }

    // MARK: Destinations

    /// Every screen that can be pushed onto Today. None of them brings a
    /// `NavigationStack` of its own: one pushed inside this one would put a
    /// second navigation bar on the screen, and a stack bound to a typed path
    /// traps on a link it cannot hold.
    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case let .detail(kind):
            DetailView(kind: kind)
        case .routines:
            RoutinesView()
        case .you:
            YouView()
        case let .youPage(page):
            YouRouteView(route: page)
        }
    }

    /// The conversation, presented over whatever is showing.
    ///
    /// Bare: it brings its own `NavigationStack` — the one exception to the
    /// rule above, because a sheet is a separate presentation with its own
    /// toolbar and history — and its own toasts, since anything raised in here
    /// would otherwise be drawn on this view's overlay, underneath the sheet.
    private var conversation: some View {
        ConversationSheet(toasts: askToasts)
    }

    // MARK: Arrivals

    /// Opening the current transcript to read or stop it is always available.
    /// A different thread or an incoming question waits for the live answer.
    private var readyAskID: UUID? {
        guard scenePhase == .active, model.hasRestoredConversations, !navigator.isHistoryPresented,
              let request = navigator.pendingAsk else { return nil }
        if model.isGenerating, !model.canOpenDuringReply(request) { return nil }
        return request.id
    }

    private func explainWaitingAsk() {
        guard let request = navigator.pendingAsk, readyAskID == nil else { return }
        if case .voice = request.action {
            // Don't turn on a microphone minutes after the tap.
            navigator.pendingAsk = nil
            toasts.show("Pocketd is answering. Try the microphone when it's finished.")
        } else {
            toasts.show("Pocketd will open that conversation when this answer is finished.")
        }
    }

    private func openAsk(_ request: AskEntryRequest) async {
        func valid() -> Bool {
            guard !Task.isCancelled, navigator.pendingAsk?.id == request.id, scenePhase == .active,
                  !navigator.isHistoryPresented else { return false }
            if case let .shortcut(question) = request.action { return IntentInbox.questions.isOpening(question.id) }
            return true
        }
        let outcome = await model.prepareAsk(request, while: valid)
        if outcome == .saveFailed {
            let visible = valid()
            if case let .shortcut(question) = request.action { IntentInbox.questions.abandonOpening(question.id) }
            if navigator.finishPendingAsk(request.id), visible {
                (navigator.isAskPresented ? askToasts : toasts).showSaveFailure()
            }
            return
        }
        guard case let .opened(thread) = outcome, valid(), model.currentConversationID == thread else {
            if valid(), navigator.finishPendingAsk(request.id), case let .shortcut(question) = request.action {
                IntentInbox.questions.abandonOpening(question.id)
            }
            return
        }
        guard navigator.finishPendingAsk(request.id) else { return }
        switch request.action {
        case .keyboard:
            navigator.presentAsk(in: thread, focus: true)
        case .voice:
            // A control can also arrive over an explicitly open draft.
            if model.draft.isEmpty && model.attachments.isEmpty { model.askComposerFocusRequested = true }
            navigator.isAskPresented = true
        case let .draft(text):
            if !model.deliver(text, in: thread) { askToasts.show(ConversationDraft.occupiedMessage, seconds: 4) }
            navigator.presentAsk(in: thread, focus: true)
        case let .send(text, cloud):
            if !model.deliver(text, in: thread, sendNow: true, usingCloud: cloud) { askToasts.show(ConversationDraft.occupiedMessage, seconds: 4) }
            navigator.presentAsk(in: thread, focus: !model.draft.isEmpty)
        case let .shortcut(question):
            model.openShortcutQuestion(question)
            navigator.presentAsk(in: thread, focus: !model.draft.isEmpty)
        }
    }

    private func collectArrivals() {
        collectIntentQuestion()
        collectRoutineTap()
    }

    /// Puts a question from Siri or a Shortcut into the conversation, or opens
    /// it for the "Ask Pocketd" control.
    ///
    /// Opening the sheet is navigation only. In particular, don't make a
    /// second, unqualified `send: true` handoff from the question's text.
    private func collectIntentQuestion() {
        // A tap on the control, independent of any Siri question below — see
        // AskLaunch. It asks for the composer, and the microphone where the
        // phone can listen on-device.
        if AskLaunch.take() != nil {
            model.record(.featureUsed(feature: .controlAsk, surface: .control))
            navigator.requestAsk(.main, .voice)
        }
        guard scenePhase == .active else { return }
        if let question = IntentInbox.questions.takeForPresentation(in: model.currentConversationID) {
            model.record(.featureUsed(feature: .intentAsk, surface: .intent))
            navigator.requestAsk(.shortcut(question.id), .shortcut(question))
        } else {
            model.sendShortcutIfReady()
        }
    }

    /// Takes a tap on a routine's notification to where the model says it
    /// goes: Today for a brief (being rewritten there), the routine's result
    /// page for anything else, the list when the routine has since been
    /// deleted.
    private func collectRoutineTap() {
        Task {
            guard let destination = await model.takeRoutineTap() else { return }
            model.record(.featureUsed(feature: .routineNotification, surface: .notification))
            navigator.follow(destination)
        }
    }
}

// MARK: - Staging arrivals from outside

#if DEBUG
/// Stages the things that reach the shell from outside the app, so each path
/// can be walked on a simulator — where no routine fires while anyone is
/// watching, `simctl push` hangs on an unsigned build, and Siri and the
/// Control Center gallery cannot be driven from a script.
///
///     xcrun simctl launch <udid> dev.pocketd.app -pocketd.routineBanner nudge   # or: brief
///     # then leave the app and tap the banner (or the app open: it shows over it)
///     xcrun simctl launch <udid> dev.pocketd.app -pocketd.stageIntent "What's on tomorrow?"
///     xcrun simctl launch <udid> dev.pocketd.app -pocketd.stageControl
///     # each of these two waits in its inbox; leave the app and come back
///
/// Each one writes exactly what the real thing writes and nothing more: the
/// banner carries only the routine's id, the question goes through
/// `IntentInbox.deliver` as `AskPocketdIntent.perform()` does, and the control
/// leaves `OpenAskIntent`'s marker. The shell then has to find them by itself.
/// Entirely inside `#if DEBUG`.
@MainActor
enum ArrivalStage {
    private static var staged = false
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func stageIfRequested(_ model: AppModel) async {
        guard !staged else { return }
        staged = true
        if let question = value(after: "-pocketd.stageIntent") {
            IntentInbox.deliver(question)
        }
        if arguments.contains("-pocketd.stageControl") {
            AskLaunchRequest.leave(mode: .voice)
        }
        if arguments.contains("-pocketd.routineBanner") {
            await postRoutineBanner(brief: value(after: "-pocketd.routineBanner") == "brief", model)
        }
    }

    /// `brief` picks the first brief routine; otherwise the first routine
    /// with a result page of its own.
    private static func postRoutineBanner(brief wantsBrief: Bool, _ model: AppModel) async {
        await model.loadScheduledTasks()
        let task = model.scheduledTasks.first { task in
            if case .brief = task.body { return wantsBrief }
            return !wantsBrief
        }
        guard let task else { return }

        let centre = UNUserNotificationCenter.current()
        _ = try? await centre.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = wantsBrief ? "Your morning brief is ready." : "Tap to see what it found."
        content.userInfo = [NotificationCentre.taskKey: task.id.uuidString]
        let request = UNNotificationRequest(
            identifier: "stage-\(task.id.uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 6, repeats: false)
        )
        try? await centre.add(request)
    }
}
#endif
