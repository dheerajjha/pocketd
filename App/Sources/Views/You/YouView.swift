import PocketdKit
import SwiftUI
import UIKit

/// You: the person, what Pocketd can see, and everything else one level down.
///
/// Pushed from the avatar on Today. One screen of one-line rows under mono
/// labels — WHAT POCKETD CAN SEE, BRAIN, PRIVACY, USE FROM YOUR LAPTOP, ABOUT,
/// ADVANCED — and no footers: every row says its state in one grey line, and
/// anything that needs a paragraph lives on the page the row opens. The server
/// section, the request log, the memory switches and the analytics switch all
/// used to sit here; the first two moved to Other devices, the memory switches
/// are gone (keeping a brain in memory is automatic), and the analytics switch
/// is on the Privacy page beside the promise it qualifies.
///
/// The sections are ordered by how often somebody has a reason to touch them.
/// What Pocketd can see is first because it is the difference between this
/// app and a local chat box.
struct YouView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(ProStore.self) private var pro: ProStore?

    @State private var editingName = false
    @State private var showingAbout = false
    /// Whether the header has scrolled under the bar, so the bar's own "You"
    /// can take over. One title on screen at a time, as on `DetailPage`.
    @State private var headerIsHidden = false

    /// Where the published policy lives. Written out rather than assembled,
    /// because a privacy link that 404s is worse than no privacy link.
    private static let policyURL = URL(string: "https://dheerajjha.github.io/pocketd/")!

    /// The App Store's own review page for Pocketd. `requestReview()` is
    /// Apple's to show or to swallow — it is rationed, and shows nothing at
    /// all in a build that did not come from the App Store — so a row that
    /// says "Rate Pocketd" opens the page that always answers.
    private static let reviewURL = URL(string: "https://apps.apple.com/app/id6811137664?action=write-review")!

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PDSpacing.xl) {
                    header.pdStaggerIn(0)
                    AbilitiesSection().pdStaggerIn(1).id("abilities")
                    brainSection.pdStaggerIn(2).id("brain")
                    privacySection.pdStaggerIn(3).id("privacy")
                    laptopSection.pdStaggerIn(4).id("devices")
                    aboutSection.pdStaggerIn(5).id("about")
                    advancedSection.pdStaggerIn(6).id("settings")
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.xs)
                .padding(.bottom, PDSpacing.xl)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                let hidden = offset > 56
                if hidden != headerIsHidden { headerIsHidden = hidden }
            }
            #if DEBUG
            // A screenshot run says which section it came for. `YouStage` and
            // this modifier are both inside `#if DEBUG`.
            .task {
                guard let anchor = YouStage.scrollAnchor else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(anchor, anchor: .top)
            }
            #endif
        }
        .scrollIndicators(.hidden)
        .pdCanvas()
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("You")
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .opacity(headerIsHidden ? 1 : 0)
                    .animation(PDMotion.gentle, value: headerIsHidden)
                    .accessibilityHidden(!headerIsHidden)
            }
        }
        .sheet(isPresented: $editingName) { NameSheet() }
        .sheet(isPresented: $showingAbout) { AboutSheet() }
        #if DEBUG
        // A screenshot's state, asked for at launch. See `YouStage`; the whole
        // type and these two calls are inside `#if DEBUG`.
        .task { await YouStage.apply(model: model, navigator: navigator) }
        .task {
            switch YouStage.sheet {
            case "name": editingName = true
            case "about": showingAbout = true
            default: break
            }
        }
        #endif
    }

    // MARK: - Header

    /// The avatar and the name — the page's title, so the bar shows none
    /// until this has scrolled away.
    private var header: some View {
        Button {
            Haptics.tap()
            editingName = true
        } label: {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: PDSpacing.s))
                : AnyLayout(HStackLayout(spacing: PDSpacing.m))
            layout {
                AvatarCircle(initial: model.profile.initial, size: 56)
                HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
                    Text(model.profile.greetingName ?? "Add your name")
                        .font(Font.pd.titleDetail)
                        .tracking(-0.3)
                        .foregroundStyle(Color.pd.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "pencil")
                        .font(Font.pd.secondary.weight(.semibold))
                        .foregroundStyle(Color.pd.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, PDSpacing.xs)
            .frame(minHeight: PDMetric.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PDPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.profile.greetingName ?? "Add your name")
        .accessibilityHint(model.profile.greetingName == nil ? "Tells Pocketd what to call you" : "Changes your name")
        .accessibilityAddTraits([.isButton, .isHeader])
    }

    // MARK: - Brain

    private var brainSection: some View {
        let row = brainRow
        return YouSection("Brain") {
            NavRow(symbol: "brain", title: row.title, detail: row.detail) {
                navigator.push(.brain)
            }
        }
    }

    /// The one row, in two short lines: which brain, and whether it is ready
    /// — decided in the Kit (`BrainRowSummary`) from `brainStatus`, the same
    /// answer every other screen reads.
    private var brainRow: BrainRowSummary {
        BrainRowSummary.make(
            status: model.brainStatus,
            usingBuiltIn: model.isUsingBuiltInBrain,
            builtInAvailability: model.builtInAvailability,
            downloadName: downloadName,
            waitingReadsYourDay: waitingDownload?.dayAccess().readsYourDay ?? true
        )
    }

    /// The download answering the phone, loading, on its way, or waiting on
    /// disk — whichever is most true now.
    private var downloadName: String? {
        let ids = [
            model.loadedModelID,
            model.loadingModelID,
            model.visibleTransfers.first(where: \.isActive)?.id,
            waitingDownload?.id,
        ]
        guard let id = ids.compactMap({ $0 }).first(where: { $0 != ModelRecord.builtInID }) else { return nil }
        return model.catalog.first { $0.id == id }?.displayName
    }

    /// The installed download that would load next — the chosen one first.
    private var waitingDownload: ModelRecord? {
        let id: String?
        if case let .downloaded(chosen)? = model.effectiveBrain {
            id = chosen
        } else {
            id = model.installed.first?.id
        }
        guard let id else { return nil }
        return model.catalog.first { $0.id == id }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        YouSection("Privacy") {
            // The Privacy page's own promise, word for word: brain downloads
            // and (if allowed) anonymous usage counts do leave, so "nothing"
            // would be the one untrue line on this page.
            NavRow(symbol: "lock", title: "Privacy", detail: "Nothing personal leaves your phone") {
                navigator.push(.privacy)
            }
        }
    }

    // MARK: - Use from your laptop

    private var laptopSection: some View {
        YouSection("Use from your laptop") {
            // The "Pro" capsule before the tap, not after it: the page opens
            // for anyone, the switch on it is Pocketd Pro.
            NavRow(
                symbol: "laptopcomputer",
                title: "Other devices",
                detail: model.laptopAccessSummary,
                status: ProBadge.status(for: pro)
            ) {
                navigator.push(.devices)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        YouSection("About") {
            // Pocketd Pro (Unlock / On) and, while it is off, Restore
            // purchase; ends with its own divider. See `ProAboutRows`.
            ProAboutRows()
            LinkRow(symbol: "star", title: "Rate Pocketd") {
                openURL(Self.reviewURL)
            }
            RowDivider()
            LinkRow(symbol: "doc.text", title: "Privacy policy") {
                openURL(Self.policyURL)
            }
            RowDivider()
            ActionRow(symbol: "sparkles", title: "Replay intro") {
                // Back to Today first, so the intro ends where a first run
                // does rather than two screens deep in You.
                navigator.go(.today)
                model.replayOnboarding()
            }
            RowDivider()
            NavRow(symbol: "info.circle", title: "About Pocketd", detail: "Version \(AboutSheet.version)") {
                showingAbout = true
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        YouSection("Advanced") {
            NavRow(symbol: "text.quote", title: "Assistant instructions", detail: instructionsPreview) {
                navigator.push(.instructions)
            }
            RowDivider()
            NavRow(symbol: "slider.horizontal.3", title: "Server settings", detail: "How other devices are answered") {
                navigator.push(.settings)
            }
            RowDivider()
            NavRow(symbol: "waveform.path.ecg", title: "Diagnostics", detail: "What Pocketd has been doing") {
                navigator.push(.diagnostics)
            }
        }
    }

    /// "Standard", or the first line of somebody's own, cut short — a row is
    /// not where a paragraph of instructions gets read.
    private var instructionsPreview: String {
        let trimmed = model.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != InstructionsView.standard else { return "Standard" }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return firstLine.count > 42 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
}

// MARK: - Name

/// One field, because there is one thing this app knows about the person.
private struct NameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.l) {
                Text("What should Pocketd call you?")
                    .pdHero()
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only for the greeting. It stays on this iPhone.")
                    .pdSubtitle()
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Your name", text: $draft)
                    .accessibilityLabel("Your name")
                    .font(Font.pd.body)
                    .foregroundStyle(Color.pd.ink)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(save)
                    .padding(.horizontal, PDSpacing.m)
                    .padding(.vertical, PDSpacing.s)
                    .frame(minHeight: PDMetric.askBarHeight)
                    .background(Color.pd.chip, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1)
                    )
            }
            .padding(PDSpacing.heroGutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Pinned rather than at the end of the scroll: at the largest text
        // sizes the question alone fills a medium sheet, and Save must not be
        // a scroll away from the keyboard.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: PDSpacing.xxs) {
                PrimaryButton(title: "Save", arrow: false, action: save)
                SecondaryLink("Not now") { dismiss() }
            }
            .padding(.horizontal, PDSpacing.heroGutter)
            .padding(.bottom, PDSpacing.s)
            .background(Color.pd.canvas)
        }
        .pdCanvas()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            draft = model.profile.name
            focused = true
        }
    }

    private func save() {
        model.profile.name = draft
        Haptics.success()
        dismiss()
    }
}

