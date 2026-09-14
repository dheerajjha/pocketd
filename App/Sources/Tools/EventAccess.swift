import EventKit
import Foundation
import PocketdKit

// The value types this file used to declare — `CalendarEventRow`, `ReminderRow`
// and `PersonalDataLookup` — now live in PocketdKit beside the code that turns
// them into what the model reads. Nothing about them needed EventKit, and on
// this side of the seam they could not be tested without a device.

// MARK: - The store

/// The single owner of this app's `EKEventStore`.
///
/// An actor rather than a `@MainActor` type because both reads block: EventKit
/// hits a SQLite database and, on the first call after launch, waits on the
/// calendar daemon. Doing that on the main actor drops frames in the Chat view
/// the tool call was made from.
///
/// One store, not one per call. `EKEventStore` is expensive to create, and the
/// iOS 17 permission APIs are instance methods whose result the *same* instance
/// has to observe — a store created after the grant sees a stale authorization
/// until it is reset.
actor EventAccess {
    static let shared = EventAccess()

    private let store = EKEventStore()

    /// Re-exported so a caller here reads one name for one number: the row cap
    /// and the sentence that announces truncation have to agree, and the
    /// sentence is written where the rows are rendered.
    static let rowLimit = PersonalDataTools.rowLimit

    // MARK: - Permission

    /// EventKit's own status, one entity at a time.
    ///
    /// Separately, and never as a single "personal data" flag: since iOS 17 the
    /// two are independent grants with different prompts, and a user who allows
    /// their calendar routinely refuses their reminders. Collapsing them makes
    /// the reminders tool report a calendar problem.
    ///
    /// `nonisolated` because `authorizationStatus(for:)` is a type method that
    /// reads the process's TCC cache — no instance, no blocking — so a view can
    /// call it to decide whether to show a "grant access" row.
    nonisolated static var eventsStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    nonisolated static var remindersStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    /// The same thing in the app's own vocabulary, which is what the tools and
    /// the tests speak.
    nonisolated static func authorization(for entity: PersonalDataEntity) -> PersonalDataAuthorization {
        switch entity {
        case .calendar: translate(eventsStatus)
        case .reminders: translate(remindersStatus)
        }
    }

    /// Maps EventKit's status onto the app's own vocabulary.
    ///
    /// `.fullAccess` and the deprecated `.authorized` are the same raw value,
    /// so only one of them can appear in this switch; `.authorized` is the
    /// pre-iOS-17 spelling and matching `.fullAccess` covers both. `@unknown
    /// default` fails closed: a status a future iOS invents is not a grant.
    private nonisolated static func translate(_ status: EKAuthorizationStatus) -> PersonalDataAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    /// Asks for read access if it has never been asked, and reports where
    /// things stand either way.
    ///
    /// Uses the iOS 17 API — `requestFullAccessToEvents()` /
    /// `requestFullAccessToReminders()`. The deprecated `requestAccess(to:)`
    /// is not a naming change: on iOS 17 it resolves to *write-only* for
    /// events, which is invisible until a read silently returns an empty
    /// calendar. Reading needs full access and nothing else will do.
    ///
    /// The returned `Bool` is deliberately discarded in favour of re-reading
    /// the status, because `false` conflates "denied" with "granted add-only",
    /// and those are two different sentences to the user.
    func requestReadAccess(to entity: PersonalDataEntity) async -> PersonalDataAuthorization {
        let current = Self.authorization(for: entity)
        switch current {
        case .granted, .denied, .restricted:
            // iOS shows its prompt once. Asking again from here would return
            // instantly with the same answer and only add latency.
            return current
        case .notDetermined, .writeOnly:
            // `.writeOnly` is worth one attempt: the user has never been asked
            // for full access, so the system may still offer the upgrade
            // prompt. If it has been asked, this returns without any UI.
            break
        }

        do {
            switch entity {
            case .calendar: _ = try await store.requestFullAccessToEvents()
            case .reminders: _ = try await store.requestFullAccessToReminders()
            }
        } catch {
            DiagnosticLog.record(.failure(area: .eventKit, code: "permission_request_failed"))
            // A throw here means the request could not be put to the user at
            // all — no prompt, no decision. Whatever the status says now is
            // still the truth, and it is not this function's job to turn a
            // permission question into a dead generation.
        }
        // After the prompt rather than before it, because the interesting value
        // is what the user just decided. Only on the path that actually asked:
        // the early return above is a settled answer being re-read, and logging
        // that would put a line in for every tool call.
        let settled = Self.authorization(for: entity)
        DiagnosticLog.record(.permission(entity: entity.noun, status: String(describing: settled)))
        return settled
    }

    // MARK: - Reads

    /// Events overlapping `interval`, oldest first, capped.
    func events(in interval: DateInterval, limit: Int = EventAccess.rowLimit) async -> PersonalDataLookup<CalendarEventRow> {
        let authorization = await requestReadAccess(to: .calendar)
        guard authorization.canRead else { return .unauthorized(authorization) }

        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: nil // every calendar the user has, which is what they mean by "my calendar"
        )

        let matches = store.events(matching: predicate)
            .compactMap { event -> CalendarEventRow? in
                guard let start = event.startDate else { return nil }
                // EventKit's predicate is inclusive at both ends, so a 09:00
                // event tomorrow comes back in today's query when today closes
                // at tomorrow's midnight. An event that genuinely spans the
                // boundary started earlier and survives this test.
                guard start < interval.end else { return nil }
                let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
                return CalendarEventRow(
                    title: Self.displayTitle(event.title),
                    start: start,
                    end: event.endDate ?? start,
                    location: (location?.isEmpty ?? true) ? nil : location,
                    isAllDay: event.isAllDay
                )
            }
            // Not sorted by EventKit. An unsorted list read out loud is a list
            // of the wrong day's meetings in the wrong order.
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }

        return .rows(Array(matches.prefix(limit)), truncated: matches.count > limit)
    }

    /// Incomplete reminders whose due date falls in `window`, soonest first.
    ///
    /// `window` with both ends `nil` is the only shape that also returns
    /// reminders with no due date — which for most people is most of them.
    func reminders(in window: DateWindow, limit: Int = EventAccess.rowLimit) async -> PersonalDataLookup<ReminderRow> {
        let authorization = await requestReadAccess(to: .reminders)
        guard authorization.canRead else { return .unauthorized(authorization) }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: window.start,
            ending: window.end,
            calendars: nil
        )

        let matches = await fetchRows(matching: predicate)
            // Undated last: they are open forever and would otherwise crowd out
            // the ones with a deadline under the row cap.
            .sorted { left, right in
                switch (left.due, right.due) {
                case let (l?, r?): (l, left.title) < (r, right.title)
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): left.title < right.title
                }
            }

        return .rows(Array(matches.prefix(limit)), truncated: matches.count > limit)
    }

    /// Bridges EventKit's one remaining callback-only fetch.
    ///
    /// `fetchReminders(matching:completion:)` returns a cancellation token, so
    /// the Swift importer generates no `async` overload for it — a continuation
    /// is the only way across. The mapping to value rows happens *inside* the
    /// callback, on whatever queue EventKit chose, precisely so that no
    /// `EKReminder` is ever captured by the continuation and carried onto this
    /// actor.
    private func fetchRows(matching predicate: NSPredicate) async -> [ReminderRow] {
        let calendar = Calendar.current
        return await withCheckedContinuation { (continuation: CheckedContinuation<[ReminderRow], Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map { reminder in
                    let components = reminder.dueDateComponents
                    return ReminderRow(
                        title: Self.displayTitle(reminder.title),
                        due: components.flatMap { calendar.date(from: $0) },
                        // A date-only reminder has no hour. Formatting it with
                        // one would invent a deadline the user never set.
                        dueHasTime: components?.hour != nil,
                        priority: reminder.priority,
                        // Read inside the callback with everything else, so no
                        // `EKReminder` escapes onto the actor.
                        identifier: reminder.calendarItemIdentifier,
                        repeats: Self.pattern(of: reminder.recurrenceRules?.first)
                    )
                })
            }
        }
    }

    // MARK: - Recurrence

    /// The app's vocabulary as an EventKit rule.
    ///
    /// `end: nil` throughout — a repeating reminder somebody asked for by voice
    /// has no end date in the request, and inventing one would stop the thing
    /// silently on a day nobody chose.
    private nonisolated static func rule(for repeats: ReminderRepeat) -> EKRecurrenceRule {
        switch repeats {
        case .daily:
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekly:
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .monthly:
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly:
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        case .weekdays:
            // Weekly with five days named, which is how iCalendar spells
            // "every weekday" and therefore how the Reminders app will show it.
            return EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: 1,
                daysOfTheWeek: [.monday, .tuesday, .wednesday, .thursday, .friday]
                    .map { EKRecurrenceDayOfWeek($0) },
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )
        }
    }

    /// The same mapping backwards, for the duplicate check.
    ///
    /// Deliberately lossy and deliberately conservative: a rule this app did
    /// not write — one the user built in the Reminders app, with an interval of
    /// three or an end date — comes back as `nil` rather than as the nearest
    /// case. Reporting "every three weeks" as `weekly` would let the duplicate
    /// check match it against a weekly reminder and silently decline to file
    /// the one that was asked for.
    private nonisolated static func pattern(of rule: EKRecurrenceRule?) -> ReminderRepeat? {
        guard let rule, rule.interval == 1, rule.recurrenceEnd == nil else { return nil }
        switch rule.frequency {
        case .daily:
            return rule.daysOfTheWeek == nil ? .daily : nil
        case .weekly:
            guard let days = rule.daysOfTheWeek else { return .weekly }
            let named = Set(days.map(\.dayOfTheWeek))
            let workingWeek: Set<EKWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
            if named == workingWeek { return .weekdays }
            return days.count == 1 ? .weekly : nil
        case .monthly:
            return .monthly
        case .yearly:
            return .yearly
        @unknown default:
            return nil
        }
    }

    // MARK: - Writes

    /// Files a new reminder.
    ///
    /// Requires full access rather than `canWrite`, and the reason is the
    /// caller's rather than EventKit's: `PersonalDataWrites.createReminder`
    /// reads the open reminders first to avoid filing the same thing twice, so
    /// a write-only grant would produce a duplicate check that silently saw
    /// nothing and a list that slowly filled with copies.
    func createReminder(_ new: NewReminder) async -> WriteResult {
        let authorization = await requestReadAccess(to: .reminders)
        guard authorization.canRead else { return .unauthorised(authorization) }

        guard let list = store.defaultCalendarForNewReminders() else {
            // Real, and not an error state anyone causes deliberately: a phone
            // whose Reminders lists are all iCloud-disabled has nowhere to put
            // one. Reported rather than crashed on.
            DiagnosticLog.record(.failure(area: .eventKit, code: "no_default_reminder_list"))
            return .failed
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = new.title
        reminder.calendar = list
        if let due = new.due {
            // Date-only stays date-only. Adding hour and minute to a reminder
            // the user gave a day for turns "sometime Friday" into an alarm at
            // midnight.
            let fields: Set<Calendar.Component> = new.dueHasTime
                ? [.year, .month, .day, .hour, .minute]
                : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due)
        }
        if let repeats = new.repeats {
            // Only ever alongside a due date. `PersonalDataWrites` guarantees
            // that pairing — a pattern with nothing to repeat from is refused
            // before it gets here — and EventKit would otherwise hold a rule
            // that never fires.
            reminder.recurrenceRules = [Self.rule(for: repeats)]
        }

        do {
            try store.save(reminder, commit: true)
            return .written
        } catch {
            DiagnosticLog.record(.failure(area: .eventKit, code: "reminder_save_failed"))
            return .failed
        }
    }

    /// Ticks one off, by identifier.
    ///
    /// By identifier and not by title, so that the reminder completed is the
    /// one the caller looked at. Re-running a title search here would leave a
    /// window in which a second matching reminder appeared and got ticked off
    /// instead — rare, and the kind of wrong nobody discovers until they need
    /// the thing they thought was still outstanding.
    func completeReminder(identifier: String) async -> WriteResult {
        let authorization = await requestReadAccess(to: .reminders)
        guard authorization.canRead else { return .unauthorised(authorization) }

        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return .failed
        }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
            return .written
        } catch {
            DiagnosticLog.record(.failure(area: .eventKit, code: "reminder_complete_failed"))
            return .failed
        }
    }

    /// Adds an event.
    ///
    /// `canWrite` rather than `canRead`, because an add genuinely works under
    /// the iOS 17 write-only grant and refusing it would turn a permission the
    /// user deliberately gave into a dead feature.
    func createEvent(_ new: NewEvent) async -> WriteResult {
        let authorization = await requestReadAccess(to: .calendar)
        guard authorization.canWrite else { return .unauthorised(authorization) }

        guard let calendar = store.defaultCalendarForNewEvents else {
            DiagnosticLog.record(.failure(area: .eventKit, code: "no_default_calendar"))
            return .failed
        }

        let event = EKEvent(eventStore: store)
        event.title = new.title
        event.startDate = new.start
        event.endDate = new.end
        event.calendar = calendar
        if let repeats = new.repeats {
            event.recurrenceRules = [Self.rule(for: repeats)]
        }

        do {
            // `.futureEvents` rather than `.thisEvent`, now that a repeating
            // phrase creates a series instead of being refused. On a brand new
            // event the two are equivalent, but `.thisEvent` on an event
            // carrying a recurrence rule is the spelling that means "detach
            // this one occurrence", which is not what a create means.
            try store.save(event, span: .futureEvents, commit: true)
            return .written
        } catch {
            DiagnosticLog.record(.failure(area: .eventKit, code: "event_save_failed"))
            return .failed
        }
    }

    /// `EKCalendarItem.title` is imported as `String!` — it is genuinely nil
    /// for an event created by some CalDAV servers, and an empty row tells the
    /// model nothing.
    private nonisolated static func displayTitle(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(untitled)" : trimmed
    }
}
