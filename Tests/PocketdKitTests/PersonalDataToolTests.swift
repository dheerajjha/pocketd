import Foundation
import Testing
@testable import PocketdKit

/// Records what the store was asked to do, and what it was asked for.
///
/// The interesting assertion in this file is a negative one — that a network
/// caller causes *no* read — and a negative is only worth anything if something
/// records the attempt. A spy that simply returned an empty list would pass a
/// test that checks the output while the calendar was read and thrown away,
/// which is precisely the failure this exists to catch.
private actor ReadSpy<Argument: Sendable, Row: Sendable> {
    private(set) var calls = 0
    private(set) var lastArgument: Argument?
    private let result: PersonalDataLookup<Row>

    init(returning result: PersonalDataLookup<Row>) {
        self.result = result
    }

    func read(_ argument: Argument) -> PersonalDataLookup<Row> {
        calls += 1
        lastArgument = argument
        return result
    }
}

private typealias CalendarSpy = ReadSpy<DateInterval, CalendarEventRow>
private typealias ReminderSpy = ReadSpy<DateWindow, ReminderRow>

/// Fixed so that nothing here depends on the day the suite is run.
private let noon = Date(timeIntervalSince1970: 1_788_955_200)

@Suite("Personal data tools: who may ask")
struct PersonalDataToolOriginTests {

    @Test("a network caller cannot read the calendar, and cannot cause it to be read")
    func networkOriginIsRefusedBeforeTheStoreIsTouched() async {
        let spy = CalendarSpy(returning: .rows(
            [CalendarEventRow(title: "Board meeting", start: noon, end: noon)],
            truncated: false
        ))

        let payload = await PersonalDataTools.calendarPayload(
            range: .today,
            now: noon,
            origin: .network(host: "192.168.1.42", port: 55_000),
            read: { await spy.read($0) }
        )

        // Two properties, and the second is the one that matters. The first says
        // the caller learns nothing; the second says the phone did not look. A
        // tool that read the calendar and then declined to report it would still
        // have woken EventKit, still have raised the permission prompt, and
        // still have put the user's schedule in this process's memory at the
        // request of a stranger on the LAN.
        #expect(payload["text"] as? String == ToolContext.refusal)
        #expect(payload["events"] == nil)
        #expect(await spy.calls == 0)
    }

    @Test("nor the reminders")
    func networkOriginIsRefusedForReminders() async {
        let spy = ReminderSpy(returning: .rows([ReminderRow(title: "Renew passport")], truncated: false))

        let payload = await PersonalDataTools.reminderPayload(
            filter: .all_open,
            now: noon,
            origin: .network(host: "192.168.1.42", port: 55_000),
            read: { await spy.read($0) }
        )

        #expect(payload["text"] as? String == ToolContext.refusal)
        #expect(payload["reminders"] == nil)
        #expect(await spy.calls == 0)
    }

    @Test("loopback is refused exactly like anything else on the wire")
    func loopbackIsNotPrivileged() async {
        // The /chat page the phone serves reaches the engine over a socket, so
        // it arrives here as 127.0.0.1. Privileging that address would hand the
        // user's calendar to every process on the phone, and to anything that
        // can talk a browser into a request.
        for host in ["127.0.0.1", "::1", "localhost"] {
            let spy = CalendarSpy(returning: .rows([], truncated: false))
            let payload = await PersonalDataTools.calendarPayload(
                range: .today, now: noon, origin: .network(host: host, port: 11_434),
                read: { await spy.read($0) }
            )
            #expect(payload["text"] as? String == ToolContext.refusal, "host \(host)")
            #expect(await spy.calls == 0, "host \(host)")
        }
    }

    @Test("the refusal is the only thing a network caller gets back")
    func refusalCarriesNoOtherKeys() async {
        let payload = await PersonalDataTools.calendarPayload(
            range: .this_week, now: noon, origin: .network(host: "10.0.0.9", port: 1),
            read: { _ in .rows([CalendarEventRow(title: "Secret", start: noon, end: noon)], truncated: true) }
        )
        // Not even the truncation note: "there are more" is itself a fact about
        // the user's week.
        #expect(payload.keys.sorted() == ["text"])
    }

    @Test("an unset origin is refused, because the default is the untrusted one")
    func defaultOriginFailsClosed() async {
        // `ToolContext.origin` outside any binding is a network caller. A tool
        // reached by some future path that forgets to bind it must read nothing
        // rather than everything.
        let spy = CalendarSpy(returning: .rows([], truncated: false))
        let payload = await PersonalDataTools.calendarPayload(
            range: .today, now: noon, read: { await spy.read($0) }
        )
        #expect(payload["text"] as? String == ToolContext.refusal)
        #expect(await spy.calls == 0)
    }

