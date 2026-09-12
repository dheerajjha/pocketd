import Foundation

// MARK: - The two independent things

/// Where one ability stands with the rest of the system, as far as this process
/// is able to know.
///
/// Deliberately not `PersonalDataAuthorization` widened. That type is EventKit's
/// five answers restated, and EventKit is the only one of the three subsystems
/// on this screen that answers at all: HealthKit refuses to report a read grant,
/// and a listening socket is an observation rather than a grant. The cases those
/// two need — `neverReported`, `failed` — have no meaning in EventKit's
/// vocabulary and would have had to be faked there.
public enum AbilityGrant: Sendable, Equatable {
    /// iOS has granted the read. For the server, the listener is up: that is an
    /// observation this process made rather than an answer iOS gave, and it is
    /// the strongest fact available, because Local Network authorization is not
    /// reportable either. (It gates Bonjour advertising and outbound discovery,
    /// not the inbound accept, so a bound socket is genuinely serving even when
    /// nothing can find it by name.)
    case granted
    /// The question has never been put to the user, or they dismissed it.
    case notAsked
    /// iOS says no.
    case refused
    /// The iOS 17 calendar trap: "Add Only Access" files new events and reads
    /// nothing. Anything testing for "not denied" reports it as a grant.
    case addOnly
    /// Screen Time or a management profile. Not the same as refused, because
    /// the user cannot change it from the app's own page in iOS Settings.
    case restricted
    /// iOS will not say, ever. Health reads, and nothing else here.
    case neverReported
    /// There is no such subsystem on this device to talk to.
    case unavailable
    /// Being asked or being started, right now.
    case inProgress
    /// It could not be started at all. Carries the reason, because "not
    /// working" without one is unactionable.
    case failed(String)
}

public extension AbilityGrant {
    /// EventKit's answer in this screen's vocabulary.
    ///
    /// One mapping rather than one per call site: the app already translates
    /// `EKAuthorizationStatus` into `PersonalDataAuthorization` in exactly one
    /// place, and a second hand-rolled translation in a view is how `.writeOnly`
    /// gets read as a grant for the second time.
    init(_ authorization: PersonalDataAuthorization) {
        switch authorization {
        case .granted: self = .granted
        case .notDetermined: self = .notAsked
        case .denied: self = .refused
        case .restricted: self = .restricted
        case .writeOnly: self = .addOnly
        }
    }
}

/// Whether the engine is actually carrying this ability's tool.
///
/// The third thing that can leave a switch on and inert, after the user's own
/// switch and iOS. `ToolGate` decides whether the resident model is handed any
/// tool at all and `CapabilityBudget` decides how many of them the context
/// window can carry — and at a 1,024-token window the budget quietly keeps the
/// calendar and drops reminders. A row reading "On. The assistant can read your
/// reminders" over an engine carrying no reminders tool is the exact lie this
/// screen exists to stop telling.
public enum AbilityRegistration: Sendable, Equatable {
    case registered
    /// Nothing to register — the switch is off, or it is the server, which is
    /// not a tool.
    case notApplicable
    /// The gate or the budget refused it. Carries the finished sentence from
    /// whichever of them decided, because `CapabilityNotice` has already ranked
    /// the two and only one of them is the reason.
    case withheld(String)
}

// MARK: - What the row says it is

/// The one state a row is in, from the switch and the grant together.
///
/// Both halves are real and they are independent, so the states nobody models
/// are the ones that go wrong: on-but-not-granted is a switch that reads as
/// working and reads nothing, granted-but-off is a permission iOS is still
/// holding for an app that has stopped using it, and "iOS will not tell us" is
/// most of what is true about Health. Flat cases rather than a pair of booleans
/// plus branching in a `body`, because branching in a `body` cannot be tested
/// and this is precisely where the lying would happen.
public enum AbilityState: Sendable, Equatable {
    /// No such subsystem on this device. Outranks everything: a switch cannot
    /// be meaningfully on or off for hardware that is not here.
    case unsupported
    /// Off, and iOS is holding nothing.
    case off
    /// Off here, and iOS access is still granted. The state with no button for
    /// it: there is no API to hand a permission back, so switching the ability
    /// off deregisters the tool and leaves the grant exactly where it was.
    case offWithGrantStanding
    case offAndRefused
    case offAndAddOnly
    case offAndRestricted
    /// A prompt is on screen, or the server is coming up.
    case pending
    /// On, and working as far as anything here can establish.
    case on
    /// On, and iOS has not answered.
    case onAwaitingGrant
    case onAndRefused
    case onAndAddOnly
    case onAndRestricted
    /// On, and iOS will never confirm it. Health's ordinary state.
    case onButUnconfirmed
    /// On, and the engine is not carrying the tool. Carries the reason.
    case onButWithheld(String)
    /// On, and it could not start. Carries the reason.
    case onButFailed(String)

