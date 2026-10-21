#if DEBUG
import SwiftUI

/// Every design-system component in its states, on one screen, for review and
/// screenshots — Debug builds only, and nothing in it touches the app's model.
///
///     xcrun simctl launch <udid> dev.pocketd.app -pocketd.gallery
///     xcrun simctl launch <udid> dev.pocketd.app -pocketd.gallery tiles
///
/// With a section name after the flag it shows that section alone (see
/// `GallerySection`), so a screenshot run can photograph each one without
/// driving a scroll view. `detail` pushes a real `DetailPage` and `promo`
/// presents a real `PromoSheet`. Light, dark and the text size come from the
/// simulator (`xcrun simctl ui <udid> appearance dark`, `content_size …`).
///
/// Entirely inside `#if DEBUG`: a Release build has no path to any of it.
struct ComponentGallery: View {
    var only: GallerySection?

    var body: some View {
        switch only {
        case .detail:
            GalleryDetailHost()
        case .detailScrolled:
            GalleryDetailHost(scrolled: true)
        case .promo:
            GalleryPromoHost()
        case .composer:
            GalleryComposerPage()
        case let section?:
            ScrollView {
                GallerySectionView(section: section)
                    .padding(.horizontal, PDSpacing.gutter)
                    .padding(.bottom, PDSpacing.xxl)
            }
            // `-pocketd.gallery.end`: open at the bottom of the section, to
            // photograph what a large text size pushes below the fold.
            .defaultScrollAnchor(GallerySection.startsAtEnd ? .bottom : .top)
            .pdCanvas()
        case nil:
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: PDSpacing.xxl) {
                        ForEach(GallerySection.inline) { section in
                            GallerySectionView(section: section)
                        }
                        VStack(alignment: .leading, spacing: PDSpacing.s) {
                            SectionLabel("Full screen")
                            PDCard {
                                VStack(alignment: .leading, spacing: 0) {
                                    NavigationLink("Detail page") { GalleryDetailPage() }
                                        .pdHitTarget(alignment: .leading)
                                    NavigationLink("Composer over content") { GalleryComposerPage() }
                                        .pdHitTarget(alignment: .leading)
                                    NavigationLink("Promo sheet") { GalleryPromoHost() }
                                        .pdHitTarget(alignment: .leading)
                                }
                                .font(Font.pd.rowTitle)
                                .tint(Color.pd.ink)
                            }
                        }
                    }
                    .padding(.horizontal, PDSpacing.gutter)
                    .padding(.bottom, PDSpacing.xxl)
                }
                .pdCanvas()
                .navigationTitle("Components")
            }
        }
    }
}

/// The gallery's sections, by the name the launch argument uses.
enum GallerySection: String, CaseIterable, Identifiable {
    case type, colour, buttons, tiles, rows, cards, feedback, composer, detail, promo
    /// The detail page opened already scrolled to its end, to see the bar
    /// title take over from the in-page heading.
    case detailScrolled = "detail-scrolled"

    var id: String { rawValue }

    /// The sections drawn inline in the full gallery; the rest are screens.
    static let inline: [GallerySection] = [.type, .colour, .buttons, .tiles, .rows, .cards, .feedback]

    var title: String {
        switch self {
        case .type: "Type"
        case .colour: "Colour"
        case .buttons: "Buttons"
        case .tiles: "Tiles"
        case .rows: "Rows"
        case .cards: "Cards"
        case .feedback: "Feedback"
        case .composer: "Composer"
        case .detail: "Detail page"
        case .promo: "Promo sheet"
        case .detailScrolled: "Detail page, scrolled"
        }
    }

    static var startsAtEnd: Bool {
        ProcessInfo.processInfo.arguments.contains("-pocketd.gallery.end")
    }

    /// `-pocketd.gallery` and, optionally, the section after it.
    static var launchRequest: (requested: Bool, section: GallerySection?) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-pocketd.gallery") else { return (false, nil) }
        let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        return (true, next.flatMap(GallerySection.init(rawValue:)))
    }
}

