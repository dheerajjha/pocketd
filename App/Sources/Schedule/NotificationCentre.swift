import Foundation
import PocketdKit
import UserNotifications

/// Everything this app says to iOS's notification system, and the one thing it
/// hears back.
///
/// A notification is not decoration here, it is the delivery mechanism for half
/// the feature. A prompt task cannot think in the background — Metal refuses a
/// backgrounded app's command buffers on every iPhone — so its *due moment* is
/// kept by a `UNCalendarNotificationTrigger`, which fires at the right second
/// with no app execution of any kind, and the thinking happens when the user
/// taps it. Take the notification away and a prompt task is a row in a list
/// that never does anything.
///
/// Two rules are load-bearing and easy to break by accident:
///
/// - **Nothing is asked for at launch.** This app currently opens without a
///   single permission prompt, which is unusual enough that people comment on
///   it, and it is the first impression of a product whose whole argument is
///   restraint. `requestAuthorization()` is called from the save of the user's
///   *first* task and nowhere else. `reconcile` deliberately does not ask, and
///   returns quietly when it has not been granted.
/// - **No repeating triggers.** See `arm(_:at:calendar:)`.
@MainActor
@Observable
final class NotificationCentre {

    static let shared = NotificationCentre()

    /// The key a notification carries its task under.
    ///
    /// `nonisolated` so the delegate below, which the system calls from wherever
    /// it likes, can read it without an actor hop.
    nonisolated static let taskKey = "pocketd.taskID"

    /// How early a delivered notification may be and still count as this
    /// firing's. Triggers land at the matched instant or a moment after, never
    /// meaningfully before; a minute is slack for the clock, not for a schedule.
    private static let deliveryGrace: TimeInterval = 60

    /// The task a notification tap is asking the app to collect.
    ///
    /// Stored rather than streamed, and that is the whole design of this
    /// property. A tap that launches the app from cold arrives *before* any view
    /// exists to hear it — the delegate is called out of
    /// `didFinishLaunchingWithOptions`, which is why it has to be installed
    /// there — so anything event-shaped is delivered to nobody and the tap does
    /// nothing at all. A value that simply sits here is readable by whatever
    /// appears next, whenever it appears.
    private(set) var requestedTask: UUID?

    /// Held strongly here because `UNUserNotificationCenter.delegate` is a weak
    /// reference. Assigning a freshly constructed delegate and letting it go out
    /// of scope compiles, runs, and silently stops every tap from reaching the
    /// app.
    @ObservationIgnored private let delegate = ScheduleNotificationDelegate()

    private init() {}

    // MARK: - Launch

    /// Installs the delegate. Called from `didFinishLaunchingWithOptions` and
    /// nowhere else: UserNotifications states the requirement in the header —
    /// "The delegate must be set before the application returns from
    /// application:didFinishLaunchingWithOptions:" — and the failure it causes
    /// is the one that matters most. A notification tapped while the app is not
    /// running launches it and delivers the response immediately; a delegate
    /// installed later in the launch sequence misses exactly that case, so
    /// tapping works in testing, where the app is already open, and does nothing
    /// for a user whose phone has been in a pocket since breakfast.
    ///
    /// It asks for nothing. Installing a delegate is not a permission request
    /// and must not become one.
    func attach() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    // MARK: - Permission

