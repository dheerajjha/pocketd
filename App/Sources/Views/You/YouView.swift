import PocketdKit
import StoreKit
import SwiftUI
import UIKit

/// You, as one screen.
///
/// v1 spread this over five tabs and three sheets: Abilities, Models, Server,
/// Settings, Data. Every one of them was named after a subsystem, and between
/// them they answered one question — what this assistant can see, what it
/// thinks with, who else can use it, and what it keeps. That is a profile, so
/// it is a profile now: five sections, each a mono label over a card of rows,
/// and everything technical exactly one level further down.
///
/// The sections are ordered by how often somebody has a reason to touch them,
/// not by how the code is arranged. What it can see is first because it is the
/// difference between this app and a local chat box.
struct YouView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview

    @State private var editingName = false
    @State private var editingInstructions = false
    @State private var showingAbout = false

    /// Where the published policy lives. Written out rather than assembled,
    /// because a privacy link that 404s is worse than no privacy link.
    private static let policyURL = URL(string: "https://dheerajjha.github.io/pocketd/")!

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                    header.pdStaggerIn(0)
                    AbilitiesSection().pdStaggerIn(1).id("abilities")
                    brainSection.pdStaggerIn(2).id("brain")
                    OtherDevicesSection().pdStaggerIn(3).id("devices")
                    privacySection.pdStaggerIn(4).id("privacy")
                    settingsSection.pdStaggerIn(5).id("settings")
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.xs)
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
        // The floating bar's space, as safe area rather than padding, so the
        // list runs under the capsule and its last row still clears it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: PDMetric.tabBarClearance)
        }
        // Wash behind the content but in front of the flat canvas — the other
        // order makes the gradient invisible.
        .pdHeroWash()
        .pdCanvas()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $editingName) { NameSheet() }
        .sheet(isPresented: $editingInstructions) { InstructionsSheet() }
        .sheet(isPresented: $showingAbout) { AboutSheet() }
        #if DEBUG
        // A screenshot's state, asked for at launch. See `YouStage`; the whole
        // type and this call are inside `#if DEBUG`.
        .task { await YouStage.apply(model: model, navigator: navigator) }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        Button {
            Haptics.tap()
            editingName = true
        } label: {
            HStack(spacing: PDSpacing.m) {
                Text(model.profile.initial)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: PDMetric.iconTile, height: PDMetric.iconTile)
                    .background(Color.pd.avatar, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: PDSpacing.xs) {
                        Text(model.profile.greetingName ?? "Add your name")
                            .font(Font.pd.titleDetail)
                            .foregroundStyle(Color.pd.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.pd.inkTertiary)
                    }
                    Text("Pocketd on \(UIDevice.current.model)")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, PDSpacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.profile.greetingName ?? "No name set"). Pocketd on \(UIDevice.current.model). Double tap to change your name.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Brain

    private var brainSection: some View {
        YouSection("BRAIN") {
            NavRow(
                symbol: "brain",
                title: brain.title,
                detail: brain.detail,
                status: brain.status
            ) {
                navigator.push(.brain)
            }
        }
    }

    /// The one row, and the four things it can be saying.
    ///
    /// "No brain yet" rather than "No model loaded", and the real name under it
    /// whenever there is one: somebody who has never heard the word model still
    /// needs to be able to tell two of them apart, and the manufacturer's name
    /// is how.
    private var brain: (title: String, detail: String, status: (kind: StatusPill.Kind, text: String)) {
        if let id = model.loadedModelID {
            let record = model.catalog.first { $0.id == id }
            let detail = record.map { "\(pdFitWords(model.fit(for: $0))) · \(pdBytes($0.totalDownloadBytes))" }
                ?? "On this phone"
            return (model.loadedModelName, detail, (.positive, "Ready"))
        }
        if let loading = model.loadingModelID {
            let name = model.catalog.first { $0.id == loading }?.displayName ?? loading
            return (name, "Warming up", (.neutral, "Loading…"))
        }
        if let transfer = model.visibleTransfers.first(where: { $0.isActive }) {
            let name = model.catalog.first { $0.id == transfer.id }?.displayName ?? "A brain"
            let percent = Int((transfer.fraction * 100).rounded(.down))
            return (name, "Downloading · \(percent)%", (.neutral, "On its way"))
        }
        if let first = model.installed.first {
            return (first.displayName, "On this phone, not in use yet", (.neutral, "Not loaded"))
        }
        return ("No brain yet", "Pocketd needs one before it can answer anything", (.caution, "Needed"))
    }

    // MARK: - Privacy

    private var privacySection: some View {
        @Bindable var model = model

        return YouSection(
            "PRIVACY",
            footnote: "Usage counts say which screens were opened and whether a brain loaded. They can never carry a word you typed, a reply, or anything read from your calendar, reminders or health."
        ) {
            NavRow(
                symbol: "lock",
                title: "What leaves this phone",
                detail: "Every byte this app holds, counted and deletable"
            ) {
                navigator.push(.privacy)
            }
            RowDivider()
            ToggleRow(
                symbol: "chart.bar",
                title: "Share anonymous usage counts",
                detail: "On by default; the switch is here, not buried",
                isOn: Binding(
                    get: { model.analyticsConsent.permitsSending },
                    set: { model.setAnalyticsConsent($0 ? .granted : .refused) }
                )
            )
            RowDivider()
            LinkRow(
                symbol: "doc.text",
                title: "Privacy policy",
                detail: "The published page, checkable against the source"
            ) {
                openURL(Self.policyURL)
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        @Bindable var model = model

        return YouSection(
            "SETTINGS",
            // The explanation the two memory rows are too narrow to carry. It
            // belongs under the card rather than inside a row: a row detail
            // eight lines deep stops being a row.
            footnote: "A loaded brain holds its weights the whole time it is in memory. Letting go when you leave makes iOS far less likely to end the app while it is away, and the next question loads it again in a few seconds."
        ) {
            LinkRow(
                symbol: "bell",
                title: "Notifications",
                detail: "Routines tell you when they are ready"
            ) {
                openSystemSettings()
            }
            RowDivider()
            ToggleRow(
                symbol: "memorychip",
                title: "Keep the brain loaded in the background",
                detail: "Off lets go of it when you leave",
                isOn: Binding(
                    get: { !model.autoOffloadInBackground },
                    set: { model.autoOffloadInBackground = !$0 }
                )
            )
            RowDivider()
            MenuRow(
                symbol: "clock.arrow.circlepath",
                title: "Unload after idle",
                detail: "Frees the memory when it sits unused",
                selection: $model.idleOffloadSeconds,
                options: [
                    (0, "Never"),
                    (300, "5 minutes"),
                    (900, "15 minutes"),
                    (1800, "30 minutes"),
                ]
            )
            RowDivider()
            NavRow(
                symbol: "text.quote",
                title: "Assistant instructions",
                detail: instructionsPreview
            ) {
                editingInstructions = true
            }
            RowDivider()
            NavRow(
                symbol: "waveform.path.ecg",
                title: "Diagnostics",
                detail: "What the app has been doing, in order"
            ) {
                navigator.push(.diagnostics)
            }
            RowDivider()
            LinkRow(
                symbol: "star",
                title: "Rate Pocketd",
                detail: "The whole marketing budget"
            ) {
                requestReview()
            }
            RowDivider()
            NavRow(
                symbol: "sparkles",
                title: "Replay intro",
                detail: "Nothing is reset or lost"
            ) {
                model.replayOnboarding()
            }
            RowDivider()
            NavRow(
                symbol: "info.circle",
                title: "About",
                detail: "Version \(AboutSheet.version), open source"
            ) {
                showingAbout = true
            }
        }
    }

    private var instructionsPreview: String {
        let trimmed = model.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Nothing set" : trimmed
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
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
        VStack(alignment: .leading, spacing: PDSpacing.l) {
            Text("What should it\ncall you?")
                .pdHero()
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Only for the greeting. It stays on this phone and goes nowhere else.")
                .pdSubtitle()
                .fixedSize(horizontal: false, vertical: true)

            TextField("Your name", text: $draft)
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .padding(.horizontal, PDSpacing.m)
                .frame(height: PDMetric.askBarHeight)
                .background(Color.pd.chip, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1)
                )

            Spacer(minLength: 0)

            PrimaryButton(title: "Save", arrow: false, action: save)
            SecondaryLink("Not now") { dismiss() }
                .frame(maxWidth: .infinity)
        }
        .padding(PDSpacing.heroGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pdCanvas()
        .presentationDetents([.medium])
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

// MARK: - Assistant instructions

/// The system prompt, under the only name for it that means anything.
private struct InstructionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private static let standard = "You are a helpful assistant."

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.l) {
            Text("How it should\nanswer you.")
                .pdHero()
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("A standing instruction the assistant is given before every conversation. Keep it short — every word here is a word of the conversation it cannot hold.")
                .pdSubtitle()
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $draft)
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(PDSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous)
                        .fill(Color.pd.chip)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PDRadius.tile, style: .continuous)
                        .strokeBorder(Color.pd.cardStroke, lineWidth: 1)
                )
                .accessibilityLabel("Assistant instructions")

            SecondaryLink("Put the standard one back") { draft = Self.standard }

            Spacer(minLength: 0)

            PrimaryButton(title: "Save", arrow: false) {
                model.systemPrompt = draft
                Haptics.success()
                dismiss()
            }
        }
        .padding(PDSpacing.heroGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pdCanvas()
        .presentationDragIndicator(.visible)
        .onAppear { draft = model.systemPrompt }
    }
}

