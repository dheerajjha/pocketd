import PocketdKit
import SwiftUI

/// The screen the app opens to: your own day, in your own words.
///
/// Top to bottom it is one paragraph and four numbers, and that order is the
/// whole argument of v2. The paragraph is what a person reads; the tiles are
/// what they check; the chips are the four questions they were going to type
/// anyway. Everything technical — which model wrote this, whether a socket is
/// listening — is one tab away behind plain words.
///
/// Nothing on this screen needs a model. The tiles and the brief both come off
/// `TodaySnapshot`, which is read from EventKit and HealthKit alone, so a phone
/// with nothing downloaded still shows a real day rather than an invitation to
/// download something.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.dynamicTypeSize) private var typeSize

    /// One synthesizer for this screen, owned here rather than by the model:
    /// speech is a property of what is on screen, and a brief being read aloud
    /// should stop when the tab does.
    @State private var reader = ReadAloud()

    /// The four openings, written as the question a person would type — which
    /// is what makes them read as examples rather than as buttons.
    ///
    /// "Remind me to…" is deliberately unsent: it is half a sentence and the
    /// person finishes it. The other three are whole questions and go straight
    /// through.
    private static let chips: [(text: String, send: Bool)] = [
        ("What's on tomorrow?", true),
        ("Anything overdue?", true),
        ("Remind me to…", false),
        ("How did I sleep?", true),
    ]

    private var briefing: BriefingState { model.briefing }

    /// Results waiting to be written, which is the one thing the bell carries:
    /// a scheduled brief that came due while the app was closed cannot run
    /// until somebody opens it.
    private var waiting: Int {
        ScheduleSummary.pending(in: model.scheduledTasks).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                // In the scroll view rather than pinned above it. The wash is
                // on the screen and stays put; the header scrolls away, which
                // is what gives the page its whole height back once somebody is
                // reading rather than arriving.
                HeroHeader(date: DemoClock.now, wash: false) {
                    CircleIconButton(symbol: "bell", label: "Routines", badge: waiting) {
                        navigator.go(.routines)
                    }
                    AvatarButton(initial: model.profile.initial) {
                        navigator.go(.you)
                    }
                }
                .padding(.bottom, PDSpacing.m)

                BriefCard(reader: reader)
                    .padding(.horizontal, PDSpacing.gutter)
                    .pdStaggerIn(0)

                // Only when there is genuinely nothing to read. These sell the
                // missing thing rather than apologising for it, and they are
                // separate cards because `ConnectCard` is one — a card inside a
                // card is two borders saying the same thing.
                if !briefing.snapshot.hasAnythingConnected {
                    connectCards
                        .padding(.horizontal, PDSpacing.gutter)
                        .pdStaggerIn(1)
                }

                // Once a minute, because "in 2h 10m" is a countdown and a
                // stored one is still saying it at half past eleven. A
                // `TimelineView` stops when the tab goes away, which a repeating
                // `Task.sleep` in a `.task` would not.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    TodayTileGrid(snapshot: briefing.snapshot, oneColumn: typeSize.isAccessibilitySize) { tile in
                        open(tile)
                    }
                }
                .padding(.horizontal, PDSpacing.gutter)
                .pdStaggerIn(2)

                suggestions
                    .padding(.top, PDSpacing.xxs)
                    .pdStaggerIn(3)
            }
            .padding(.top, PDSpacing.xxs)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.refreshBrief(force: true) }
        // The floating bar's space, as safe area on this scroll view rather
        // than as padding: the page keeps scrolling under the capsule, and the
        // last row still comes out from under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: PDMetric.tabBarClearance)
        }
        // Wash first, canvas second, and the order is the whole effect.
        // `background` puts each new layer *behind* the last, so applying the
        // flat canvas afterwards paints it over the gradient and the top of the
        // page goes plain white.
        .pdHeroWash()
        .pdCanvas()
        .task {
            // The bell's badge, which is the one number on this screen that is
            // not decoration.
            await model.loadScheduledTasks()
            // Cheap and idempotent: `refreshBrief` returns immediately when a
            // model already wrote today's. This covers the launch that lands
            // straight on Today before `bootstrap` reaches its own call.
            await model.refreshBrief()
        }
        // Speech outlives the view otherwise: AVSpeechSynthesizer keeps
        // talking to an empty room when the tab changes underneath it.
        .onDisappear { reader.stop() }
        .onChange(of: reader.isSpeaking) { _, speaking in
            briefing.isReadingAloud = speaking
        }
    }

    // MARK: - Connect

    private var connectCards: some View {
        VStack(spacing: PDSpacing.cardGap) {
            ConnectCard(
                title: "Calendar",
                symbol: "calendar",
                detail: "So it can tell you what is next, and add things for you.",
                state: state(of: briefing.snapshot.calendar),
                primer: "Next, tap Allow Full Access."
            ) {
                connect(.calendar)
            }
            ConnectCard(
                title: "Reminders",
                symbol: "checklist",
                detail: "So it knows what is due and what slipped.",
                state: state(of: briefing.snapshot.reminders),
                primer: "Next, tap Allow Full Access."
            ) {
                connect(.reminders)
            }
        }
    }

    private func state(of availability: TodaySnapshot.Availability) -> ConnectCard.State {
        switch availability {
        case .connected: .connected
        case .refused, .unavailable: .needsAttention
        case .off: .connect
        }
    }

    /// Turns the ability on and asks iOS in the same breath.
    ///
    /// The switch first, because that is the user's own decision and it has to
    /// survive a refused grant; `requestAccess` second, because it is what puts
    /// the answer into `personalDataAuthorization`, which is what every other
    /// screen in the app reads. The refresh last, so the tiles fill in without
    /// a second tap.
    private func connect(_ entity: PersonalDataEntity) {
        switch briefing.snapshot.availability(of: entity) {
        case .refused, .unavailable:
            // Nothing this app can do from here — the switch is in iOS
            // Settings, and `ConnectCard` has already said so.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            return
        case .connected, .off:
            break
        }
        switch entity {
        case .calendar: model.calendarToolsEnabled = true
        case .reminders: model.reminderToolsEnabled = true
        }
        Task {
            await model.requestAccess(to: entity)
            await model.refreshBrief(force: true)
        }
    }

    // MARK: - Tiles

    private func open(_ tile: TodayTile) {
        model.record(.todayTileTapped(tile: tile))
        switch tile {
        case .upNext:
            reachable(briefing.snapshot.calendar) ? navigator.ask("What's on next?", send: true) : navigator.go(.you)
        case .due:
            reachable(briefing.snapshot.reminders) ? navigator.ask("What's due today?", send: true) : navigator.go(.you)
        case .sleep:
            reachable(briefing.snapshot.health) ? navigator.ask("How did I sleep?", send: true) : navigator.go(.you)
        case .steps:
            reachable(briefing.snapshot.health)
                ? navigator.ask("How active have I been?", send: true)
                : navigator.go(.you)
        }
    }

    /// Whether asking about this source could produce an answer. A tile reading
    /// "Off" sends somebody to the switch rather than to a question that would
    /// come back with a padlock.
    private func reachable(_ availability: TodaySnapshot.Availability) -> Bool {
        availability.isReadable
    }

    // MARK: - Chips

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            SectionLabel("Try asking")
                .padding(.horizontal, PDSpacing.gutter)
            ScrollView(.horizontal) {
                HStack(spacing: PDSpacing.xs) {
                    ForEach(Self.chips, id: \.text) { chip in
                        SuggestionChip(chip.text) {
                            navigator.ask(chip.text, send: chip.send)
                        }
                    }
                }
                .padding(.horizontal, PDSpacing.gutter)
                // The press effect scales the chip up a little and a clipped
                // scroll view cuts the top off it.
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Availability by entity

private extension TodaySnapshot {
    /// The snapshot's own answer for one EventKit entity, so a view does not
    /// have to remember which field holds which.
    func availability(of entity: PersonalDataEntity) -> Availability {
        switch entity {
        case .calendar: calendar
        case .reminders: reminders
        }
    }
}

// MARK: - Previews

#Preview("Today light") {
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

/// The state a simulator cannot reach: a brain mid-sentence.
#Preview("Today streaming") {
    TodayPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.full,
        brief: TodayPreviewData.templateBrief,
        phase: .streaming,
        streaming: "Good morning, Sam. Standup is at half nine and the dentist has you at half four, "
            + "so the middle of the day is yours. Submit expenses slipped yesterday"
    ))
}

#Preview("Today nothing connected") {
    TodayPreview(model: TodayPreviewData.model(
        snapshot: TodayPreviewData.nothingConnected,
        brief: DailyBrief(
            text: BriefPrompt.fallback(
                snapshot: TodayPreviewData.nothingConnected,
                name: nil,
                now: TodayPreviewData.now
            ),
            generatedAt: TodayPreviewData.now,
            source: .template,
            snapshot: TodayPreviewData.nothingConnected
        )
    ))
}

private struct TodayPreview: View {
    let model: AppModel

    var body: some View {
        TodayView()
            .environment(model)
            .environment(Navigator())
            .environment(ToastCenter())
    }
}