    /// Whether this state is the ability doing its job. Only `on` is, and
    /// nothing that merely looks like it: `onAwaitingGrant` and
    /// `onButUnconfirmed` both read as "on" in a tab bar and neither is a claim
    /// that a single row of data will come back.
    public var isWorking: Bool { self == .on }

    /// Whether the row should catch the eye. Every state where the switch says
    /// one thing and the system does another, plus the two where iOS simply
    /// will not say — "not reported" is the honest answer and it is also the
    /// one a reader takes for a dodge unless it is given a warning's weight.
    public var needsAttention: Bool {
        switch self {
        case .off, .on, .pending, .unsupported, .offWithGrantStanding:
            false
        case .offAndRefused, .offAndAddOnly, .offAndRestricted,
             .onAwaitingGrant, .onAndRefused, .onAndAddOnly, .onAndRestricted,
             .onButUnconfirmed, .onButWithheld, .onButFailed:
            true
        }
    }
}

public extension AbilityState {
    /// The one state these inputs mean.
    ///
    /// The ranking is the order of the checks and each step is a judgement:
    ///
    /// 1. A device with no such subsystem outranks everything. There is no
    ///    switch position that makes a missing Health store readable.
    /// 2. A prompt that is up outranks the answer it has not given yet.
    /// 3. The user's own switch is next: with it off, what iOS thinks is
    ///    context rather than a problem, and the states below say so without
    ///    complaining at somebody about a capability they declined.
    /// 4. A tool the engine is not carrying outranks the permission for it, for
    ///    the reason Settings already ranks them that way — a model that will
    ///    never call the tool makes the calendar permission beside the point.
    /// 5. Only then does the grant decide.
    ///
    /// - Parameter registration: what the engine did with the switch. Pass
    ///   `.notApplicable` for anything that is not a registered tool.
    static func of(
        _ ability: Ability,
        enabled: Bool,
        grant: AbilityGrant,
        registration: AbilityRegistration = .notApplicable
    ) -> AbilityState {
        let grant = resolved(grant, for: ability)

        if grant == .unavailable { return .unsupported }
        if grant == .inProgress { return .pending }

        guard enabled else {
            switch grant {
            case .granted: return .offWithGrantStanding
            case .refused: return .offAndRefused
            case .addOnly: return .offAndAddOnly
            case .restricted: return .offAndRestricted
            // A grant nobody has asked for, a grant iOS will not report, and a
            // failure from the last time it ran all mean the same thing to
            // somebody who has this switched off: nothing is happening. The
            // stale failure especially — reporting it would be complaining
            // about a capability they have already turned off.
            case .notAsked, .neverReported, .failed: return .off
            case .unavailable, .inProgress: return .off
            }
        }

        if case let .withheld(reason) = registration { return .onButWithheld(reason) }

        switch grant {
        case .granted: return .on
        case .notAsked: return .onAwaitingGrant
        case .refused: return .onAndRefused
        case .addOnly: return .onAndAddOnly
        case .restricted: return .onAndRestricted
        case .neverReported: return .onButUnconfirmed
        case let .failed(reason): return .onButFailed(reason)
        case .unavailable, .inProgress: return .pending
        }
    }