// MARK: - About

/// Version, build, and where the source is.
///
/// No logo and no marketing sentence: the interesting claim this app makes is
/// that its details are checkable, so the screen that names it links to the
/// place they can be checked.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private static let repository = URL(string: "https://github.com/dheerajjha/pocketd")!

    /// The three outside components, named because the privacy page names them
    /// and a licences link that lists nothing is theatre.
    private let components: [(name: String, detail: String, url: String)] = [
        ("llama.cpp", "MIT · the runtime the brain runs on", "https://github.com/ggml-org/llama.cpp"),
        ("LocalLLMClient", "MIT · the Swift wrapper around it", "https://github.com/tattn/LocalLLMClient"),
        ("FlyingFox", "MIT · the HTTP server other devices reach", "https://github.com/swhitty/FlyingFox"),
        ("Mixpanel", "Apache 2.0 · sends the usage counts", "https://github.com/mixpanel/mixpanel-swift"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    Text("Pocketd")
                        .font(Font.pd.titleDetail)
                        .foregroundStyle(Color.pd.ink)
                    Text("An assistant that lives on this phone. Nothing you say to it leaves the device.")
                        .pdSubtitle()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, PDSpacing.s)

                YouSection("THIS BUILD") {
                    ValueRow(title: "Version", value: Self.version)
                    RowDivider(inset: 0)
                    ValueRow(title: "Build", value: Self.build)
                }

                YouSection(
                    "WHAT IT IS BUILT ON",
                    footnote: "Every claim this app makes about itself is checkable against the source, which is the point of publishing it."
                ) {
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
/// A switch in one place so that adding a route is a compiler error here rather
/// than a blank screen at runtime. Every screen behind it is pushed now: none
/// of them carries a `NavigationStack` of its own any more, which is what
/// `YouRoute.bringsOwnNavigationStack` used to be protecting against.
struct YouRouteView: View {
    @Environment(AppModel.self) private var model
    let route: YouRoute

    var body: some View {
        switch route {
        case .brain:
            BrainView()
        case .addBrain:
            ModelSearchView()
        case .brainAdvanced:
            BrainAdvancedView()
        case .devices:
            DevicesView()
        case .deskMode:
            // Desk mode is a mode rather than a screen — `RootView` swaps the
            // whole shell for it. Reaching it as a route is possible from
            // `openYou(.deskMode)`, so it gets an honest destination rather
            // than a blank one.
            YouDetailScreen(title: "Desk mode", subtitle: "A dim, drifting screen for a phone left serving on a charger. It costs less battery, and a dark display leaves more of the thermal budget for answering.") {
                PrimaryButton(title: "Turn on desk mode", arrow: false) {
                    model.deskMode = true
                }
                .padding(.top, PDSpacing.s)
            }
        case .privacy:
            PrivacyView()
        case .settings:
            SettingsView()
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