extension View {
    /// The whole app becomes the component gallery when launched with
    /// `-pocketd.gallery`. Applied last on the root view, so nothing of the
    /// app — not even its bootstrap — runs underneath.
    @ViewBuilder
    func componentGalleryIfRequested() -> some View {
        let request = GallerySection.launchRequest
        if request.requested {
            ComponentGallery(only: request.section)
        } else {
            self
        }
    }
}

// MARK: - Sections

private struct GallerySectionView: View {
    let section: GallerySection

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            Text(section.title)
                .font(Font.pd.titleDetail)
                .foregroundStyle(Color.pd.ink)
                .padding(.top, PDSpacing.m)
            switch section {
            case .type: GalleryType()
            case .colour: GalleryColour()
            case .buttons: GalleryButtons()
            case .tiles: GalleryTiles()
            case .rows: GalleryRows()
            case .cards: GalleryCards()
            case .feedback: GalleryFeedback()
            case .composer, .detail, .promo, .detailScrolled: EmptyView()
            }
        }
    }
}

private struct GalleryType: View {
    private let tokens: [(String, Font)] = [
        ("title · largeTitle bold", Font.pd.title),
        ("titleDetail · title bold", Font.pd.titleDetail),
        ("statValue · title", Font.pd.statValue),
        ("statText · title2 semibold", Font.pd.statText),
        ("7:30 timeHero · largeTitle", Font.pd.timeHero),
        ("lead · title3", Font.pd.lead),
        ("headline · title3 semibold", Font.pd.headline),
        ("verdict · title3", Font.pd.verdict),
        ("rowTitle · headline", Font.pd.rowTitle),
        ("body · body", Font.pd.body),
        ("buttonLabel · headline", Font.pd.buttonLabel),
        ("monoValue · callout mono", Font.pd.monoValue),
        ("secondary · subheadline", Font.pd.secondary),
        ("footnote · footnote", Font.pd.footnote),
        ("code · footnote mono", Font.pd.code),
        ("label · caption2 mono", Font.pd.label),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            Text("Every token is a text style.").pdHero().foregroundStyle(Color.pd.ink)
            Text("The brief is a lead on the canvas: no card, at most 3 sentences.").pdLead()
            Text("A page's grey summary sentence uses pdSubtitle.").pdSubtitle()
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    ForEach(tokens, id: \.0) { name, font in
                        Text(name)
                            .font(font)
                            .foregroundStyle(Color.pd.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct GalleryColour: View {
    private let text: [(String, Color)] = [
        ("ink", .pd.ink), ("inkSecondary — 5.5:1", .pd.inkSecondary),
        ("inkTertiary — decoration only", .pd.inkTertiary),
        ("accent", .pd.accent), ("positive", .pd.positive), ("caution", .pd.caution),
    ]
    private let surfaces: [(String, Color)] = [
        ("canvas", .pd.canvas), ("card", .pd.card), ("chip", .pd.chip),
        ("fillTile", .pd.fillTile), ("canvasWarm", .pd.canvasWarm), ("fillWarm", .pd.fillWarm),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.xs) {
                    ForEach(text, id: \.0) { name, colour in
                        Text(name).font(Font.pd.body).foregroundStyle(colour)
                    }
                    Text("inkSecondaryWarm on warm")
                        .font(Font.pd.body)
                        .foregroundStyle(Color.pd.inkSecondaryWarm)
                        .padding(PDSpacing.xs)
                        .background(Color.pd.canvasWarm, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(spacing: PDSpacing.s) {
                        AvatarCircle(initial: "S")
                        Text("onAvatar on avatar").font(Font.pd.secondary).foregroundStyle(Color.pd.inkSecondary)
                    }
                }
            }
            HStack(spacing: PDSpacing.xs) {
                ForEach(surfaces, id: \.0) { name, colour in
                    VStack(spacing: PDSpacing.xxs) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colour)
                            .frame(height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.pd.cardStroke, lineWidth: 1)
                            )
                        Text("Grey text")
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .padding(.horizontal, 2)
                            .background(colour)
                        Text(name).font(Font.pd.code).foregroundStyle(Color.pd.ink)
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                }
            }
        }
    }
}

