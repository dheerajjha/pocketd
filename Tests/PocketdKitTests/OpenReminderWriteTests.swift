import Foundation
import Testing
@testable import PocketdKit

@Suite("Reminder writes check the whole store")
struct OpenReminderWriteTests {
    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func others(_ count: Int) -> [ReminderRow] {
        (0..<count).map { ReminderRow(title: "Other \($0)", due: day.addingTimeInterval(Double($0)), identifier: "private-\($0)") }
    }

    private actor Store {
        let all: [ReminderRow]?
        var completed: [String] = []
        var added: [String] = []
        init(_ all: [ReminderRow]?) { self.all = all }
        func fetch(_ query: OpenReminderQuery) -> PersonalDataLookup<ReminderRow> {
            // An unbounded EventKit predicate is the only one that includes
            // undated reminders. This fixture includes those on purpose.
            let window = query.window
            return query.select(from: all?.filter { row in
                guard let due = row.due else { return window.start == nil && window.end == nil }
                return (window.start.map { due >= $0 } ?? true) && (window.end.map { due < $0 } ?? true)
            })
        }
        func tick(_ row: ReminderRow) -> WriteResult { completed.append(row.identifier ?? "missing"); return .written }
        func add(_ row: NewReminder) -> WriteResult { added.append(row.title); return .written }
    }

    private func write(_ verb: ReminderAction, title: String = "Return key", store: Store,
                       query: OpenReminderQuery? = nil) async -> [String: any Sendable] {
        let question = verb == .complete ? "Tick off \(title)" : "Remind me to \(title)"
        let request = GenerationRequest(modelID: "fixture", messages: [.user(question)], origin: .onDeviceChat, submittedQuestion: question)
        let lookup: @Sendable () async -> PersonalDataLookup<ReminderRow> = { await store.fetch(query ?? .writeMatches(title: title)) }
        return await ModelWriteTurn.$current.withValue(request.modelWriteTurn) {
            if verb == .complete {
                return await ModelPersonalDataWrites.completeReminder(title: title, when: nil, origin: .onDeviceChat,
                    existing: lookup, complete: { await store.tick($0) })
            } else {
                return await ModelPersonalDataWrites.createReminder(title: title, when: nil, origin: .onDeviceChat,
                    existing: lookup, write: { await store.add($0) })
            }
        }
    }

    @Test("Rows 20 and 21 have the same title: only one is displayed, neither is completed", arguments: [false, true])
    func duplicateAcrossDisplayBoundary(extraPrivateRow: Bool) async throws {
        let store = Store(others(19) + [
            ReminderRow(title: "Return key", due: day.addingTimeInterval(20), identifier: "on-screen"),
            ReminderRow(title: "Return key", due: day.addingTimeInterval(21), identifier: "off-screen")
        ] + (extraPrivateRow ? [ReminderRow(title: "Hidden personal title", identifier: "hidden-id")] : []))
        let list = await PersonalDataTools.reminderPayload(filter: .all_open, origin: .onDeviceChat) { window in
            await store.fetch(.list(in: window, limit: PersonalDataTools.rowLimit))
        }
        let visible = try #require(list["reminders"] as? [[String: any Sendable]])
        #expect(visible.count == 20 && visible.last?["title"] as? String == "Return key")
        #expect(visible.filter { $0["title"] as? String == "Return key" }.count == 1)
        #expect((list["note"] as? String)?.contains("first 20") == true)
        let result = await write(.complete, store: store)
        #expect((result["text"] as? String)?.contains("2 open reminders match") == true)
        #expect((result["text"] as? String)?.contains("Which one?") == true)
        #expect(!ModelWriteTurn.didWrite(result))
        #expect(await store.completed.isEmpty)
        for text in [ToolResult.encode(list), SystemToolOutput.render(list), ToolResult.encode(result)] {
            #expect(!text.contains("Hidden personal title") && !text.contains("off-screen"))
        }
    }

    @Test("A unique undated match after twenty dated records completes by ID; partial titles and meaningful symbols stay distinct")
    func exactUniqueBeyondCap() async {
        let store = Store(others(20) + [ReminderRow(title: "Return key ring", identifier: "longer"),
            ReminderRow(title: "Return keyboard", identifier: "partial"),
            ReminderRow(title: "RETURN  \t key!", identifier: "the-only-key"),
            ReminderRow(title: "Learn C#", identifier: "c-sharp")])
        let result = await write(.complete, store: store)
        #expect(ModelWriteTurn.didWrite(result))
        #expect(await store.completed == ["the-only-key"])
        for missing in ["Return", "Learn C++"] {
            let no = await write(.complete, title: missing, store: store)
            #expect((no["text"] as? String)?.contains("could not find") == true)
        }
        #expect(await store.completed == ["the-only-key"])
    }

    @Test("Creating checks even the 22nd same-title record for the matching due date and recurrence")
    func createDuplicateBeyondCap() async {
        let dated = (0..<21).map { ReminderRow(title: "Return key", due: day.addingTimeInterval(Double($0) * 3600),
                                                dueHasTime: true, identifier: "dated-\($0)", repeats: .daily) }
        let store = Store(dated + [ReminderRow(title: "Return Key", identifier: "undated-duplicate")])
        let duplicate = await write(.create, store: store)
        #expect(duplicate["already_existed"] as? Bool == true)
        #expect(!ModelWriteTurn.didWrite(duplicate))
        #expect(await store.added.isEmpty)
        let noDuplicate = Store(dated)
        #expect(ModelWriteTurn.didWrite(await write(.create, store: noDuplicate)))
        #expect(await noDuplicate.added == ["Return key"])
    }

    @Test("A date-only task doesn't suppress a separate task requested for midnight")
    func dateOnlyVersusMidnight() {
        let midnight = Calendar.current.startOfDay(for: day)
        let candidate = NewReminder(title: "Return key", due: midnight, dueHasTime: true)
        let dateOnly = ReminderRow(title: "Return key", due: midnight, dueHasTime: false)
        #expect(PersonalDataWrites.duplicate(of: candidate, in: [dateOnly], calendar: .current) == nil)
    }

    @Test("A partial display page or failed EventKit fetch cannot authorize a write")
    func incompleteLookupRefusesBothWrites() async {
        let page = OpenReminderQuery.list(in: DateWindow(start: nil, end: nil), limit: 20)
        for verb in [ReminderAction.create, .complete] {
            for (store, query) in [(Store(others(19) + [ReminderRow(title: "Return key", due: day.addingTimeInterval(40)),
                ReminderRow(title: "Return key")]), Optional(page)), (Store(nil), nil)] {
                let result = await write(verb, store: store, query: query)
                #expect((result["text"] as? String)?.contains("could not check every open reminder") == true)
                #expect(!ModelWriteTurn.didWrite(result))
                #expect(await store.added.isEmpty)
                #expect(await store.completed.isEmpty)
            }
        }
    }

    @Test("The EventKit create and complete adapters both select write matches, not display rows")
    func productionLookupWiring() throws {
        let source = try ToolPermissionTests.source("ToolBodies.swift")
        let start = try #require(source.range(of: "static func reminders("))
        let section = source[start.upperBound...]
        for verb in ["case .create:", "case .complete:"] {
            let start = try #require(section.range(of: verb))
            let body = section[start.upperBound...].components(separatedBy: "case .")[0]
            #expect(body.contains(".writeMatches(title: title)") && !body.contains("reminders(in:"))
        }
    }
}
