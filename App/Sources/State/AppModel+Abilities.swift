import Foundation
import LocalLLMClient
import PocketdKit
import UIKit

/// What the assistant may read: the three switches, what iOS says about each,
/// and what the engine is actually carrying.
@MainActor
extension AppModel {

    // MARK: - The one door

    /// Connects Calendar, Reminders or Health. Every Connect button, switch and
    /// offer in the app comes through here, and nothing else raises an iOS
    /// permission sheet for them.
    ///
    /// In this order, and each step is the reason there is one door:
    ///
    /// 1. The switch goes on. It is the person's own decision and it survives a
    ///    refusal: the row then says the source is off in iOS Settings rather
    ///    than pretending nobody asked, and allowing it there later needs no
    ///    second tap here.
    /// 2. iOS is asked only where it has never answered (`ConnectDoor.step`).
    ///    A refusal opens the Settings app instead, because an app cannot ask
    ///    twice.
    /// 3. The engine is told what it carries, and the day is read again so
    ///    the tiles fill in without another tap.
    ///
    /// Callers announce "connected" only for `.connected`. The five doors this
    /// replaced each decided that for themselves, and one of them toasted
    /// "Calendar connected" while the sheet was still waiting to be raised —
    /// mid-reply, by the tool's own read.
    ///
    /// Two taps while the sheet is up are one trip: the second waits for the
    /// first and gets its answer.
    @discardableResult
    func connect(_ ability: Ability, from source: AbilitySource) async -> ConnectOutcome {
        if let trip = connectTrips[ability] { return await trip.value }
        let trip = Task { await self.walkThroughConnectDoor(ability, from: source) }
        connectTrips[ability] = trip
        let outcome = await trip.value
        connectTrips[ability] = nil
        return outcome
    }

    /// Switches a source off.
    ///
    /// That is all an app can do: there is no API to hand a permission back
    /// to iOS, so the grant stays where it was and Pocketd stops reading.
    func disconnect(_ ability: Ability) {
        guard ability.readsPersonalData, isOn(ability) else { return }
        record(.abilityDisabled(ability: ability.rawValue))
        setSwitch(ability, on: false)
        dayMayHaveChanged()
    }

    private func walkThroughConnectDoor(_ ability: Ability, from source: AbilitySource) async -> ConnectOutcome {
        guard ability.readsPersonalData else { return .unavailable }
        if !isOn(ability) {
            record(.abilityEnabled(ability: ability.rawValue, source: source))
        }
        setSwitch(ability, on: true)

        let outcome: ConnectOutcome
        switch ConnectDoor.step(for: ability, grant: standingGrant(for: ability)) {
        case .alreadyConnected:
            outcome = .connected
        case .askIOS:
            outcome = await askIOS(for: ability)
        case .openSettings:
            openSystemSettings()
            outcome = .openedSettings
        case .blocked:
            outcome = .blocked
        case .unavailable:
            outcome = .unavailable
        }
        // After the answer, so what the engine carries and what the tiles show
        // are both read from it rather than from the moment before the sheet.
        await applyPersonalDataTools()
        dayMayHaveChanged()
        return outcome
    }

    /// Where iOS stands on one source, read now and without asking.
    func standingGrant(for ability: Ability) -> AbilityGrant {
        switch ability {
        case .calendar, .reminders:
            guard let entity = ability.entity else { return .unavailable }
            return AbilityGrant(EventAccess.authorization(for: entity))
        case .health:
            guard HealthAccess.isAvailable else { return .unavailable }
            return switch healthAvailability {
            case .available: .neverReported
            case .noHealthData: .unavailable
            case let .requestFailed(reason): .failed(reason)
            }
        case .localServer:
            return .unavailable
        }
    }

