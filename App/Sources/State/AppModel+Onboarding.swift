import Foundation
import PocketdKit
import UserNotifications

/// What the five-screen intro reads and does.
///
/// Every decision is `Intro`'s, in the Kit, where it is tested; this file only
/// gathers the inputs from the app's state and calls the one door each action
/// already has — `connect(_:from:)` for a source, `useBuiltInBrain()` /
/// `useDownloadedBrain(id:)` / `download(_:)` for the brain,
/// `setUpMorningBrief(at:weekdaysOnly:)` for the routine. Nothing here keeps a
/// second copy of where anything stands, which is what lets Back and a replayed
/// intro show the phone as it is rather than as somebody last tapped it.
@MainActor
extension AppModel {

    // MARK: - Choosing how Pocketd thinks

    /// The brain screen's plan for this phone, now.
    ///
    /// A download already answering counts as chosen even when nobody chose it
    /// in so many words — one a laptop pulled through the server, or a phone
    /// whose choice predates the key — so a replay says "Ready" for it rather
    /// than offering it as if it were not here. The built-in brain does not get
    /// the same reading: on a first run it is what answers before anybody has
    /// chosen, and the screen exists to let them.
    var introBrainPlan: Intro.BrainPlan {
        var chosen = brainChoice
        if chosen == nil, case .downloaded? = effectiveBrain { chosen = effectiveBrain }
        return Intro.BrainPlan.make(
            chosen: chosen,
            builtIn: IntroOverride.builtIn ?? builtInAvailability,
            installed: installed,
            arriving: transfers.values
                .filter(\.isActive)
                .map(\.record)
                .sorted { $0.displayName < $1.displayName },
            recommendation: IntroOverride.download ?? BrainRecommendation.recommended(for: budget)
        )
    }

    /// Does what Continue on the brain screen means, without holding the intro
    /// up: a download arrives in the background and a downloaded brain loads in
    /// the background, so the caller moves on as soon as this returns.
    func applyIntroBrain(_ action: Intro.BrainPlan.Action) {
        switch action {
        case .nothing:
            return
        case .useBuiltIn:
            Task { await useBuiltInBrain() }
        case let .useDownloaded(id):
            if installed.contains(where: { $0.id == id }) {
                Task { await useDownloadedBrain(id: id) }
            } else {
                // Already on its way: the choice is all there is to record.
                chooseIntroDownload(id)
            }
        case let .download(record):
            chooseIntroDownload(record.id)
            download(record)
        }
    }

    /// Records a download as the phone's brain before it has landed.
    ///
    /// `useDownloadedBrain(id:)` needs the file on the phone, and the intro
    /// starts the download a second before it moves on — so without this the
    /// choice of "Private download" on a phone with Apple Intelligence was
    /// recorded nowhere. Recorded here, `effectiveBrain` stays on Apple's model
    /// until the file arrives (the phone can answer meanwhile) and picks the
    /// download up from then on. Putting it in charge the moment it lands is
    /// asked of `download(_:)` (hand-off to A3).
    func chooseIntroDownload(_ id: String) {
        brainChoice = .downloaded(id: id)
        brainChoice?.save()
    }

    /// The live transfer for a row on the brain screen, for its percentage.
    func introTransfer(for record: ModelRecord) -> ModelTransfer? {
        transfers[record.id]
    }

    // MARK: - Connecting your day

    /// Where Calendar, Reminders or Health stands, read from the switch and
    /// iOS's standing answer each time the screen draws.
    ///
    /// Calendar and Reminders come from `personalDataAuthorization` rather than
    /// a fresh TCC lookup per redraw; the connect screen refreshes it when it
    /// appears, and the connect door and the return from iOS Settings keep it
    /// current after that.
    func introSourceStatus(_ ability: Ability) -> Intro.SourceStatus {
        switch ability {
        case .calendar:
            return .of(.calendar, isOn: calendarToolsEnabled, grant: eventKitGrant(.calendar))
        case .reminders:
            return .of(.reminders, isOn: reminderToolsEnabled, grant: eventKitGrant(.reminders))
        case .health:
            return .of(.health, isOn: healthToolsEnabled, grant: standingGrant(for: .health))
        case .localServer:
            return .unavailable
        }
    }

    private func eventKitGrant(_ entity: PersonalDataEntity) -> AbilityGrant {
        if let known = personalDataAuthorization[entity] { return AbilityGrant(known) }
        return AbilityGrant(EventAccess.authorization(for: entity))
    }

    // MARK: - The morning brief

    /// The morning brief already on this phone, as the time row should start:
    /// its time and whether it skips weekends. A replayed intro shows the
    /// routine somebody has, and Set it up moves that one rather than adding a
    /// second (`setUpMorningBrief`).
    var introExistingMorningBrief: (time: TimeOfDay, weekdaysOnly: Bool, isOn: Bool)? {
        guard let routine = existingRoutine(for: .morningBrief) else { return nil }
        switch routine.recurrence {
        case let .weekly(days, time):
            return (time, days == Weekday.workdays, routine.isEnabled)
        case let .daily(time):
            return (time, false, routine.isEnabled)
        case let .monthly(_, time, _):
            return (time, true, routine.isEnabled)
        case .once:
            return nil
        }
    }