private struct GalleryButtons: View {
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            SectionLabel("Header")
            HStack(spacing: PDSpacing.s) {
                HeaderCapsule(initial: "S", onRoutines: { count += 1 }, onYou: { count += 1 })
                HeaderCapsule(initial: "S", showsBadge: true, onRoutines: { count += 1 }, onYou: { count += 1 })
            }
            HStack(spacing: PDSpacing.xs) {
                CircleIconButton(symbol: "chevron.left", label: "Back") { count += 1 }
                CircleIconButton(symbol: "clock", label: "History", badge: 2) { count += 1 }
                CircleIconButton(symbol: "hand.thumbsup", label: "Good answer", size: 32) { count += 1 }
                AvatarButton(initial: "D") { count += 1 }
            }

            SectionLabel("Pills and links")
            HStack(spacing: PDSpacing.xs) {
                PillButton(title: "Read aloud", symbol: "speaker.wave.2") { count += 1 }
                PillButton(title: "Use this", symbol: "checkmark", isOn: true) { count += 1 }
            }
            HStack(spacing: PDSpacing.xs) {
                LinkPill(title: "Try again", symbol: "arrow.clockwise") { count += 1 }
                TextLink("Set it up") { count += 1 }
            }
            Text("Taps: \(count)")
                .font(Font.pd.code)
                .foregroundStyle(Color.pd.inkSecondary)
                .accessibilityIdentifier("gallery.taps")

            SectionLabel("The one button")
            PrimaryButton(title: "Continue") { count += 1 }
            PrimaryButton(title: "Set it up", arrow: false, isLoading: true) {}
            SecondaryLink("Not now") { count += 1 }
        }
    }
}

private struct GalleryTiles: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            VerdictGrid {
                VerdictTile(
                    label: "Up next", symbol: "calendar",
                    status: "Design review with the team",
                    sentence: "In 3h 19m · Conference room B."
                ) {}
                VerdictTile(
                    label: "Due", symbol: "checklist",
                    status: "1 overdue", tone: .caution,
                    sentence: "Send the invoice was due yesterday."
                ) {}
                VerdictTile(
                    label: "Sleep", symbol: "bed.double",
                    status: "Rested", tone: .positive,
                    sentence: "6h 36m — about your usual."
                ) {}
                VerdictTile.off(
                    label: "Activity", symbol: "figure.walk",
                    sentence: "Turn on to see your steps."
                ) {}
            }
            SectionLabel("Inside a card")
            PDCard {
                ComparisonTiles(
                    usual: .init("Usual", value: "7h 10m"),
                    current: .init("Last night", value: "6h 36m"),
                    delta: "34 minutes under your usual."
                )
            }
            // StatTile fills its height now, so the two containers that
            // still hold it are reproduced here as their call sites build
            // them — an answer card's LazyVGrid, v2 Today's Grid, both one
            // column at the accessibility sizes. Neither may stretch a tile
            // past its row.
            PDCard {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 130), spacing: PDSpacing.tileGap)],
                    alignment: .leading,
                    spacing: PDSpacing.tileGap
                ) {
                    StatTile(label: "Resting", value: "58", unit: "bpm", footnote: "usual 61")
                    StatTile(label: "Steps", value: "4,120")
                    StatTile(label: "Sleep", value: "6h 36m")
                }
            }
            Grid(horizontalSpacing: PDSpacing.tileGap, verticalSpacing: PDSpacing.tileGap) {
                if typeSize.isAccessibilitySize {
                    GridRow { StatTile(label: "Up next", value: "Design review with the team", isText: true) {} }
                    GridRow { StatTile(label: "Due", value: "3", unit: "today", footnote: "1 overdue", tint: .pd.caution) {} }
                } else {
                    GridRow {
                        StatTile(label: "Up next", value: "Design review with the team", isText: true) {}
                        StatTile(label: "Due", value: "3", unit: "today", footnote: "1 overdue", tint: .pd.caution) {}
                    }
                }
            }
        }
    }
}