    /// Puts the iOS sheet up. The only call in the app that does, for these
    /// three.
    private func askIOS(for ability: Ability) async -> ConnectOutcome {
        switch ability {
        case .calendar, .reminders:
            guard let entity = ability.entity else { return .unavailable }
            let answer = await EventAccess.shared.requestReadAccess(to: entity)
            personalDataAuthorization[entity] = answer
            return ConnectDoor.outcome(for: ability, after: AbilityGrant(answer))
        case .health:
            switch await HealthAccess.shared.requestAllReadAccess() {
            case .available:
                healthAvailability = .available
                return .connected
            case .noHealthData:
                healthAvailability = .noHealthData
                return .unavailable
            case let .requestFailed(sentence):
                // Already a sentence for a person — `HealthAccess` keeps iOS's
                // error text, which on an unsigned build names an entitlement,
                // out of it — and the event goes to the log.
                DiagnosticLog.record(.failure(area: .healthKit, code: "permission_request_failed"))
                healthAvailability = .requestFailed(sentence)
                return .couldNotAsk
            }
        case .localServer:
            return .unavailable
        }
    }

    private func setSwitch(_ ability: Ability, on: Bool) {
        switch ability {
        case .calendar: calendarToolsEnabled = on
        case .reminders: reminderToolsEnabled = on
        case .health: healthToolsEnabled = on
        case .localServer: break
        }
    }