    /// Drops any grant an ability's subsystem is not in a position to report.
    ///
    /// This is the anti-lying rule, and it is enforced here rather than trusted
    /// to every call site because the call sites are where it fails. A caller
    /// that reads `HKHealthStore.authorizationStatus(for:)` gets a real,
    /// confident-looking answer about *write* access and will happily hand it
    /// over as `.granted` — at which point the screen tells the user their
    /// health data is being read when HealthKit has never said any such thing.
    /// Coerced to `.neverReported`, the row says what is actually known.
    ///
    /// `.restricted` is coerced along with the rest, and that is the case worth
    /// naming: it looks like a fact about the device rather than a claim about a
    /// grant, and for EventKit it is one — `EKAuthorizationStatus.restricted` is
    /// reported. HealthKit has no such status to report, so a `.restricted` for
    /// Health could only ever have been inferred, and an inference is exactly
    /// what this screen may not print.
    ///
    /// `.unavailable`, `.inProgress` and `.failed` survive. None of the three is
    /// a claim about a read grant: the first is `isHealthDataAvailable()`, which
    /// HealthKit does answer, and the other two are facts about this process.
    private static func resolved(_ grant: AbilityGrant, for ability: Ability) -> AbilityGrant {
        guard !ability.grantIsReportedByOS else { return grant }
        switch grant {
        case .granted, .notAsked, .refused, .addOnly, .restricted, .neverReported: return .neverReported
        case .unavailable, .inProgress, .failed: return grant
        }
    }
}

// MARK: - The one thing to do about it

/// The single button on a row.
///
/// One, because a row offering two doors is a row the reader has to work out,
/// and the whole complaint about the old Settings section is that working it
/// out was left to them. Where the real lever is in iOS rather than here, the
/// sentence names the corridor and `AbilityPresentation.linksToSystemSettings`
/// puts the front door under it.
public enum AbilityAction: Sendable, Equatable {
    /// Flip this app's switch on. Also the moment iOS gets asked, which is why
    /// it is a button and not a toggle: a switch that asks iOS for your
    /// calendar and then waits for a second tap before meaning anything reads
    /// as broken.
    case turnOn
    /// Flip this app's switch off — which deregisters the tool and does
    /// nothing else. No app can revoke a system permission, and the copy beside
    /// this must not imply otherwise.
    case turnOff
    /// Put the question to iOS again. Only ever offered where iOS has not
    /// answered, because a settled question returns instantly with no UI and a
    /// button that visibly does nothing is worse than no button.
    case askAgain
    /// Leave, because nothing in this app can change it.
    case openSystemSettings
    /// Start it again after a failure.
    case retry
    /// Nothing anybody can do from this row.
    case none

    /// What the button says.
    ///
    /// Per ability, because "Turn on" is wrong for a server and "Start serving"
    /// is wrong for a calendar. `openSystemSettings` is worded exactly as the
    /// Settings screen already words it — one wording for one action, wherever
    /// it surfaces.
    public func label(for ability: Ability) -> String? {
        switch self {
        case .turnOn: ability == .localServer ? "Start serving" : "Turn on"
        case .turnOff: ability == .localServer ? "Stop serving" : "Turn off"
        case .askAgain: "Ask iOS again"
        case .openSystemSettings: "Open iOS Settings"
        case .retry: "Try again"
        case .none: nil
        }
    }
}

public extension AbilityAction {
    /// The one action a state affords.
    ///
    /// Two invariants hold across this table and the tests assert both: `turnOn`
    /// is only ever offered from a state that is off, and `turnOff` only from
    /// one that is on. A row that offers to turn on something already on is the
    /// cheapest possible way to tell a reader the screen is not tracking
    /// reality.
    static func of(_ state: AbilityState) -> AbilityAction {
        switch state {
        case .unsupported: .none
        case .off, .offWithGrantStanding: .turnOn
        case .offAndRefused, .offAndAddOnly: .openSystemSettings
        // Deliberately no door. Screen Time and management profiles are not in
        // this app's page in iOS Settings, and sending somebody to the front
        // door for a lever that is not behind it is the dead end this screen is
        // supposed to replace.
        case .offAndRestricted, .onAndRestricted: .none
        case .pending: .none
        case .on, .onButUnconfirmed: .turnOff
        case .onAwaitingGrant: .askAgain
        case .onAndRefused, .onAndAddOnly: .openSystemSettings
        // The fix is a different model or a wider context window, neither of
        // which is a button on this row. The reason carried by the state names
        // what to change.
        case .onButWithheld: .none
        case .onButFailed: .retry
        }
    }
}
