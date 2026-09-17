import PocketdKit
import SwiftUI

/// What the assistant is allowed to see, as three rows on the You screen.
///
/// This is v1's whole Abilities screen, folded into a section. The screen was
/// the right idea at the wrong altitude: three switches that decide whether
/// this app is an assistant or a local chat box do not deserve a destination,
/// they deserve to be the first thing on the profile.
///
/// Every claim here is still decided in `PocketdKit/Abilities` rather than in a
/// `body`. A claim assembled inline is a claim nobody can write a test against,
/// and the whole value of these rows is that the state beside an ability can be
/// trusted. What lives here is the adapter — turning EventKit, HealthKit and
/// the engine's budget into the two facts `AbilityPresentation` asks for — plus
/// the rendering.
///
/// The server used to be the fourth row. It is its own section now, under
/// "Other devices", because it reads nothing of the user's and sharing a
/// heading with three things that do was always a category error.
struct AbilitiesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// What iOS says about the two EventKit entities, including the ones whose
    /// switch is off.
    ///
    /// `AppModel.personalDataAuthorization` deliberately holds no entry for a
    /// switched-off entity — it is what the warnings are built from, and a
    /// warning about a capability somebody has switched off is a complaint.
    /// This section shows abilities whether they are on or not, so it keeps its
    /// own reading. Cached rather than read in `body` because
    /// `EKEventStore.authorizationStatus` is a synchronous TCC lookup that a
    /// SwiftUI body would run on every redraw, and because the transitions that
    /// matter — the prompt being answered, the user coming back from iOS
    /// Settings — are events rather than something to poll.
    @State private var eventAuthorization: [PersonalDataEntity: PersonalDataAuthorization] = [:]

    /// The three that read something of the user's. Order is the product's
    /// claim about what this is.
    private let abilities: [Ability] = [.calendar, .reminders, .health]

    var body: some View {
        YouSection("WHAT IT CAN SEE", footnote: abilityNetworkExclusionNote) {
            ForEach(Array(abilities.enumerated()), id: \.element) { index, ability in
                if index > 0 { RowDivider() }
                row(for: ability, presentation: presentation(for: ability))
            }
        }
        .task { refresh() }
        // The one way a granted permission becomes a denied one is the user
        // leaving for iOS Settings and coming back, and nothing about that trip
        // tells this process anything.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    // MARK: - One ability

    @ViewBuilder
    private func row(for ability: Ability, presentation row: AbilityPresentation) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            HStack(spacing: PDSpacing.s) {
                IconTile.small(ability.symbolName)
                // The pill under the title rather than beside it. Beside it,
                // "Needs attention" is wide enough that the title is what gets
                // squeezed, and a row reading "Cale…" beside a full-length
                // status is the wrong thing truncated.
                VStack(alignment: .leading, spacing: 4) {
                    Text(ability.title)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                    StatusPill(pill(for: ability, row.state).kind, pill(for: ability, row.state).text)
                }
                Spacer(minLength: PDSpacing.xxs)
                Toggle("", isOn: binding(for: ability))
                    .labelsHidden()
                    .tint(Color.pd.accent)
                    .disabled(row.state == .unsupported)
                    .accessibilityLabel(ability.title)
            }

            // The payoff, under the switch rather than beside it. "Read
            // calendar" — v1's Settings label — says what the app will do and
            // nothing about what the reader gets, and a switch whose payoff is
            // unstated is a switch that stays off.
            Text(ability.summary)
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // Only where the switch and the system disagree, where iOS will not
            // say, or where switching off leaves a grant standing — which is
            // the one genuinely surprising quiet state. In plain on and plain
            // off the pill above has already said everything true, and a
            // paragraph under each of three rows turns a card into a form.
            if let line = attentionLine(ability, row.state) {
                Text(line)
                    .font(Font.pd.footnote)
                    .foregroundStyle(isCalm(ability, row.state) ? Color.pd.inkTertiary : Color.pd.caution)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions(for: ability, row: row)
        }
        .padding(.vertical, PDSpacing.s)
        .accessibilityElement(children: .contain)
    }

    /// The one button a state affords, plus the door to iOS when the lever is
    /// not in this app at all.
    ///
    /// Turning on and off is the switch above, so `.turnOn` and `.turnOff` draw
    /// nothing — offering a button that does what the switch beside it does is
    /// how a row starts looking like a form.
    @ViewBuilder
    private func actions(for ability: Ability, row: AbilityPresentation) -> some View {
        let label = actionLabel(row.action, for: ability)
        // The door, only where the sentence above has just named the corridor.
        // In the calm states the sentence is not shown, so the door would be a
        // button with nothing explaining what is behind it.
        let showsSettings = row.linksToSystemSettings
            && row.action != .openSystemSettings
            && (row.state.needsAttention || row.state == .offWithGrantStanding)

        if label != nil || showsSettings {
            HStack(spacing: PDSpacing.xs) {
                if let label {
                    PillButton(title: label, symbol: symbol(for: row.action)) {
                        perform(row.action, for: ability)
                    }
                }
                if showsSettings {
                    PillButton(title: "Open Settings", symbol: "arrow.up.right", symbolTrails: true) {
                        openSystemSettings()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, PDSpacing.xxs)
        }
    }

    /// The button's words, from the state machine — except for the two the
    /// switch already performs, and one rewording.
    ///
    /// "Ask iOS again" is the developer's sentence for it. What the reader is
    /// doing is putting the question back on screen, so the button says so.
    private func actionLabel(_ action: AbilityAction, for ability: Ability) -> String? {
        switch action {
        case .turnOn, .turnOff, .none: nil
        case .askAgain: "Ask again"
        case .openSystemSettings: "Open Settings"
        case .retry: action.label(for: ability)
        }
    }

    private func symbol(for action: AbilityAction) -> String {
        switch action {
        case .askAgain: "questionmark.circle"
        case .openSystemSettings: "arrow.up.right"
        case .retry: "arrow.clockwise"
        case .turnOn, .turnOff, .none: "circle"
        }
    }

    /// What the pill says, which is four words and never more.
    ///
    /// The honest long sentence is under the row; this is the version that
    /// scans down a list of three. Every state where the switch says one thing
    /// and the system says another collapses to "Needs attention", because from
    /// the outside they are the same problem: it is not working and the line
    /// below says why.
    ///
    /// The one exception is a switch that is on with no brain loaded. That is
    /// not a fault and nothing on this row can fix it — the Brain section
    /// directly below is where it is fixed — so it reads as waiting rather than
    /// as three amber warnings on a first run.
    private func pill(for ability: Ability, _ state: AbilityState) -> (kind: StatusPill.Kind, text: String) {
        switch state {
        case .unsupported:
            (.neutral, "Not available")
        case .off, .offWithGrantStanding, .offAndRefused, .offAndAddOnly, .offAndRestricted:
            (.neutral, "Off")
        case .pending:
            (.neutral, "Checking…")
        case .on:
            (.positive, "Connected")
        case .onButWithheld where withheld(for: ability) == .noBrain:
            (.neutral, "Waiting for a brain")
        case .onAwaitingGrant, .onAndRefused, .onAndAddOnly, .onAndRestricted,
             .onButUnconfirmed, .onButWithheld, .onButFailed:
            (.caution, "Needs attention")
        }
    }

    /// Whether a row's detail line is information rather than a warning.
    private func isCalm(_ ability: Ability, _ state: AbilityState) -> Bool {
        if state == .offWithGrantStanding { return true }
        if case .onButWithheld = state, withheld(for: ability) == .noBrain { return true }
        return false
    }

    // MARK: - The sentence under a row

    /// Why the withholding happened, as three cases rather than as a string.
    ///
    /// `AbilityState.onButWithheld` carries the engine's own sentence, and the
    /// engine's sentences are written for the diagnostics log: "No model is
    /// loaded, so nothing is registered yet", "a 4096-token context allows 900
    /// tokens of tool schemas". Every one of those words is on the list this
    /// screen may not use. The state machine still decides *whether* the row is
    /// withheld — that part is tested — and this decides what a person is told
    /// about it.
    private enum Withheld: Equatable {
        case noBrain
        case brainCannotLookThingsUp
        case noRoom
    }

    private func withheld(for ability: Ability) -> Withheld? {
        guard let group = capabilityGroup(for: ability) else { return nil }
        if model.loadedModelID == nil { return .noBrain }
        let gate = model.personalDataToolGate
        if !gate.registersTools { return .brainCannotLookThingsUp }
        if model.capabilityPlan?.shortfall(for: group) != nil { return .noRoom }
        return nil
    }

    private func capabilityGroup(for ability: Ability) -> CapabilityGroup? {
        switch ability {
        case .calendar: .calendar
        case .reminders: .reminders
        case .health: .health
        case .localServer: nil
        }
    }

    /// The whole of what a row says under its summary, in words this screen is
    /// allowed to use.
    ///
    /// `nil` in the two calm states — plainly on, plainly off — where the pill
    /// has already said everything that is true.
    private func attentionLine(_ ability: Ability, _ state: AbilityState) -> String? {
        let path = ability.systemSettingsPath ?? "iOS Settings"
        switch state {
        case .on, .off, .pending, .unsupported:
            return nil
        case .offWithGrantStanding:
            // The one genuinely surprising quiet state: the switch is off and
            // iOS still lists the permission as granted.
            return "Switching this off stops Pocketd reading it. It does not hand the permission back to iOS — only you can, in \(path)."
        case .offAndRefused, .onAndRefused:
            return "iOS is refusing it. Allow it again in \(path)."
        case .offAndAddOnly, .onAndAddOnly:
            return "iOS is letting Pocketd add to \(ability.noun) but not read it. Change it in \(path)."
        case .offAndRestricted, .onAndRestricted:
            return "Something on this phone is blocking it — Screen Time, or a profile somebody else manages. It cannot be changed from here."
        case .onAwaitingGrant:
            return "iOS has not been asked yet, so nothing is being read. Ask again to put the question back on screen."
        case .onButUnconfirmed:
            // The only sentence Health may ever have. iOS deliberately refuses
            // to report whether a read was allowed, so a refusal and a day with
            // nothing recorded are identical from inside this app.
            return "iOS never tells an app whether a Health read was allowed, so nothing here can show you a state. Check what you have shared in \(path)."
        case .onButWithheld:
            switch withheld(for: ability) {
            case .noBrain, .none:
                return "Nothing can read \(ability.noun) until a brain is loaded."
            case .brainCannotLookThingsUp:
                return "The brain in use cannot look things up, so \(ability.noun) stays unread. A larger one can."
            case .noRoom:
                return "There is not enough room for everything at once, so this one was left out. Turning another off makes room."
            }
        case let .onButFailed(reason):
            return reason
        }
    }

    // MARK: - The switch

    private func binding(for ability: Ability) -> Binding<Bool> {
        Binding(
            get: { isEnabled(ability) },
            set: { setEnabled($0, ability) }
        )
    }

    private func isEnabled(_ ability: Ability) -> Bool {
        switch ability {
        case .calendar: model.calendarToolsEnabled
        case .reminders: model.reminderToolsEnabled
        case .health: model.healthToolsEnabled
        case .localServer: model.serverShouldRun || model.serverState.isRunning
        }
    }

    private func setEnabled(_ on: Bool, _ ability: Ability) {
        // Recorded here and not in AppModel, because the question this answers
        // is whether THIS SCREEN works — the same setter is reachable from the
        // in-chat offer, and a single event with no source could not tell them
        // apart.
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

    private func perform(_ action: AbilityAction, for ability: Ability) {
        switch action {
        case .turnOn: setEnabled(true, ability)
        case .turnOff: setEnabled(false, ability)
        case .askAgain: askAgain(ability)
        case .retry: Task { await model.startServer() }
        case .openSystemSettings: openSystemSettings()
        case .none: break
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    /// Puts a question iOS has not answered back to the user.
    ///
    /// Only reachable from `.onAwaitingGrant`, which is the one state where
    /// there is anything to ask. Costs nothing if the question turns out to be
    /// settled after all: iOS shows its prompt once and every later call
    /// returns the standing answer without any UI.
    private func askAgain(_ ability: Ability) {
        guard let entity = ability.entity else { return }
        // Through AppModel rather than EventAccess directly: the answer has to
        // land in `personalDataAuthorization`, which every other surface reads.
        Task {
            await model.requestAccess(to: entity)
            refresh()
        }
    }

    // MARK: - Turning the system into the two facts

    private func presentation(for ability: Ability) -> AbilityPresentation {
        switch ability {
        case .calendar:
            eventKitRow(.calendar, entity: .calendar, group: .calendar)
        case .reminders:
            eventKitRow(.reminders, entity: .reminders, group: .reminders)
        case .health:
            AbilityPresentation.decide(
                .health,
                enabled: model.healthToolsEnabled,
                grant: healthGrant,
                registration: registration(enabled: model.healthToolsEnabled, group: .health)
            )
        case .localServer:
            AbilityPresentation.decide(
                .localServer,
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
        // the only honest answer available that early, and cheaper than showing
        // a state nobody has looked up.
        model.personalDataAuthorization[entity]
            ?? eventAuthorization[entity]
            ?? EventAccess.authorization(for: entity)
    }

    /// HealthKit's answer, which is never about a read.
    ///
    /// `.available` becomes `.neverReported` rather than `.granted`, and that
    /// is the whole point: `HKAuthorizationStatus` describes write access, and
    /// a refused read is indistinguishable from a day with nothing recorded.
    /// The coercion in `AbilityState.of` would catch a mistake here anyway;
    /// getting it right at the source means the screen is not relying on the
    /// safety net.
    private var healthGrant: AbilityGrant {
        guard HealthAccess.isAvailable else { return .unavailable }
        switch model.healthAvailability {
        case .available: return .neverReported
        case .noHealthData: return .unavailable
        case let .requestFailed(reason): return .failed(reason)
        }
    }

    /// A bound socket, which is an observation rather than a grant.
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

    private func refresh() {
        model.refreshPersonalDataAuthorization()
        for entity in PersonalDataEntity.allCases {
            eventAuthorization[entity] = EventAccess.authorization(for: entity)
        }
    }
}
