import Foundation

/// The three model-origin EventKit entry points. Injecting storage rather
/// than authority keeps tests on the same path as both real tool adapters.
/// Buttons, including exact-row completion and Undo, have their own authority.
public enum ModelPersonalDataWrites {
    public static func createEvent(title: String?, start: String?, durationMinutes: Int?, origin: RequestOrigin,
                                   write: @Sendable (NewEvent) async -> WriteResult) async -> ModelWriteTurn.Payload {
        await ModelWriteTurn.perform(.addEvent, title: title, when: start, minutes: durationMinutes, origin: origin) {
            await PersonalDataWrites.createEvent(title: title, start: start, durationMinutes: durationMinutes,
                                                  userText: ModelWriteTurn.current?.question, origin: origin, write: write)
        }
    }

    public static func createReminder(title: String?, when: String?, origin: RequestOrigin,
                                      existing: @Sendable () async -> PersonalDataLookup<ReminderRow>,
                                      write: @Sendable (NewReminder) async -> WriteResult) async -> ModelWriteTurn.Payload {
        await ModelWriteTurn.perform(.addReminder, title: title, when: when, origin: origin) {
            await PersonalDataWrites.createReminder(title: title, when: when, origin: origin, existing: existing, write: write)
        }
    }

    public static func completeReminder(title: String?, when: String?, origin: RequestOrigin,
                                        existing: @Sendable () async -> PersonalDataLookup<ReminderRow>,
                                        complete: @Sendable (ReminderRow) async -> WriteResult) async -> ModelWriteTurn.Payload {
        await ModelWriteTurn.perform(.tickOff, title: title, when: when, origin: origin) {
            await PersonalDataWrites.completeReminder(title: title, origin: origin, existing: existing, complete: complete)
        }
    }
}
