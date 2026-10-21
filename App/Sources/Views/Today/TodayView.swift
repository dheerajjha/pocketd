import PocketdKit
import SwiftUI
import UserNotifications

/// The screen the app opens to, every morning: your day, in plain words.
///
/// Top to bottom it is a paragraph, at most two notes, four verdicts, and one
/// question. The paragraph is what a person reads; the notes are only ever
/// something that changed or something only they can do; the tiles are what
/// they glance at ("Rested", "1 overdue"), each one tap from the page with the
/// numbers; and the composer at the bottom is where anything else gets asked. Nothing here names a brain, a model or a
/// download: the most the machinery ever says is "Getting ready".
///
/// Nothing on this screen needs a brain. The tiles and the paragraph both come
/// off `TodaySnapshot`, read from EventKit and HealthKit alone, so a phone with
/// nothing downloaded still opens on a real day.
///
/// The day is read through `refreshBrief`'s gate: arriving here does not read
/// EventKit again unless the reading is old or something marked it stale (a
/// permission, the calendar changing, the app coming back to the front). Pull
/// to refresh is the one way to insist.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts

    /// One synthesizer for this screen, owned here rather than by the model:
    /// speech is a property of what is on screen, and a brief being read
    /// aloud stops when the screen does.
    @State private var reader = ReadAloud()

    /// Whether the page has scrolled up under the status bar, for the
    /// backdrop that keeps it off the clock before iOS 26.
    @State private var isScrolledUnderStatusBar = false

    /// Whether the routines on disk have been read this launch. The morning
    /// brief offer waits for it: before then "no morning brief" only means
    /// "not read yet", and the card would flash on and off.
    @State private var routinesKnown = false

    @AppStorage("pocketd.today.morningBriefOfferDismissed") private var morningBriefOfferDismissed = false
    /// Comma-separated `Ability` raw values whose "off in iOS Settings" card
    /// was put away.
    @AppStorage("pocketd.today.refusalsDismissed") private var refusalsDismissed = ""

    private var briefing: BriefingState { model.briefing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                // In the scroll view rather than pinned above it: the wash is
                // on the screen and stays put, and the header scrolls away,
                // which gives the page its whole height back once somebody is
                // reading rather than arriving.
                HeroHeader(date: DemoClock.now, wash: false) {
                    HeaderCapsule(
                        initial: model.profile.initial,
                        showsBadge: !model.unreadRoutineResults.isEmpty,
                        onRoutines: { navigator.go(.routines) },
                        onYou: { navigator.go(.you) }
                    )
                }

                BriefLead(
                    text: briefText,
                    name: model.profile.greetingName,
                    status: statusLine,
                    reader: reader,
                    onReadAloud: { model.markReadAloud() }
                )
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, -PDSpacing.xs)
                .pdStaggerIn(0)

                // News above the tiles: a routine's result, a source iOS
                // refused, a brain that cannot answer. Below them, on an
                // iPhone 17 Pro with a brief of four lines, such a card sat
                // exactly behind the chip and the composer at rest — news
                // nobody saw until they scrolled. It is rare, so on most
                // mornings this is empty and the tiles sit under the brief.
                feed(placement: .aboveTiles)
                    .padding(.horizontal, PDSpacing.gutter)
                    .pdStaggerIn(1)

                tiles
                    .padding(.horizontal, PDSpacing.gutter)
                    .padding(.top, PDSpacing.xxs)
                    .pdStaggerIn(2)

                // The morning-brief offer below them. It is an offer rather
                // than news, and above the tiles it pushed Sleep and Activity
                // under the composer every morning until somebody set it up.
                feed(placement: .belowTiles)
                    .padding(.horizontal, PDSpacing.gutter)
                    .pdStaggerIn(3)
            }
            .padding(.top, PDSpacing.xxs)
            .padding(.bottom, PDSpacing.l)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > PDSpacing.xs
        } action: { _, scrolled in
            isScrolledUnderStatusBar = scrolled
        }
        .modifier(StatusBarEdge(isScrolled: isScrolledUnderStatusBar))
        // The one way to insist on a fresh reading — and the one way to ask a
        // brain to write the brief again. It returns once the template is
        // published; "Writing…" carries on underneath while a brain rewrites.
        .refreshable { await model.refreshBrief(force: true) }
        // Wash first, canvas second, and the order is the whole effect:
        // `background` puts each new layer behind the last, so the flat canvas
        // applied afterwards sits under the gradient rather than over it.
        .pdHeroWash()
        .pdCanvas()
        .contextComposer(composer)
        .task {
            if !routinesKnown {
                await model.loadScheduledTasks()
                routinesKnown = true
            }
            // Through the gate: returns at once when the day was read in the
            // last few minutes and nothing has marked the reading stale.
            await model.refreshBrief()
        }
        // AVSpeechSynthesizer keeps talking to an empty room otherwise.
        .onDisappear { reader.stop() }
        .onChange(of: reader.isSpeaking) { _, speaking in
            briefing.isReadingAloud = speaking
        }
    }

    // MARK: - The brief

    /// The paragraph on screen. While a brain writes, the one already there —
    /// the template or the last brain's — stays, and only the line under it
    /// changes. Before the first reading lands, the greeting alone: it is the
    /// one sentence about today that is true before anything has been read.
    private var briefText: String {
        if let text = briefing.brief?.text, !text.isEmpty { return text }
        let greeting = TimeOfDayKind.from(now: DemoClock.now).greeting
        return model.profile.greetingName.map { "\(greeting), \($0)." } ?? "\(greeting)."
    }

    /// The status line, only when it is true. "Writing…" while a brain
    /// rewrites the paragraph; "Getting ready" while one is arriving or
    /// loading. Never a brain's name, a size or a percentage.
    private var statusLine: String? {
        if briefing.phase == .streaming { return "Writing…" }
        switch model.brainStatus {
        case let .arriving(_, minutesLeft?): return "Getting ready · about \(minutesLeft) min"
        case .arriving, .loading: return "Getting ready"
        case .none, .ready, .cannotReadYourDay, .failed: return nil
        }
    }

    // MARK: - Tiles

    /// Redrawn once a minute, because "In 2h 10m" is a countdown and a stored
    /// one would still be saying it at half past eleven. A `TimelineView`
    /// stops when the screen goes away, which a repeating sleep would not.
    private var tiles: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let unread = isUnread
            VerdictGrid {
                ForEach(model.tileVerdicts(now: DemoClock.now)) { verdict in
                    let waiting = unread && !verdict.isOff
                    VerdictTile(
                        label: verdict.tile.label,
                        symbol: Self.symbol(for: verdict.tile),
                        status: verdict.status,
                        tone: waiting ? .neutral : Self.tone(of: verdict),
                        sentence: verdict.sentence,
                        accessibilityHint: Self.hint(for: verdict),
                        spokenLabel: waiting ? "\(verdict.tile.label): reading" : verdict.accessibilityLabel,
                        action: waiting ? nil : action(for: verdict)
                    )
                    .redacted(reason: waiting ? .placeholder : [])
                }
            }
        }
    }

    /// Nothing has been read yet this launch, and no reading from earlier
    /// today was on disk to start from.
    ///
    /// The second or so of a first launch of the day, before EventKit has
    /// answered. A connected calendar with nothing read would otherwise say
    /// "Free" and a reminders list "All clear" — both false, for exactly the
    /// moment someone is looking — so those tiles hold their shape and say
    /// nothing until the day is read. An "Off" tile is already true, and shows.
    private var isUnread: Bool {
        briefing.lastRefresh == nil
            && !Calendar.current.isDate(briefing.snapshot.generatedAt, inSameDayAs: DemoClock.now)
    }

    /// What the verdict says a tap does. Never a question to a brain and
    /// never a trip to You: a readable source opens its page, an off one
    /// goes through the one connect door, which raises the iOS sheet right
    /// here (or opens Settings, when iOS has already said no).
    private func action(for verdict: TileVerdict) -> (() -> Void)? {
        switch verdict.action {
        case .openDetail: { open(verdict.tile) }
        case .connect, .openSettings: { connect(verdict.tile) }
        case .none: nil
        }
    }

    private func open(_ tile: TileVerdict.Tile) {
        model.record(.todayTileTapped(tile: Self.analyticsTile(tile)))
        switch tile {
        case .upNext: navigator.open(.day)
        case .due: navigator.open(.reminders)
        case .sleep: navigator.open(.sleep)
        case .activity: navigator.open(.activity)
        }
    }

    private func connect(_ tile: TileVerdict.Tile) {
        let ability = Self.ability(for: tile)
        model.record(.todayTileTapped(tile: Self.analyticsTile(tile)))
        Task {
            let outcome = await model.connect(ability, from: .today)
            // "Connected" goes unsaid: the tile filling in is the news. Only a
            // sentence the person needs — off in Settings, blocked — is shown.
            if let sentence = sentence(for: outcome, ability) {
                toasts.show(sentence, symbol: "exclamationmark.circle", tint: .pd.caution)
            }
        }
    }

    /// What to say after the door, if anything.
    ///
    /// Health that iOS could not be asked about says Health's own sentence —
    /// the same one the intro's Health row and the conversation say — rather
    /// than the door's generic one, so the one failure has one wording.
    private func sentence(for outcome: ConnectOutcome, _ ability: Ability) -> String? {
        if ability == .health, outcome == .couldNotAsk, case let .requestFailed(reason) = model.healthAvailability {
            return reason
        }
        return outcome.sentence(for: ability)
    }

    private static func symbol(for tile: TileVerdict.Tile) -> String {
        switch tile {
        case .upNext: "calendar"
        case .due: "checklist"
        case .sleep: "bed.double"
        case .activity: "figure.walk"
        }
    }

    /// The Kit names the feeling; the design picks the colour.
    private static func tone(of verdict: TileVerdict) -> VerdictTile.Tone {
        if verdict.isOff { return .off }
        switch verdict.tone {
        case .good: return .positive
        case .warning: return .caution
        case .neutral: return .neutral
        }
    }

    private static func hint(for verdict: TileVerdict) -> String? {
        switch verdict.action {
        case .openDetail:
            switch verdict.tile {
            case .upNext: "Shows your day"
            case .due: "Shows your reminders"
            case .sleep: "Shows your sleep"
            case .activity: "Shows your steps"
            }
        case .connect: "Turns on \(ability(for: verdict.tile).title)"
        case .openSettings: "Opens Settings"
        case .none: nil
        }
    }

    private static func ability(for tile: TileVerdict.Tile) -> Ability {
        switch tile {
        case .upNext: .calendar
        case .due: .reminders
        case .sleep, .activity: .health
        }
    }

    private static func analyticsTile(_ tile: TileVerdict.Tile) -> TodayTile {
        switch tile {
        case .upNext: .upNext
        case .due: .due
        case .sleep: .sleep
        case .activity: .steps
        }
    }

    // MARK: - Feed

    private var feedCards: [TodayFeed.Card] {
        let latest = model.unreadRoutineResults.first.map { entry in
            let said = ScheduleWords.summary(of: entry.run, in: entry.task)
            return (
                taskID: entry.task.id,
                title: entry.task.title,
                text: ScheduleWords.preview(of: said.text),
                isTrouble: said.isTrouble
            )
        }
        return TodayFeed.cards(TodayFeed.Inputs(
            brain: model.brainStatus,
            latestResult: latest,
            snapshot: briefing.snapshot,
            hasMorningBrief: routinesKnown ? model.existingRoutine(for: .morningBrief) != nil : nil,
            dismissedMorningBrief: morningBriefOfferDismissed,
            dismissedRefusals: dismissedRefusals
        ))
    }

    private enum FeedPlacement {
        case aboveTiles, belowTiles

        func holds(_ card: TodayFeed.Card) -> Bool {
            (card == .morningBrief) == (self == .belowTiles)
        }
    }

    @ViewBuilder
    private func feed(placement: FeedPlacement) -> some View {
        let cards = feedCards.filter(placement.holds)
        if !cards.isEmpty {
            VStack(spacing: PDSpacing.cardGap) {
                ForEach(cards) { card in
                    feedCard(card)
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func feedCard(_ card: TodayFeed.Card) -> some View {
        switch card {
        case .chooseBrain:
            NoticeCard(
                symbol: "sparkles",
                text: "Choose how Pocketd thinks, and ask anything about your day.",
                linkTitle: "Choose"
            ) {
                navigator.openYou(.brain)
            }
        case .brainFailed:
            NoticeCard(
                symbol: "sparkles",
                tint: .pd.caution,
                text: "Pocketd couldn't get ready to answer questions.",
                linkTitle: "See why"
            ) {
                navigator.openYou(.brain)
            }
        case let .routineResult(taskID, title, text, isTrouble):
            NoticeCard(
                symbol: "alarm",
                tint: isTrouble ? .pd.caution : .pd.ink,
                title: title,
                text: text,
                linkTitle: "Open",
                action: { navigator.open(.routineResult(taskID)) },
                onDismiss: { model.markRoutineResultsSeen() }
            )
        case let .refused(sources):
            NoticeCard(
                symbol: Self.symbol(for: sources.first ?? .calendar),
                tint: .pd.caution,
                text: TodayFeed.refusedSentence(sources),
                linkTitle: "Open Settings",
                linkSymbol: "arrow.up.right",
                action: { openSettings(for: sources) },
                onDismiss: { dismissRefusals(sources) }
            )
        case .morningBrief:
            NoticeCard(
                symbol: "sun.horizon",
                text: "Get your day every morning, before you pick up the phone.",
                linkTitle: "Set it up",
                action: { setUpMorningBrief() },
                onDismiss: { morningBriefOfferDismissed = true }
            )
        }
    }

    private static func symbol(for source: Ability) -> String {
        switch source {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .health, .localServer: "heart"
        }
    }

    /// Through the door, which opens Pocketd's page in Settings when iOS has
    /// already said no — the only page an app may open there.
    private func openSettings(for sources: [Ability]) {
        guard let first = sources.first else { return }
        Task { await model.connect(first, from: .today) }
    }

    private var dismissedRefusals: Set<Ability> {
        Set(refusalsDismissed.split(separator: ",").compactMap { Ability(rawValue: String($0)) })
    }

    private func dismissRefusals(_ sources: [Ability]) {
        let all = dismissedRefusals.union(sources)
        refusalsDismissed = all.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// One tap: the morning brief at 7:30 on weekdays, which asks iOS for
    /// notifications the first time. The time is said back, so the person
    /// knows what they agreed to and can change it in Routines.
    private func setUpMorningBrief() {
        Task {
            // iOS's notification question first, answered, then the routine.
            // The save asks on its own but does not wait for the answer, so
            // the confirmation below came up under iOS's alert and was gone
            // before anybody had answered it: the card simply vanished.
            let centre = NotificationCentre.shared
            if await centre.authorizationStatus() == .notDetermined {
                _ = await centre.requestAuthorization()
            }
            if let routine = await model.setUpMorningBrief() {
                // Long enough to be read after the notification question iOS
                // may have just put up: without it the card simply vanished.
                toasts.show(
                    Self.morningBriefSet(routine.recurrence),
                    symbol: "sun.horizon",
                    tint: .pd.ink,
                    seconds: 4
                )
            } else {
                toasts.show(
                    "Pocketd couldn't set that up. Try again in Routines.",
                    symbol: "exclamationmark.circle",
                    tint: .pd.caution
                )
            }
        }
    }

    /// "Morning brief set for 7:30 AM on weekdays."
    static func morningBriefSet(_ recurrence: Recurrence) -> String {
        let hero = ScheduleWords.hero(recurrence)
        let time = hero.period.map { "\(hero.time) \($0)" } ?? hero.time
        let days = ScheduleWords.pattern(recurrence)
        let when = switch days {
        case "Weekdays": "on weekdays"
        case "Every day": "every day"
        default: "on \(days)"
        }
        return "Morning brief set for \(time) \(when)."
    }

    // MARK: - Composer

    private var composer: ContextComposer {
        PageQuestion.composer(
            TodayQuestion.pick(briefing.snapshot, now: DemoClock.now),
            placeholder: "Ask about your day…",
            navigator: navigator,
            model: model
        )
    }
}

// MARK: - The top edge

/// What keeps the page off the clock once it scrolls.
///
/// Today has no navigation bar to do it — the day's name is the page's own
/// header — so a paragraph scrolled up at a large text size ran straight
/// under the status bar behind nothing but a faint fade. On iOS 26 the scroll
/// view's own edge effect, set hard: the system's material and the system's
/// line, exactly as under a bar. Before it, the bar material drawn into the
/// status bar's strip, only once the page has actually moved, so the hero wash
/// still runs to the top of an unscrolled screen.
private struct StatusBarEdge: ViewModifier {
    let isScrolled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Hard only once something is under the clock: at rest the hard
            // style still draws its line across the hero wash.
            content.scrollEdgeEffectStyle(isScrolled ? .hard : .soft, for: .top)
        } else {
            content.overlay(alignment: .top) {
                Color.clear
                    .frame(height: 0)
                    .background(.bar, ignoresSafeAreaEdges: .top)
                    .opacity(isScrolled ? 1 : 0)
                    .animation(PDMotion.gentle, value: isScrolled)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Previews

#Preview("Today full") {
    TodayPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief
    ))
}

#Preview("Today dark") {
    TodayPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief
    ))
    .preferredColorScheme(.dark)
}

#Preview("Today AX") {
    TodayPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief
    ))
    .dynamicTypeSize(.accessibility2)
}

/// The template on screen and a brain rewriting it underneath.
#Preview("Today writing") {
    TodayPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief,
        phase: .streaming,
        streaming: "Good morning, Sam. Standup is at 9:30 AM and the dentist"
    ))
}

/// A brain loading: one grey line, and everything else as usual.
#Preview("Today getting ready") {
    TodayPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief,
        brainLoading: true
    ))
}

#Preview("Today nothing connected") {
    TodayPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.nothingConnected,
        brief: TodayPreviewData.brief(for: TodayPreviewData.nothingConnected, name: nil)
    ))
}

private struct TodayPreview: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            TodayView()
        }
        .environment(model)
        .environment(Navigator())
        .environment(ToastCenter())
    }
}