    /// Pocketd's own page in the Settings app — the only page an app may open.
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }


    /// The switch governing one entity, so that the loops over
    /// `PersonalDataEntity.allCases` do not each carry their own `switch` over
    /// which property holds which. Adding a third entity should break in one
    /// place, not in three.
    func isEnabled(_ entity: PersonalDataEntity) -> Bool {
        switch entity {
        case .calendar: calendarToolsEnabled
        case .reminders: reminderToolsEnabled
        }
    }

    /// The one thing Settings prints under the two switches.
    ///
    /// One sentence and not two, because two deciders can answer this question
    /// and only the last one to run is the reason. See `CapabilityNotice`.
    var capabilityNotice: CapabilityNotice? {
        CapabilityNotice.decide(
            gate: personalDataToolGate,
            plan: capabilityPlan,
            modelName: loadedModelName
        )
    }

    /// The phone's brain's verdict: Apple's model always reads the day and
    /// never drops a capability for space; a download says what its template
    /// and its budget allow.
    func refreshToolGate() async {
        personalDataToolGate = await phoneBrain.toolGate
        capabilityPlan = await phoneBrain.capabilityPlan
    }

    /// What gets registered for a given state of the switches.
    ///
    /// The self-test tool is independent of them: `-pocketd-selftest-tool`
    /// exercises the tool-calling loop on a device without needing EventKit, a
    /// permission prompt or a calendar with anything in it, and it has to keep
    /// working whether or not the real tools are on.
    /// The tools the product registers, each tagged with the capability it
    /// belongs to so the engine's budget can drop a whole capability rather
    /// than an arbitrary tool.
    ///
    /// Priority is the array order, and it is a product judgement: the calendar
    /// answers the question people actually ask most, and health is the largest
    /// schema of the three, so on a window too small for everything health is
    /// the one that goes.
    ///
    /// One parameter per tool rather than one for the pair. The budget has
    /// always dropped these two independently — `CapabilityGroup` has separate
    /// cases for exactly that reason — and it was only the switch above it that
    /// could not express a calendar without reminders.
    static func registrations(
        calendar: Bool,
        reminders: Bool,
        health: Bool
    ) -> [(tool: any LLMTool, group: CapabilityGroup)] {
        var registered: [(tool: any LLMTool, group: CapabilityGroup)] = []
        if calendar {
            registered.append((CalendarTool(), .calendar))
        }
        if reminders {
            registered.append((RemindersTool(), .reminders))
        }
        // Availability-guarded so a device with no Health store never pays
        // schema tokens for a tool that could only ever refuse.
        if health, HealthAccess.isAvailable {
            registered.append((HealthSummaryTool(), .health))
        }
        return registered
    }

    /// Outside the budget on purpose: a diagnostic is not a capability, and
    /// charging it against the ceiling would let the self-test alter the thing
    /// it exists to test.
    static func selfTestTools() -> [any LLMTool] {
        ProcessInfo.processInfo.arguments.contains("-pocketd-selftest-tool") ? [EchoTool()] : []
    }

    /// Tells the engine what it is carrying, from the switches and the
    /// standing iOS answers.
    ///
    /// Never asks iOS anything. This runs from the switches' observers, which
    /// also fire while the brain is being restored at launch, and a request
    /// from here put the Calendar sheet over the first screen of the intro.
    /// Health was the last one still asking from here; it now asks only at
    /// the door, like the other two — see `connect(_:from:)`.
    func applyPersonalDataTools() async {
        let before = personalDataAuthorization
        for entity in PersonalDataEntity.allCases {
            guard isEnabled(entity) else {
                // Dropped, not kept. These entries are what Settings turns into
                // "Pocketd cannot read your calendar" warnings, and with two
                // switches one of them can go off while the screen stays up:
                // leaving the last answer behind means complaining about a
                // permission for a capability the user has just switched off.
                personalDataAuthorization[entity] = nil
                continue
            }
            personalDataAuthorization[entity] = EventAccess.authorization(for: entity)
        }
        // Not a reload. The engine records the new set and rebuilds its client
        // on the next request that needs one, so a user who flips the switch
        // and puts the phone down pays nothing at all. Both brains are told:
        // the download serves other devices and stands in when Apple's model
        // declines, whichever one the phone is talking to.
        await phoneBrain.updateAbilities(
            calendar: calendarToolsEnabled,
            reminders: reminderToolsEnabled,
            health: healthToolsEnabled,
            registrations: Self.registrations(
                calendar: calendarToolsEnabled,
                reminders: reminderToolsEnabled,
                health: healthToolsEnabled
            ),
            exempt: Self.selfTestTools()
        )
        // The switch is what changed what the budget was asked to carry, so it
        // is also the moment the answer changes. Without this the refusal only
        // appeared after the next model load, which is to say on the screen the
        // user was already looking at, several minutes late.
        await refreshToolGate()
        // A switch changes what Today may read. The brief's own refresh folds
        // this into the one already running rather than reading twice.
        if personalDataAuthorization != before { dayMayHaveChanged() }
    }

    /// Re-reads what iOS thinks, without prompting.
    ///
    /// Settings calls this on appear, and the app on every return to the
    /// foreground: the one way a granted permission becomes a denied one is
    /// the user leaving for iOS Settings and coming back, and nothing about
    /// that trip tells this process anything.
    func refreshPersonalDataAuthorization() {
        // The gate is re-read whether or not either switch is on: it is what
        // the row shows to explain an inert switch, and the trip to iOS
        // Settings is not the only thing that can have happened while this
        // screen was away.
        Task { await refreshToolGate() }
        // A device with no Health store at all is a fact about the device, not
        // an answer iOS gave: it is true at launch, before anything has asked
        // for anything, and a switch left on from a previous install would
        // otherwise sit here explaining nothing until the user toggled it. Only
        // ever set in the direction the read supports — `.available` here would
        // overwrite a `.requestFailed` reason with a shrug.
        if healthToolsEnabled, !HealthAccess.isAvailable {
            healthAvailability = .noHealthData
        }
        // Every entity, switched on or not: the rows that list abilities whether
        // they are on or not have to say whether turning one on will work or
        // will need a trip to iOS Settings first, and they cannot from an
        // absent entry.
        let before = personalDataAuthorization
        for entity in PersonalDataEntity.allCases {
            personalDataAuthorization[entity] = EventAccess.authorization(for: entity)
        }
        // A permission changed while the app was away: the tiles were read
        // under the old answer.
        if Self.readableEntities(before) != Self.readableEntities(personalDataAuthorization) {
            dayMayHaveChanged()
        }
    }

    private static func readableEntities(
        _ answers: [PersonalDataEntity: PersonalDataAuthorization]
    ) -> Set<PersonalDataEntity> {
        Set(answers.filter { $0.value.canRead }.map(\.key))
    }

    /// Asks iOS for an entity without touching the switch.
    ///
    /// Superseded by `connect(_:from:)`, which every screen now uses; kept only
    /// so a view that has not moved yet still compiles.
    func requestAccess(to entity: PersonalDataEntity) async {
        personalDataAuthorization[entity] = await EventAccess.shared.requestReadAccess(to: entity)
        await refreshToolGate()
        dayMayHaveChanged()
    }
}