private struct GalleryRows: View {
    @State private var calendar = true
    @State private var reminders = false

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            SectionLabel("What Pocketd can see")
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.m) {
                    SourceRow(symbol: "calendar", title: "Calendar", detail: "Reads and adds events", accessory: .toggle($calendar))
                    SourceRow(symbol: "checklist", title: "Reminders", detail: "Reads, adds and ticks off reminders", accessory: .toggle($reminders))
                    SourceRow(symbol: "heart", title: "Health", detail: "Reads sleep and steps", accessory: .status("Off in iOS Settings", isOn: false)) {}
                    SourceRow(symbol: "heart", title: "Health", detail: "Reads sleep and steps", accessory: .status("On", isOn: true))
                }
            }
            PDCard(warm: true) {
                VStack(alignment: .leading, spacing: PDSpacing.m) {
                    SourceRow(symbol: "checklist", title: "Reminders", detail: "Reads, adds and ticks off reminders", accessory: .connect {}, warm: true)
                    Primer("Next, tap **Allow Full Access** so Pocketd can read your reminders.", warm: true)
                }
            }
            SectionLabel("Later today")
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    DataRow(
                        title: "Lunch at The Arches",
                        subtitle: "The Arches, Leith Walk · 1h",
                        value: "1:00 PM",
                        links: [.init("Directions") {}, .init("Open in Calendar") {}]
                    )
                    Divider().overlay(Color.pd.divider)
                    DataRow(title: "Send the invoice", subtitle: "Was due yesterday", value: "5:00 PM", valueTint: .pd.caution)
                }
            }
            PDCard {
                TimelineList(items: [
                    TimelineItem(time: "9:30", title: "Standup", detail: "15 minutes"),
                    TimelineItem(time: "11:00", title: "Design review with the team"),
                    TimelineItem(time: "All day", title: "Anna's birthday", tint: .pd.inkTertiary),
                ])
            }
            // Side by side while they fit, stacked when they do not: the
            // pills themselves never wrap.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PDSpacing.xs) { statusSamples }
                VStack(alignment: .leading, spacing: PDSpacing.xs) { statusSamples }
            }
        }
    }
}

extension GalleryRows {
    @ViewBuilder
    fileprivate var statusSamples: some View {
        StatusPill(.positive, "Ready")
        StatusPill(.neutral, "Off")
        MiniLabel("Mini label")
    }
}

private struct GalleryCards: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            NoticeCard(
                symbol: "sun.horizon",
                text: "Get your day every morning, before you pick up the phone.",
                linkTitle: "Set it up"
            ) {}
            NoticeCard(
                symbol: "calendar",
                tint: .pd.caution,
                text: "Calendar is off in iOS Settings.",
                linkTitle: "Open Settings",
                linkSymbol: "arrow.up.right",
                action: {},
                onDismiss: {}
            )
            Primer("Next, tap **Allow** so Pocketd can tell you when it's ready.")
            ConnectCard(
                title: "Reminders",
                symbol: "checklist",
                detail: "Ask what's overdue, or have Pocketd remind you.",
                state: .needsAttention
            ) {}
        }
    }
}

private struct GalleryFeedback: View {
    @State private var toasts = ToastCenter()

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            Toast(message: ToastMessage(text: "Reminder set for 5:00 PM", symbol: "bell"))
            Toast(message: ToastMessage(
                text: "Ticked off",
                symbol: "checkmark.circle",
                tint: .pd.positive,
                action: ToastAction(title: "Undo") {}
            ))
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    Text("Getting ready · about 2 min")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                    ProgressStripe(fraction: 0.34)
                }
            }
            HStack(spacing: PDSpacing.l) {
                ThinkingOrb(size: 56, dotCount: 10)
                ReadyBurst(size: 44)
                IconTile(symbol: "brain")
                IconTile.small("calendar")
            }
            SuggestionChip("What's on tomorrow?") {}
        }
    }
}

// MARK: - Full-screen pieces

private struct GalleryDetailPage: View {
    /// Enough nights to scroll the page.
    var nights = 5