    @Test("the origin is taken from the task local the engine binds")
    func readsTheBoundTaskLocal() async {
        // The engine binds `ToolContext.origin` around the whole generation and
        // the tool body reads it back through this default argument, several
        // awaits and one library AsyncStream later. If that channel ever stops
        // working the tools fail closed — but they also stop working for the
        // phone's owner, so both directions are asserted.
        let allowed = await ToolContext.$origin.withValue(.onDeviceChat) {
            await PersonalDataTools.calendarPayload(
                range: .today, now: noon, read: { _ in .rows([], truncated: false) }
            )
        }
        #expect(allowed["text"] as? String == CalendarRange.today.emptyText)

        let refused = await ToolContext.$origin.withValue(.network(host: "h", port: 2)) {
            await PersonalDataTools.calendarPayload(
                range: .today, now: noon, read: { _ in .rows([], truncated: false) }
            )
        }
        #expect(refused["text"] as? String == ToolContext.refusal)
    }

    @Test("the phone's own chat does reach the store")
    func onDeviceChatIsAllowed() async {
        // The mirror of the refusal tests: a gate that refused everybody would
        // pass every single one of them.
        let spy = CalendarSpy(returning: .rows([], truncated: false))
        _ = await PersonalDataTools.calendarPayload(
            range: .today, now: noon, origin: .onDeviceChat, read: { await spy.read($0) }
        )
        #expect(await spy.calls == 1)
    }
}

@Suite("Personal data tools: when permission is missing")
struct PersonalDataToolAuthorizationTests {

    @Test("a refused permission comes back as text, not as a thrown error")
    func deniedIsReadableText() async {
        // A throw from a tool body propagates out of the executor and kills the
        // generation: the user watches the stream stop mid-sentence and is told
        // nothing at all. These functions cannot throw, and this is the case
        // that most wants them to.
        for authorization in [PersonalDataAuthorization.denied, .restricted, .notDetermined, .writeOnly] {
            let payload = await PersonalDataTools.calendarPayload(
                range: .today, now: noon, origin: .onDeviceChat,
                read: { _ in .unauthorized(authorization) }
            )
            #expect(payload["text"] as? String == authorization.explanation(for: .calendar), "\(authorization)")
            // Never an empty list beside it: a model handed one invents a day's
            // meetings rather than reporting a permission problem.
            #expect(payload["events"] == nil, "\(authorization)")
        }
    }

    @Test("a denied calendar says calendar, and denied reminders say reminders")
    func eachEntityIsNamedSeparately() async {
        // iOS 17 split these into two grants with two prompts, and a user who
        // allows their calendar routinely refuses their reminders. Reporting one
        // entity's problem under the other's name sends them to a screen where
        // nothing is wrong.
        let calendar = await PersonalDataTools.calendarPayload(
            range: .today, now: noon, origin: .onDeviceChat, read: { _ in .unauthorized(.denied) }
        )["text"] as? String
        let reminders = await PersonalDataTools.reminderPayload(
            filter: .overdue, now: noon, origin: .onDeviceChat, read: { _ in .unauthorized(.denied) }
        )["text"] as? String

        #expect(calendar?.contains("Calendars") == true)
        #expect(reminders?.contains("Reminders") == true)
        #expect(calendar != reminders)
    }

    @Test("the denial names the screen that actually has the switch")
    func denialIsActionable() async {
        let text = await PersonalDataTools.reminderPayload(
            filter: .today, now: noon, origin: .onDeviceChat, read: { _ in .unauthorized(.denied) }
        )["text"] as? String
        // The model repeats this to the user more or less verbatim, so it has to
        // be a whole instruction. "Permission denied" on its own sends people to
        // the app's own page, which is not where the toggle is.
        #expect(text?.contains("Settings > Privacy & Security > Reminders > Pocketd") == true)
    }

    @Test("a permission failure is never confusable with an empty day")
    func emptyIsNotDenied() async {
        let empty = await PersonalDataTools.calendarPayload(
            range: .today, now: noon, origin: .onDeviceChat, read: { _ in .rows([], truncated: false) }
        )["text"] as? String
        let denied = await PersonalDataTools.calendarPayload(
            range: .today, now: noon, origin: .onDeviceChat, read: { _ in .unauthorized(.denied) }
        )["text"] as? String

        #expect(empty == "No events today.")
        #expect(denied != empty)
    }

    @Test("write-only access is reported as the trap it is, not as a grant")
    func writeOnlyIsNotARead() async {
        // A user who taps "Add Only Access" on the iOS 17 prompt lands here: the
        // app can file new events and read none. Anything that only checks for
        // "not denied" reports this as working.
        #expect(PersonalDataAuthorization.writeOnly.canRead == false)
        let text = await PersonalDataTools.calendarPayload(
            range: .today, now: noon, origin: .onDeviceChat, read: { _ in .unauthorized(.writeOnly) }
        )["text"] as? String
        #expect(text?.contains("Full Access") == true)
    }
}

@Suite("Personal data tools: what the model reads")
struct PersonalDataToolPayloadTests {

