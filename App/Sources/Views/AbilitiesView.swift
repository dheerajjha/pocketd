import PocketdKit
import SwiftUI

/// One screen listing everything the assistant can be given, with its real
/// state beside it.
///
/// The failure this replaces: the three things that make this app something
/// other than a local chat box — reading your calendar, your reminders and your
/// health — were three switches two thirds of the way down Settings, defaulting
/// off, under a header nobody scrolls to. The differentiator was invisible, and
/// a capability nobody can find is a capability the product does not have.
///
/// Every claim on this screen is decided in `PocketdKit/Abilities` rather than
/// here, and for the reason the data inspector gives about its own copy: a claim
/// assembled inline in a `body` is a claim nobody can write a test against, and
/// this screen's whole value is that the state beside an ability can be trusted.
/// What is left here is the adapter — turning EventKit, HealthKit, the engine's
/// budget and a listening socket into the two facts `AbilityPresentation` asks
/// for — plus the rendering.
struct AbilitiesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    var goTo: (AppTab) -> Void = { _ in }

    /// What iOS says about the two EventKit entities, including the ones whose
    /// switch is off.
    ///
    /// `AppModel.personalDataAuthorization` deliberately holds no entry for a
    /// switched-off entity — it is what Settings turns into warnings, and a
    /// warning about a capability somebody has switched off is a complaint. This
    /// screen is the one that shows abilities whether they are on or not, so it
    /// keeps its own reading. Cached rather than read in `body` because
    /// `EKEventStore.authorizationStatus` is a synchronous TCC lookup that a
    /// SwiftUI body would run on every redraw, and because the transitions that
    /// matter — the prompt being answered, the user coming back from iOS
    /// Settings — are events rather than something to poll.
    @State private var eventAuthorization: [PersonalDataEntity: PersonalDataAuthorization] = [:]

    var body: some View {
        NavigationStack {
            List {
                openingSection
                ForEach(Ability.allCases) { ability in
                    section(for: ability, row: presentation(for: ability))
                }
            }
            .navigationTitle("Abilities")
        }
        .task { refresh() }
        // The one way a granted permission becomes a denied one is the user
        // leaving for iOS Settings and coming back, and nothing about that trip
        // tells this process anything.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    // MARK: - The opening

    private var openingSection: some View {
        Section {
            Text("What the assistant on this phone can do, and where each one actually stands.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if hasWorkingAbility {
                // Only once something is live. Sending someone to Chat to try an
                // ability they have not enabled is sending them to watch a model
                // invent a calendar, which is the failure the abilities exist to
                // end rather than a demonstration of them.
                Button("Ask it something") { goTo(.chat) }
            }
        } footer: {
            // At the top rather than under the list, because it is the
            // objection a reader has while they are reading the first row and
            // not after the last one: three abilities that read someone's
            // calendar, on a phone this same app puts on the network.
            // `RequestOrigin.mayReachPersonalData` is what makes it true.
            Text(abilityNetworkExclusionNote)
        }
    }

    /// Whether any ability will actually answer a question right now.
    private var hasWorkingAbility: Bool {
        Ability.allCases.contains { $0.readsPersonalData && presentation(for: $0).state.isWorking }
    }

    // MARK: - One ability

    @ViewBuilder
    private func section(for ability: Ability, row: AbilityPresentation) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                // The payoff first and the state under it. "Read calendar" —
                // the Settings switch's label — says what the app will do and
                // nothing about what the reader gets, and a switch whose payoff
                // is unstated is a switch that stays off.
                Text(ability.summary)
                Text(row.statusLine)
                    .font(.footnote)
                    .foregroundStyle(row.state.needsAttention ? warning : Color.secondary)
                if let note = row.revocationNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let address = servingAddress, ability == .localServer {
                    Text(address)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            // With the note folded in. Combining derives a label from the
            // children and a following override replaces it outright, so the
            // sentence that makes a row honest — the one saying iOS never
            // reports whether a Health read was allowed — would otherwise have
            // no route out to VoiceOver at all.
            .accessibilityLabel(permissionAnnouncement(
                title: ability.title,
                state: row.statusLine,
                note: row.revocationNote
            ))

            if let label = row.action.label(for: ability) {
                Button(label) { perform(row.action, for: ability) }
            }
            if row.linksToSystemSettings {
                // Opens the front door and no further: the per-entity switches
                // live under Privacy & Security and no app can deep-link a user
                // to them. The status line above says which corridor.
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            if ability == .localServer, model.serverState.isRunning {
                Button("Server details") { goTo(.server) }
            }
        } header: {
            Label(ability.title, systemImage: ability.symbolName)
        }
    }

    private var servingAddress: String? {
        guard case let .running(host, port) = model.serverState else { return nil }
        return "http://\(host):\(port)"
    }

    // MARK: - Turning the system into the two facts

    private func presentation(for ability: Ability) -> AbilityPresentation {
        switch ability {
        case .calendar:
            return eventKitRow(.calendar, entity: .calendar, group: .calendar)
        case .reminders:
            return eventKitRow(.reminders, entity: .reminders, group: .reminders)
        case .health:
            return AbilityPresentation.decide(
                .health,
                enabled: model.healthToolsEnabled,
                grant: healthGrant,
                registration: registration(enabled: model.healthToolsEnabled, group: .health)
            )
        case .localServer:
            return AbilityPresentation.decide(
                .localServer,
                // A listening socket counts as on even while the user is in the
                // middle of turning it off. `stopServer` flips
                // `serverShouldRun` before the listener is actually down, and
                // reading the flag alone printed "Off. Nothing else on your
                // network can reach this phone" over a server that was still
                // answering — a state lie on the screen whose whole argument is
                // that it does not tell them.
                enabled: model.serverShouldRun || model.serverState.isRunning,
                grant: serverGrant
            )
        }
    }

    private func eventKitRow(
        _ ability: Ability,
        entity: PersonalDataEntity,
        group: CapabilityGroup
    ) -> AbilityPresentation {
        let enabled = model.isEnabled(entity)
        return AbilityPresentation.decide(
            ability,
            enabled: enabled,
            grant: AbilityGrant(authorization(for: entity)),
            registration: registration(enabled: enabled, group: group)
        )
    }

    private func authorization(for entity: PersonalDataEntity) -> PersonalDataAuthorization {
        // The app's own cache when it has one, this screen's otherwise, and a
        // direct read on the single frame before `.task` has landed — which is
        // the only honest answer available that early, and cheaper than the
        // alternative of showing a state we have not looked up.
        model.personalDataAuthorization[entity]
            ?? eventAuthorization[entity]
            ?? EventAccess.authorization(for: entity)
    }

    /// HealthKit's answer, which is never about a read.
    ///
    /// `.available` becomes `.neverReported` rather than `.granted`, and that is
    /// the whole point: `HKAuthorizationStatus` describes write access, and a
    /// refused read is indistinguishable from a day with nothing recorded. The
    /// coercion in `AbilityState.of` would catch a mistake here anyway; getting
    /// it right at the source means the screen is not relying on the safety net.
    private var healthGrant: AbilityGrant {
        guard HealthAccess.isAvailable else { return .unavailable }
        switch model.healthAvailability {
        case .available: return .neverReported
        case .noHealthData: return .unavailable
        case let .requestFailed(reason): return .failed(reason)
        }
    }

    /// A bound socket, which is an observation rather than a grant.
    ///
    /// Local Network authorization is not reportable to an app either, and it
    /// gates Bonjour advertising and outbound discovery rather than the inbound
    /// accept — so a listening server is genuinely serving even when nothing can
    /// find it by name, and `.granted` here means exactly "it is listening".
    ///
    /// Stopped-but-wanted is `.inProgress` rather than a failure: iOS tears the
    /// listener down on suspend and `AppModel` puts it back on the next
    /// foreground, so on a screen the user is looking at it is a transition.
    private var serverGrant: AbilityGrant {
        switch model.serverState {
        case .running: .granted
        case .starting: .inProgress
        case let .failed(reason): .failed(reason)
        case .stopped: model.serverShouldRun ? .inProgress : .notAsked
        }
    }

    /// What the engine did with the switch.
    ///
    /// The gate is asked before the budget, in that order, because a gate
    /// refusal means nothing was ever priced and the budget has nothing to add.
    /// `CapabilityNotice` ranks the same two the same way and says why at
    /// length; this is that ranking applied one capability at a time, which is
    /// what a screen with a row per capability needs.
    private func registration(enabled: Bool, group: CapabilityGroup) -> AbilityRegistration {
        guard enabled else { return .notApplicable }
        let gate = model.personalDataToolGate
        if !gate.registersTools, let sentence = gate.explanation(modelName: model.loadedModelName) {
            return .withheld(sentence)
        }
        if let shortfall = model.capabilityPlan?.shortfall(for: group) {
            return .withheld(shortfall)
        }
        return .registered
    }

    // MARK: - Doing the one thing

    private func perform(_ action: AbilityAction, for ability: Ability) {
        switch action {
        case .turnOn: setEnabled(true, ability)
        case .turnOff: setEnabled(false, ability)
        case .askAgain: askAgain(ability)
        case .retry: Task { await model.startServer() }
        case .openSystemSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .none: break
        }
    }

    private func setEnabled(_ on: Bool, _ ability: Ability) {
        // Recorded here and not in AppModel, because the question this answers
        // is whether THIS SCREEN works — the same setter is reachable from the
        // in-chat offer and from Settings, and a single event with no source
        // could not tell them apart.
        if ability != .localServer {
            model.record(
                on
                ? .abilityEnabled(ability: ability.rawValue, source: .abilitiesScreen)
                : .abilityDisabled(ability: ability.rawValue)
            )
        }
        switch ability {
        // Setting these is what asks iOS: `AppModel` puts the prompt at the
        // switch rather than at first tool use, because first use is
        // mid-generation — the stream open, the gate held, and nothing on
        // screen connecting the sheet to what the user typed.
        case .calendar: model.calendarToolsEnabled = on
        case .reminders: model.reminderToolsEnabled = on
        case .health: model.healthToolsEnabled = on
        case .localServer:
            Task { on ? await model.startServer() : await model.stopServer() }
        }
    }

    /// Puts a question iOS has not answered back to the user.
    ///
    /// Only reachable from `.onAwaitingGrant`, which is the one state where
    /// there is anything to ask. Costs nothing if the question turns out to be
    /// settled after all: iOS shows its prompt once and every later call returns
    /// the standing answer without any UI.
    private func askAgain(_ ability: Ability) {
        guard let entity = ability.entity else { return }
        // Through AppModel rather than EventAccess directly: the answer has to
        // land in `personalDataAuthorization`, which every other surface reads.
        // Asking here and refreshing afterwards prompts correctly and leaves a
        // window where the rest of the app still believes the old answer.
        Task {
            await model.requestAccess(to: entity)
            refresh()
        }
    }

    private func refresh() {
        model.refreshPersonalDataAuthorization()
        for entity in PersonalDataEntity.allCases {
            eventAuthorization[entity] = EventAccess.authorization(for: entity)
        }
    }

    // MARK: - Colour that survives light mode

    /// `Color.orange` is meant for fills. As `.footnote` body copy on the light
    /// grouped background it measures 2.20:1 against WCAG AA's 4.5:1, so a
    /// warning written in it reads clearly in dark mode and is nearly invisible
    /// in light — invisible, too, to anyone developing in dark.
    /// `StoredDataPresentationTests` asserts the ratios these components reach.
    private var warning: Color {
        Color(uiColor: UIColor { traits in
            let chosen = traits.userInterfaceStyle == .dark
                ? StoredDataPalette.warningOnDark
                : StoredDataPalette.warningOnLight
            return UIColor(
                red: CGFloat(chosen.red),
                green: CGFloat(chosen.green),
                blue: CGFloat(chosen.blue),
                alpha: 1
            )
        })
    }
}