    /// Asks to be allowed to notify, at the only moment this app is willing to
    /// ask: the user has just saved a task whose entire purpose is to arrive
    /// later.
    ///
    /// `.alert` and `.sound`, and deliberately not `.badge` — nothing in this
    /// app maintains a badge count, and an app that asks for a permission it
    /// never exercises is asking for trust it does not need.
    ///
    /// `.provisional` was considered and rejected, and it is a closer call than
    /// it looks: provisional authorization needs no prompt at all, which suits
    /// this app's manner, and delivers quietly to Notification Centre. But a
    /// scheduled briefing that never makes a sound is not the thing the user
    /// just asked for — they set a time. Asking once, at the moment the request
    /// makes obvious sense, is the honest version of the same restraint.
    ///
    /// Returns whether the app may notify. A refusal is not an error and must
    /// not block the save: the task still runs, its results are still recorded,
    /// and the screen that shows them still works. It is the caller's job to say
    /// so on screen.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return granted ?? false
    }

    /// Where permission stands, for a screen that needs to explain why a task
    /// will stay quiet.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Arming

    /// Brings the pending notifications into line with the schedule as it now
    /// stands: one armed trigger per enabled task, none for anything else.
    ///
    /// Called after every change to the schedule and after every settle, and
    /// both halves matter. A task that has just run needs its *next* firing
    /// armed, because a non-repeating trigger is spent once it fires; a task
    /// that has just been deleted, disabled or spent needs its pending request
    /// withdrawn, or iOS delivers a notification for something that no longer
    /// exists.
    ///
    /// Deliberately does not request authorization. See the type's note.
    func reconcile(_ tasks: [ScheduledTask], now: Date = Date(), calendar: Calendar = .current) async {
        let centre = UNUserNotificationCenter.current()
        let status = await centre.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        // `dueness(now:)` answers `nil` for a disabled task and for a spent
        // `.once`, so "what should be armed" needs no separate filter — and the
        // date it gives is the first firing strictly after now, which is the one
        // a trigger can still be armed for. A trigger whose components are in
        // the past is accepted by iOS and never delivered.
        var wanted: [String: (task: ScheduledTask, firing: Date)] = [:]
        for task in tasks {
            guard let next = task.dueness(now: now, calendar: calendar).next else { continue }
            wanted[task.id.uuidString] = (task, next)
        }

        // Withdraw anything armed for a task that is no longer asking for it.
        // Filtered to identifiers that parse as a UUID so this only ever clears
        // up after itself: a result banner's identifier carries its firing too
        // (see `resultIdentifier`), and anything a later feature schedules will
        // not be a bare UUID either.
        let pending = await centre.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { UUID(uuidString: $0) != nil && wanted[$0] == nil }
        if !stale.isEmpty {
            centre.removePendingNotificationRequests(withIdentifiers: stale)
        }

        for (_, entry) in wanted {
            await arm(entry.task, at: entry.firing, calendar: calendar)
        }
    }

    /// One non-repeating trigger, identified by the task's UUID.
    ///
    /// **Not `repeats: true`**, and this is the single most tempting wrong turn
    /// in the file. A repeating `UNCalendarNotificationTrigger` would survive
    /// without the app ever running again, which is genuinely attractive — but
    /// it can only repeat a `DateComponents` match, and this app's recurrences
    /// are not that. `.weekly` with three days is three matches, not one;
    /// `.monthly(day: 31, whenShort: .lastDay)` has no components that describe
    /// February; `.once` must not repeat at all. Every one of those would be
    /// *approximately* right, which is the worst outcome for a schedule: nobody
    /// notices for weeks, and by the time they do the app has been arriving at
    /// the wrong time so consistently that they have stopped reading it.
    ///
    /// The price is honest and worth stating: a spent trigger is only replaced
    /// when this app runs again — a granted background refresh, or the user
    /// opening it. If iOS never grants a refresh *and* the app is never opened,
    /// the schedule stops after the armed firing. `FireSequence` is what makes
    /// that recoverable rather than lost: whenever the app does run, every
    /// missed firing collapses into one owed run.
    private func arm(_ task: ScheduledTask, at firing: Date, calendar: Calendar) async {
        let content = UNMutableNotificationContent()
        content.title = bannerTitle(for: task)
        content.body = switch task.body {
        case .watcher:
            "Due now. Tap to see it."
        case .prompt:
            // Says the constraint out loud, in the one place a user meets it.
            "Due now. Tap to run it — Pocketd can only think while it is open."
        }
        content.sound = .default
        // Groups a task's notifications into one thread, so a daily watcher is
        // one expandable stack rather than a week of separate rows.
        content.threadIdentifier = task.id.uuidString
        content.userInfo = [Self.taskKey: task.id.uuidString]

        // Components rather than an instant, because that is all
        // UNCalendarNotificationTrigger accepts — and the conversion is a
        // decision, not a formality:
        //
        // For a recurring rule the components are left *floating*. 09:00 stays
        // 09:00 if the user flies somewhere, which is exactly what `Recurrence`
        // promises: the rule is re-evaluated in the device's calendar, so an
        // instant pinned to the old zone would fire an hour out and disagree
        // with everything the app shows.
        //
        // `.once` is the opposite and carries a timeZone so it stays an
        // absolute instant. "3pm tomorrow" is a promise about a specific moment
        // — `Recurrence` says so where the case is declared — and floating it
        // would move an appointment-shaped reminder across a flight.
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: firing)
        if case .once = task.recurrence {
            components.timeZone = calendar.timeZone
        }

        let request = UNNotificationRequest(
            identifier: task.id.uuidString,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        // Adding a request whose identifier is already pending replaces it,
        // which is what makes this function safe to call on every settle.
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Announcing a run

    /// Announces what a watcher found.
    ///
    /// # What goes in the banner, and why it is less than it could be
    ///
    /// A watcher's rendered report is two parts. `headline` is assembled from a
    /// count, a noun and a fixed phrase — "3 events today", "1 reminder
    /// overdue" — and there is no path by which anybody else's text reaches it.
    /// `lines` is precisely anybody else's text: event titles written by whoever
    /// sent the invite, reminder names, often naming other people.
    ///
    /// **The banner carries the headline. The lines stay in the app.**
    ///
    /// The reasoning, because this is a real cost and the decision should be
    /// re-arguable rather than inherited. A lock screen is a display anyone
    /// holding the phone can read without unlocking it, and iOS gives an app no
    /// say in that: whether previews are hidden until the owner's face unlocks
    /// them is a Settings choice the app can neither read nor set, and its
    /// default differs by device. So the app has to decide for itself what it is
    /// prepared to put there for everyone, and this app's entire promise is that
    /// what it reads about you stays with you. A notification is the one moment
    /// it volunteers that data unprompted, to a screen it does not control.
    ///
    /// What it costs is the glance: "3 events today" tells you whether to care,
    /// and the tap tells you what they are. What it buys is that the app cannot
    /// be the reason a stranger, or a colleague, learns who somebody is meeting.
    /// It is also the recoverable direction — a later release can offer a
    /// per-task "show details in the banner" switch, chosen deliberately by
    /// someone who has understood it. Nothing can un-show a banner that named an
    /// appointment across a meeting-room table.
    ///
    /// The two remaining bodies are safe by construction and go out in full: an
    /// empty result's sentence is a template with nothing in it, and a
    /// permission explanation is about this app, not about the data it could not
    /// read.
    ///
    /// The title is the task's own name, which the user typed themselves. It is
    /// the one piece of text on the banner that belongs to the person holding
    /// the phone, and a notification with no title is unidentifiable.
    func announce(
        _ result: WatcherResult,
        of task: ScheduledTask,
        firing: Date,
        notifyWhenEmpty: Bool
    ) async {
        let body: String
        switch result {
        case .found(let report):
            body = report.headline
        case .nothing(let sentence):
            // A daily watcher that buzzes to say nothing happened is the fastest
            // way to get this app's notifications switched off, which is why the
            // task carries the answer rather than the rule deciding.
            guard notifyWhenEmpty else { return }
            body = sentence
        case .unreadable(let authorization, let entity):
            // Always announced, whatever `notifyWhenEmpty` says. "I could not
            // look" and "there was nothing there" are different facts, and this
            // is the one the user can do something about — the sentence names
            // the Settings path.
            body = authorization.explanation(for: entity)
        }
        let alreadyTold = await armAlreadyFired(for: task, firing: firing)
        await post(body, of: task, firing: firing, alreadyTold: alreadyTold)
    }

    /// Announces a prompt task that came due somewhere it could not be run.
    ///
    /// Usually says nothing at all, and that is the point: the armed trigger has
    /// already fired at exactly the right second and is sitting on the user's
    /// lock screen saying "tap to run it". This exists for the firings the arm
    /// did not cover — a task created between two firings, a phone that was off
    /// when the trigger was due, a run of missed firings collapsed into one.
    func announceAwaitingForeground(_ task: ScheduledTask, firing: Date) async {
        let alreadyTold = await armAlreadyFired(for: task, firing: firing)
        guard !alreadyTold else { return }
        await post("Due now. Tap to run it — Pocketd can only think while it is open.",
                   of: task, firing: firing, alreadyTold: false)
    }

    /// Delivers now, and decides how loudly.
    ///
    /// The failure this is shaped around: the armed trigger fires at 07:00 and
    /// buzzes, iOS grants a background refresh at 07:20, the watcher runs and
    /// posts its answer — and the user is buzzed twice in twenty minutes for one
    /// firing. So a result that follows a notification the user has already had
    /// arrives `.passive`: the row in Notification Centre quietly becomes the
    /// answer instead of the invitation, with no second alert. When there was no
    /// arm — the refresh beat the trigger, or the task was armed after its
    /// firing — this *is* the announcement and it alerts normally.
    private func post(_ body: String, of task: ScheduledTask, firing: Date, alreadyTold: Bool) async {
        let centre = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = bannerTitle(for: task)
        content.body = body
        content.threadIdentifier = task.id.uuidString
        content.userInfo = [Self.taskKey: task.id.uuidString]

        if alreadyTold {
            content.interruptionLevel = .passive
            // The invitation is replaced rather than left underneath it: two
            // rows for one firing, one of them telling the user to tap for
            // something the other one is already showing.
            centre.removeDeliveredNotifications(withIdentifiers: [task.id.uuidString])
        } else {
            content.sound = .default
        }

        // A nil trigger delivers immediately.
        try? await centre.add(UNNotificationRequest(
            identifier: Self.resultIdentifier(task, firing: firing),
            content: content,
            trigger: nil
        ))
    }

    /// Whether the armed notification for this firing has already been
    /// delivered — whether the user has been told.
    ///
    /// The date test is what keeps it about *this* firing: a task's arm is
    /// identified by its bare UUID and is reused every day, so yesterday's
    /// delivered banner is still sitting there under the same identifier.
    private func armAlreadyFired(for task: ScheduledTask, firing: Date) async -> Bool {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.contains {
            $0.request.identifier == task.id.uuidString
                && $0.date >= firing.addingTimeInterval(-Self.deliveryGrace)
        }
    }

    /// A result carries its firing in its identifier, so it never collides with
    /// the pending arm.
    ///
    /// Sharing the bare UUID would put the answer and the next firing's trigger
    /// on one identifier, and re-arming — which happens moments after a settle —
    /// would then be able to take a result away before it has been read.
    private static func resultIdentifier(_ task: ScheduledTask, firing: Date) -> String {
        "\(task.id.uuidString):\(Int(firing.timeIntervalSinceReferenceDate))"
    }

    /// The task's own name, or the app's.
    ///
    /// `ScheduledTaskStore` deliberately accepts a blank title — "a blank title
    /// is a task with a blank title, not a draft" — and a notification with an
    /// empty title renders as a body with nothing above it, attributable to
    /// nothing.
    private func bannerTitle(for task: ScheduledTask) -> String {
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Pocketd" : trimmed
    }

    // MARK: - Taps

    fileprivate func received(tap taskID: UUID) {
        requestedTask = taskID
    }

    /// Takes the outstanding request, if there is one, and clears it.
    ///
    /// Clearing on read rather than on handling is deliberate: a tap that is
    /// picked up twice runs the task twice, and there is no cheap way for the
    /// second reader to know the first one is already working on it.
    func takeRequestedTask() -> UUID? {
        defer { requestedTask = nil }
        return requestedTask
    }
}