    @Test("every value survives JSONSerialization")
    func payloadIsSerialisable() async {
        // `ToolOutput` is handed straight to `JSONSerialization`, which throws on
        // a `Date`. LocalLLMClient swallows that throw and interpolates the
        // dictionary instead — so a `Date` that slips through is not a crash, it
        // is the model quietly reading `2025-09-11 13:00:00 +0000` in UTC and
        // telling the user their 2pm meeting is at one o'clock.
        let payload = await PersonalDataTools.calendarPayload(
            range: .today, now: noon, origin: .onDeviceChat,
            read: { _ in .rows([
                CalendarEventRow(title: "Standup", start: noon, end: noon.addingTimeInterval(900), location: "Zoom"),
                CalendarEventRow(title: "Holiday", start: noon, end: noon, isAllDay: true)
            ], truncated: false) }
        )
        #expect(JSONSerialization.isValidJSONObject(payload))
        #expect(ToolResult.encode(payload).hasPrefix("{"), "a non-JSON payload falls back to key: value text")
    }

    @Test("an all-day event is not given a clock time")
    func allDayEventsPrintAsDays() async {
        let payload = await PersonalDataTools.calendarPayload(
            range: .today, now: noon, origin: .onDeviceChat,
            read: { _ in .rows([CalendarEventRow(title: "Holiday", start: noon, end: noon, isAllDay: true)], truncated: false) }
        )
        let rendered = ToolResult.encode(payload)
        // EventKit stores an all-day event as midnight to 23:59:59, and printing
        // that invents a schedule the user never set.
        #expect(rendered.contains(PersonalDataFormat.day(noon)))
        #expect(rendered.contains("\"all_day\":true"))
    }

    @Test("truncation is announced rather than silently dropping rows")
    func truncationIsReported() async {
        let payload = await PersonalDataTools.calendarPayload(
            range: .this_week, now: noon, origin: .onDeviceChat,
            read: { _ in .rows([CalendarEventRow(title: "One", start: noon, end: noon)], truncated: true) }
        )
        let note = payload["note"] as? String
        #expect(note?.contains("\(PersonalDataTools.rowLimit)") == true)
        #expect(note?.contains("there are more") == true)
    }

    @Test("the priority scale is explained once, and only when it is used")
    func priorityScaleAppearsWithPriorities() async {
        // EventKit's scale is RFC 5545's — 1 highest, 9 lowest — which is
        // backwards from everything a model has read about "priority 9". Left
        // unsaid, the list comes back ranked upside down.
        let withPriority = await PersonalDataTools.reminderPayload(
            filter: .all_open, now: noon, origin: .onDeviceChat,
            read: { _ in .rows([ReminderRow(title: "Taxes", priority: 1)], truncated: false) }
        )
        #expect(withPriority["priority_scale"] as? String == "1 is highest, 9 is lowest")

        let without = await PersonalDataTools.reminderPayload(
            filter: .all_open, now: noon, origin: .onDeviceChat,
            read: { _ in .rows([ReminderRow(title: "Milk")], truncated: false) }
        )
        // One copy for a list that has no priorities costs the user tokens for
        // nothing.
        #expect(without["priority_scale"] == nil)
    }

    @Test("a reminder with no due date says so instead of carrying a null")
    func undatedRemindersReadPlainly() async {
        let payload = await PersonalDataTools.reminderPayload(
            filter: .all_open, now: noon, origin: .onDeviceChat,
            read: { _ in .rows([ReminderRow(title: "Someday")], truncated: false) }
        )
        // `JSONSerialization` throws on `nil`, and a missing key invites the
        // model to guess a deadline.
        #expect(JSONSerialization.isValidJSONObject(payload))
        #expect(ToolResult.encode(payload).contains("no due date"))
    }

    @Test("a priority of zero is absence, not urgency")
    func zeroPriorityIsOmitted() async {
        let payload = await PersonalDataTools.reminderPayload(
            filter: .all_open, now: noon, origin: .onDeviceChat,
            read: { _ in .rows([ReminderRow(title: "Milk", priority: 0)], truncated: false) }
        )
        // Zero is EventKit's "the user set none". Reported as a priority it
        // ranks a shopping list above a deadline.
        #expect(!ToolResult.encode(payload).contains("priority"))
    }

    @Test("the window handed to the store is the one the range names")
    func rangeReachesTheStore() async {
        // The whole reason the argument is four names rather than two dates: the
        // arithmetic happens here, where a calendar and a time zone are
        // available, and the model cannot get it wrong.
        let spy = CalendarSpy(returning: .rows([], truncated: false))
        _ = await PersonalDataTools.calendarPayload(
            range: .tomorrow, now: noon, origin: .onDeviceChat, read: { await spy.read($0) }
        )
        #expect(await spy.lastArgument == PersonalDataRange.eventWindow(for: .tomorrow, now: noon))
    }

    @Test("a filter reaches the store as the window it names")
    func filterReachesTheStore() async {
        let spy = ReminderSpy(returning: .rows([], truncated: false))
        _ = await PersonalDataTools.reminderPayload(
            filter: .all_open, now: noon, origin: .onDeviceChat, read: { await spy.read($0) }
        )
        // Both ends nil is the only shape that also returns reminders with no
        // due date, which for most people is most of them.
        #expect(await spy.lastArgument?.isUnbounded == true)
    }
}