    var body: some View {
        DetailPage(
            title: "Sleep",
            summary: "6h 36m last night — 34 minutes under your usual.",
            composer: ContextComposer(
                suggestion: .init("Was this week better than last?") {},
                placeholder: "Ask anything else",
                onAsk: {},
                onMic: {}
            )
        ) {
            PDCard {
                ComparisonTiles(
                    usual: .init("Usual", value: "7h 10m"),
                    current: .init("Last night", value: "6h 36m")
                )
            }
            SectionLabel("Last 7 nights")
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    ForEach(0..<nights, id: \.self) { index in
                        if index > 0 { Divider().overlay(Color.pd.divider) }
                        DataRow(title: "Night \(index + 1)", value: ["6h 36m", "7h 12m", "8h 01m", "6h 58m", "7h 20m"][index % 5])
                    }
                }
            }
        }
    }
}

/// The detail page as the launch argument shows it: already pushed, so the
/// back button and the inline title behave as they do in the app.
private struct GalleryDetailHost: View {
    var scrolled = false
    @State private var path: [Int] = [1]
    @State private var nights = 14

    var body: some View {
        NavigationStack(path: $path) {
            Text("Today")
                .navigationDestination(for: Int.self) { _ in
                    if scrolled {
                        // Opened at the end, then one more row: a page that
                        // *opens* scrolled reports no scroll change, so the
                        // extra row is what moves it and shows the bar title
                        // taking over from the heading.
                        GalleryDetailPage(nights: nights)
                            .defaultScrollAnchor(.bottom)
                            .task {
                                try? await Task.sleep(for: .milliseconds(700))
                                nights += 1
                            }
                    } else {
                        GalleryDetailPage()
                    }
                }
        }
    }
}

private struct GalleryComposerPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                HeroHeader(dayName: "Thursday", date: "18 Sep", wash: false) {
                    HeaderCapsule(initial: "S", showsBadge: true, onRoutines: {}, onYou: {})
                }
                .padding(.horizontal, -PDSpacing.gutter)
                Text("Lunch at The Arches at 1:00 PM is next. You have 2 reminders due today and 1 overdue, and you slept 6h 36m, 29 min under your usual.")
                    .pdLead()
                VerdictGrid {
                    VerdictTile(label: "Up next", symbol: "calendar", status: "Lunch at The Arches", sentence: "In 3h 19m · Leith Walk.") {}
                    VerdictTile(label: "Due", symbol: "checklist", status: "1 overdue", tone: .caution, sentence: "Send the invoice was due yesterday.") {}
                    VerdictTile(label: "Sleep", symbol: "bed.double", status: "Rested", tone: .positive, sentence: "6h 36m — about your usual.") {}
                    VerdictTile(label: "Activity", symbol: "figure.walk", status: "Behind", tone: .caution, sentence: "4,120 steps — you're usually at 6,100 by now.") {}
                }
                NoticeCard(symbol: "sun.horizon", text: "Get your day every morning, before you pick up the phone.", linkTitle: "Set it up") {}
            }
            .padding(.horizontal, PDSpacing.gutter)
        }
        // The wash under the canvas colour would never be seen: it goes on
        // first, then the canvas behind it.
        .pdHeroWash()
        .pdCanvas()
        .contextComposer(ContextComposer(
            suggestion: .init("How did I sleep?") {},
            onAsk: {},
            onMic: {}
        ))
    }
}

private struct GalleryPromoHost: View {
    @State private var showsPromo = true

    var body: some View {
        VStack(spacing: PDSpacing.m) {
            Text("Routines").font(Font.pd.titleDetail).foregroundStyle(Color.pd.ink)
            PillButton(title: "Show the promo", symbol: "sparkles") { showsPromo = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pdCanvas()
        .sheet(isPresented: $showsPromo) {
            PromoSheet(
                symbol: "alarm",
                title: "Start every day briefed.",
                benefits: [
                    .init("sun.horizon", "Your day, waiting when you wake"),
                    .init("exclamationmark.circle", "Overdue things, caught early"),
                    .init("clock", "At the time you choose"),
                ],
                primaryTitle: "Set it up",
                primer: "Next, tap **Allow** so Pocketd can tell you when your brief is ready.",
                onPrimary: { showsPromo = false },
                onSecondary: { showsPromo = false }
            )
        }
    }
}

#Preview("Gallery") {
    ComponentGallery()
}
#endif
