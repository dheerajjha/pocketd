import Foundation

/// A single invocation, not a cache: concurrent reads can have identical visible
/// rows in different orders. The tool library only returns a model-facing dictionary;
/// never put the native handles in it, even under a key today's prompt renderer skips.
actor NativeReminderCard {
    @TaskLocal static var current: NativeReminderCard?
    private let arguments: String
    private(set) var card: AnswerCard?

    init(arguments: String) { self.arguments = arguments }

    func record(_ data: [String: any Sendable], items: [AnswerCard.Item]) {
        card = AnswerCardBuilders.reminderCard(arguments, data, nativeItems: items)
    }
}

public extension ToolResult {
    typealias CardOutput = (data: [String: any Sendable], card: AnswerCard?)

    /// Runs one tool and collects its native card separately from the bytes either
    /// model may receive. A missing capture simply produces a display-only card.
    static func withCard(from tool: String, arguments: String,
                         _ body: @Sendable () async throws -> [String: any Sendable]) async rethrows -> CardOutput {
        let capture = tool == PersonalDataToolNames.reminders ? NativeReminderCard(arguments: arguments) : nil
        let data = try await NativeReminderCard.$current.withValue(capture) { try await body() }
        let card = await capture?.card ?? AnswerCardCatalogue.standard.card(for: tool, arguments: arguments, data: data)
        return (data, card)
    }
}