// MARK: - The delegate

/// Separate from `NotificationCentre`, and nonisolated, because
/// `UNUserNotificationCenterDelegate` carries no actor annotation of its own: a
/// `@MainActor` method cannot satisfy a nonisolated protocol requirement under
/// complete concurrency checking. Each callback therefore takes what it needs
/// out of the system's objects — none of which are `Sendable` — and hops to the
/// main actor carrying nothing but a UUID.
private final class ScheduleNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// The tap. This is the entire delivery mechanism for a prompt task: the
    /// notification is what arrives on time, and this is what turns it into a
    /// run in a context where a model is actually allowed to load.
    func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // A dismissal is not a request to run anything. `UNNotificationDefault-
        // ActionIdentifier` is the tap; anything else here is a swipe-away or a
        // custom action this app does not register.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let taskID = Self.taskID(of: response)
        else { return }
        await NotificationCentre.shared.received(tap: taskID)
    }

    /// What to do when one of these lands while the app is already open.
    ///
    /// Shown, but silently. The alert sound exists to reach somebody whose phone
    /// is face down on a table; playing it into the ear of somebody who is
    /// looking at the app is just noise. `.list` keeps it in Notification Centre
    /// so a banner missed while scrolling is still recoverable. Without this
    /// method iOS presents nothing at all in the foreground, which would make a
    /// watcher firing while the phone sits in Desk Mode produce no visible sign.
    ///
    /// # The signature is not the one the documentation shows, and has to be
    ///
    /// The idiomatic spelling — `async -> UNNotificationPresentationOptions` —
    /// compiles here and is never called. This target builds with
    /// `SWIFT_OBJC_INTEROP_MODE: objcxx`, which it has no choice about because
    /// llama.cpp's headers are C++, and under C++ interop the importer renders
    /// the completion block's `NS_OPTIONS` parameter as a bare `Int` rather than
    /// as the option set. The witness then does not match the `@objc` optional
    /// requirement, `respondsToSelector:` answers no, and notifications are
    /// silently dropped whenever the app is on screen. The only trace is a
    /// warning — "nearly matches optional requirement" — which is easy to read
    /// as pedantry and is in fact the feature not working.
    ///
    /// So: raw values, checked against the compiler rather than assumed. If that
    /// warning ever reappears on this method, the import has changed again and
    /// the parameter type is what needs to follow it; ask the compiler what the
    /// requirement is rather than guessing.
    func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (Int) -> Void
    ) {
        let options: UNNotificationPresentationOptions = [.banner, .list]
        completionHandler(Int(options.rawValue))
    }

    /// `userInfo` first, and the request identifier only as a fallback. A
    /// result banner's identifier carries its firing as well as the task, so it
    /// does not parse as a UUID; the arm's identifier is a bare UUID and does.
    /// Both carry the task under `taskKey`, so the fallback is belt and braces
    /// for a notification written by an older build.
    private static func taskID(of response: UNNotificationResponse) -> UUID? {
        let request = response.notification.request
        if let raw = request.content.userInfo[NotificationCentre.taskKey] as? String,
           let id = UUID(uuidString: raw) {
            return id
        }
        return UUID(uuidString: request.identifier)
    }
}