// MARK: - About

/// Version, build, and where the source is.
///
/// No logo and no marketing sentence: the interesting claim this app makes is
/// that its details are checkable, so the screen that names it links to the
/// place they can be checked.
struct AboutSheet: View {
    @Environment(\.openURL) private var openURL

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private static let repository = URL(string: "https://github.com/dheerajjha/pocketd")!

    /// The outside components, named because the privacy page names them and
    /// a licences link that lists nothing is theatre.
    private let components: [(name: String, detail: String, url: String)] = [
        ("llama.cpp", "MIT · runs private downloads", "https://github.com/ggml-org/llama.cpp"),
        ("LocalLLMClient", "MIT · the Swift wrapper around it", "https://github.com/tattn/LocalLLMClient"),
        ("FlyingFox", "MIT · answers other devices", "https://github.com/swhitty/FlyingFox"),
        ("Mixpanel", "Apache 2.0 · sends the usage counts", "https://github.com/mixpanel/mixpanel-swift"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.xl) {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    Text("Pocketd")
                        .font(Font.pd.titleDetail)
                        .foregroundStyle(Color.pd.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your day, read from your phone, in plain words. Nothing leaves it.")
                        .pdSubtitle()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, PDSpacing.l)

                YouSection("This build") {
                    ValueRow(title: "Version", value: Self.version)
                    RowDivider(inset: 0)
                    ValueRow(title: "Build", value: Self.build)
                }

                YouSection("Open source", footnote: "Every claim Pocketd makes about itself can be checked in its source.") {
                    LinkRow(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        title: "Source",
                        detail: "github.com/dheerajjha/pocketd"
                    ) {
                        openURL(Self.repository)
                    }
                    ForEach(components, id: \.name) { component in
                        RowDivider()
                        LinkRow(symbol: "shippingbox", title: component.name, detail: component.detail) {
                            if let url = URL(string: component.url) { openURL(url) }
                        }
                    }
                }
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.bottom, PDSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .pdCanvas()
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Routes

/// What each `YouRoute` shows.
///
/// A switch in one place so that adding a route is a compiler error here
/// rather than a blank screen at runtime. Every page behind it is pushed onto
/// the one stack and brings no `NavigationStack` of its own — one that did
/// would trap inside SwiftUI on the way in.
struct YouRouteView: View {
    let route: YouRoute

    var body: some View {
        switch route {
        case .brain:
            BrainView()
        case .addBrain:
            MoreBrainsView()
        case .brainAdvanced:
            BrainAdvancedView()
        case .devices:
            OtherDevicesView()
        case .deskMode:
            // Desk mode is a mode, not a page: RootView swaps the whole screen
            // for it while `model.deskMode` is set, and it has no back button.
            // Nothing pushes this route; if something ever does, it lands on
            // the page whose button turns desk mode on.
            OtherDevicesView()
        case .privacy:
            PrivacyView()
        case .privacyDetails:
            PrivacyDetailsView()
        case .settings:
            ServerSettingsView()
        case .instructions:
            InstructionsView()
        case .diagnostics:
            DiagnosticsView()
        }
    }
}

// MARK: - Previews

#Preview("You light") {
    NavigationStack { YouView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("You dark") {
    NavigationStack { YouView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
