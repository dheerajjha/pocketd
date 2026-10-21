import PocketdKit
import SwiftUI

/// WHAT POCKETD CAN SEE: Calendar, Reminders and Health, one switch each.
///
/// Three rows that say one of three things — On, Off, or "Off in iOS
/// Settings" — and nothing else. This section used to print a pill and a
/// paragraph per row, and the worst of them was about the brain rather than
/// the permission: a granted calendar read "Needs attention" because the
/// brain in use could not look anything up, three times, in amber. Whether a
/// brain can read the day is said once, on the Brain row below, where it can
/// be fixed. Health that is on says On: iOS never reports a Health read, and
/// a row that says so in a paragraph is a row nobody can act on.
///
/// The switch is the one connect door (`AppModel.connect(_:from:)`): turning
/// it on raises the iOS sheet when iOS has never been asked, and opens the
/// Settings app when iOS already said no. A row iOS has refused shows no
/// switch at all — a switch that flips and springs back is a broken switch —
/// and the whole row is the way to Settings instead.
struct AbilitiesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.scenePhase) private var scenePhase

    /// What iOS says about the two EventKit sources, including a switched-off
    /// one — `AppModel.personalDataAuthorization` drops the entry for a source
    /// that is off. Cached rather than read in `body`: the lookup is a
    /// synchronous TCC call, and the moments it can change — the sheet being
    /// answered, a trip to Settings — are events this section hears about.
    @State private var eventAuthorization: [PersonalDataEntity: PersonalDataAuthorization] = [:]

    /// The order is the product's claim about what Pocketd is for.
    private let sources: [Ability] = [.calendar, .reminders, .health]

    var body: some View {
        YouSection("What Pocketd can see") {
            ForEach(Array(sources.enumerated()), id: \.element) { index, ability in
                if index > 0 { RowDivider() }
                row(ability)
            }
        }
        .task { refresh() }
        // The one way a granted permission becomes a refused one is the user
        // leaving for iOS Settings and coming back, and nothing about that
        // trip tells this process anything.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    // MARK: - One row

    @ViewBuilder
    private func row(_ ability: Ability) -> some View {
        let shown = SourceSwitch.of(state(of: ability))
        let detail = SourceSwitch.detail(for: ability)
        Group {
            if shown.isSwitch {
                SourceRow(
                    symbol: ability.symbolName,
                    title: ability.title,
                    detail: detail,
                    accessory: .toggle(binding(for: ability, isOn: shown == .on))
                )
            } else if shown.rowOpensSettings {
                // Through the door rather than straight to Settings: the door
                // sets the switch too, so allowing it there needs no second
                // tap here on the way back. Add-only calendars go through it
                // for the same reason, and iOS may ask once more first.
                SourceRow(
                    symbol: ability.symbolName,
                    title: ability.title,
                    detail: detail,
                    accessory: .status(shown.statusText ?? "", isOn: false)
                ) {
                    connect(ability)
                }
                .accessibilityHint("Opens Settings")
            } else {
                SourceRow(
                    symbol: ability.symbolName,
                    title: ability.title,
                    detail: detail,
                    accessory: .status(shown.statusText ?? "", isOn: false)
                )
            }
        }
        .padding(.vertical, PDSpacing.s)
        .frame(minHeight: PDMetric.minHitTarget)
    }

    // MARK: - The switch

    private func binding(for ability: Ability, isOn: Bool) -> Binding<Bool> {
        Binding(
            get: { isOn },
            set: { on in
                if on {
                    connect(ability)
                } else {
                    model.disconnect(ability)
                    refresh()
                }
            }
        )
    }

    /// Through the one door. Nothing here says "connected": the switch moving
    /// is the answer when iOS allows it, and the row itself changes to "Off in
    /// iOS Settings" when it does not. Only a request iOS never put on screen
    /// gets a sentence, because nothing else on the row would explain it.
    private func connect(_ ability: Ability) {
        Task {
            let outcome = await model.connect(ability, from: .abilitiesScreen)
            refresh()
            if outcome == .couldNotAsk, let sentence = outcome.sentence(for: ability) {
                toasts.show(sentence, symbol: "exclamationmark.circle", tint: .pd.caution)
            }
        }
    }

    // MARK: - Where each source stands

    /// The Kit's state for one row, from the switch and what iOS says.
    ///
    /// The engine's registration is left out on purpose: whether the brain in
    /// use can read the day is the Brain row's sentence, not this one's.
    private func state(of ability: Ability) -> AbilityState {
        switch ability {
        case .calendar, .reminders:
            guard let entity = ability.entity else { return .unsupported }
            return AbilityState.of(
                ability,
                enabled: model.isEnabled(entity),
                grant: AbilityGrant(authorization(for: entity))
            )
        case .health:
            return AbilityState.of(.health, enabled: model.healthToolsEnabled, grant: healthGrant)
        case .localServer:
            return .unsupported
        }
    }

    private func authorization(for entity: PersonalDataEntity) -> PersonalDataAuthorization {
        // The app's reading when it has one, this section's otherwise, and a
        // direct read on the single frame before `.task` has landed.
        model.personalDataAuthorization[entity]
            ?? eventAuthorization[entity]
            ?? EventAccess.authorization(for: entity)
    }

    /// HealthKit's answer, which is never about a read: available means
    /// "iOS will not say", and that is what `AbilityState` turns into On.
    private var healthGrant: AbilityGrant {
        guard HealthAccess.isAvailable else { return .unavailable }
        switch model.healthAvailability {
        case .available: return .neverReported
        case .noHealthData: return .unavailable
        case let .requestFailed(reason): return .failed(reason)
        }
    }

    private func refresh() {
        model.refreshPersonalDataAuthorization()
        for entity in PersonalDataEntity.allCases {
            eventAuthorization[entity] = EventAccess.authorization(for: entity)
        }
    }
}
