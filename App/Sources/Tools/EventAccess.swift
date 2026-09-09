import EventKit
import Foundation
import PocketdKit

// MARK: - What comes back

/// One event, reduced to values that can leave the actor.
///
/// `EKEvent` is a reference type EventKit owns, mutates behind your back on a
/// store refresh, and does not mark `Sendable`. Handing one to a tool body
/// would be a data race the compiler cannot see through a completion handler,
/// so nothing but this struct crosses the boundary.
struct CalendarEventRow: Sendable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var isAllDay: Bool
}

/// One incomplete reminder, same reasoning.
struct ReminderRow: Sendable, Equatable {
    var title: String
    var due: Date?
    /// A reminder can be due on a *date* with no time of day. Printing 00:00
    /// for those tells the model something the user never said.
    var dueHasTime: Bool
    /// EventKit's scale: 1 highest, 9 lowest, 0 meaning the user set none.
    var priority: Int
}

/// Rows, or the reason there are none. Never an error.
///
/// A thrown error from a tool body propagates out of LocalLLMClient's executor
/// and ends the generation — the user watches the stream stop mid-sentence with
/// nothing to read. Every failure mode here is a value instead.
enum PersonalDataLookup<Row: Sendable>: Sendable {
    case rows([Row], truncated: Bool)
    case unauthorized(PersonalDataAuthorization)
}

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

    /// Cap on rows. Twenty is not arbitrary: a phone-sized model gets roughly
    /// 40–60 tokens per row of JSON, so twenty events is around a thousand
    /// tokens of context that the answer then has to fit alongside.
    static let rowLimit = 20

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
            // A throw here means the request could not be put to the user at
            // all — no prompt, no decision. Whatever the status says now is
            // still the truth, and it is not this function's job to turn a
            // permission question into a dead generation.
        }
        return Self.authorization(for: entity)
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
                        priority: reminder.priority
                    )
                })
            }
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