    /// Set it up on the morning screen: iOS's notification question, then the
    /// routine — the one already here moved rather than a second one added.
    ///
    /// The question is put here, at the tap, and answered before this returns,
    /// so the screen that primed it ("Next, tap **Allow**.") is still the one
    /// on show when iOS asks. The save's own ask now runs in the background
    /// (`NotificationCentre.scheduleChanged`), which left the sheet arriving
    /// over "You're all set" with nothing on screen saying what it was for. It
    /// finds the question answered and asks nothing more.
    func setUpIntroMorningBrief(at time: TimeOfDay, weekdaysOnly: Bool) async {
        if await NotificationCentre.shared.authorizationStatus() == .notDetermined {
            await NotificationCentre.shared.requestAuthorization()
        }
        await setUpMorningBrief(at: time, weekdaysOnly: weekdaysOnly)
    }

    // MARK: - The last screen

    /// ✓ Calendar ✓ Reminders – Health ✓ Morning brief 7:30 AM, weekdays.
    var introChecklist: [Intro.ChecklistItem] {
        var brief: (time: String, weekdaysOnly: Bool)?
        if let existing = introExistingMorningBrief, existing.isOn {
            brief = (Format.time(RoutineDraft.date(from: existing.time)), existing.weekdaysOnly)
        }
        return Intro.checklist(
            calendar: introSourceStatus(.calendar).isConnected,
            reminders: introSourceStatus(.reminders).isConnected,
            health: introSourceStatus(.health).isConnected,
            morningBrief: brief
        )
    }

    /// Whether Pocketd can answer yet, as the last screen's one line.
    var introReadiness: Intro.Readiness {
        .of(brainStatus, downloadStopped: introStoppedDownload != nil)
    }

    /// A download for the phone's brain that stopped part-way, so the last
    /// screen can offer Try again — the one place a stopped download would
    /// otherwise go unmentioned until somebody asked a question.
    var introStoppedDownload: ModelRecord? {
        let chosenID: String? = if case let .downloaded(id) = brainChoice { id } else { nil }
        let stopped = transfers.values.filter { transfer in
            switch transfer.state {
            case .paused, .failed: true
            case .waiting, .running, .stopping, .finished: false
            }
        }
        return (stopped.first { $0.id == chosenID } ?? (chosenID == nil ? stopped.first : nil))?.record
    }

    // MARK: - Replay

    /// Whether the intro on screen is a replay from You rather than a first
    /// run. A replay can be closed; a first run cannot — it has no Skip, and
    /// every optional step has its own "Not now".
    var introIsReplay: Bool {
        introFinishedAtLaunch || introFinishedThisLaunch || IntroOverride.skippedIntroAtLaunch
    }

    /// Closes a replayed intro and changes nothing else: whatever its screens
    /// already did — a brain chosen, a source connected, the morning brief set —
    /// stays done, as it would have on Continue.
    func leaveIntroReplay() {
        record(.onboardingCompleted(via: .skipped, destination: .today))
        completeOnboarding()
    }

    /// Leaves the intro: the name, the funnel's last event, the flag.
    ///
    /// The name is written only when it changed, because writing it re-renders
    /// the brief — and an empty field on a replay is somebody clearing it.
    func finishIntro(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != profile.name.trimmingCharacters(in: .whitespacesAndNewlines) {
            profile.name = trimmed
        }
        record(.onboardingCompleted(via: .finished, destination: .today))
        introFinishedThisLaunch = true
        completeOnboarding()
    }
}

// MARK: - Debug overrides

/// Two launch arguments for walking the download path on a simulator, where
/// Apple's model is available and the recommended download is over a
/// gigabyte. Debug builds only; a Release build always reads `nil`.
///
///     -pocketd.introBrain downloadOnly      the brain screen as on a phone with no built-in option
///     -pocketd.introDownload smollm2-360m   offer this catalogue brain instead of the recommendation
enum IntroOverride {
    static var builtIn: BuiltInBrainAvailability? {
        #if DEBUG
        return value(after: "-pocketd.introBrain") == "downloadOnly" ? .notEligible : nil
        #else
        return nil
        #endif
    }

    /// A Debug launch with `-pocketd.skipIntro` (or a seed that sets it) has
    /// been through the intro as far as anything else in the app is concerned,
    /// so replaying it in that launch is a replay.
    static var skippedIntroAtLaunch: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-pocketd.skipIntro")
        #else
        return false
        #endif
    }

    static var download: ModelRecord? {
        #if DEBUG
        return value(after: "-pocketd.introDownload").flatMap { ModelCatalog.model(withID: $0) }
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif
}
