import Foundation

/// The current date, written into the system message.
///
/// Deliberately not a tool, and the arithmetic is measured rather than a matter
/// of taste. A `get_current_datetime` tool costs about 72 tokens of schema AND
/// forces the library's 264-character preamble into existence — roughly 160
/// tokens before the model does anything. This string is about 76. Half the
/// price, and it cannot fail.
///
/// Three further reasons a tool is the wrong shape here. A tool has to be
/// CHOSEN, and a small model will not reliably work out that "what's on
/// tomorrow" needs a datetime call before a calendar call. A tool costs a whole
/// extra round trip — two prefills — for a fact that is free to compute. And
/// the library deduplicates tool calls by name, so a chain that needs the date
/// twice gets it once.
///
/// Yesterday and tomorrow are spelled out because small models are unreliable
/// at date arithmetic, and every relative question depends on getting it right.
public enum DateContext {
    public static func sentence(
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        calendar.locale = locale

        let long = DateFormatter()
        long.locale = locale
        long.timeZone = timeZone
        long.dateFormat = "EEEE, d MMMM yyyy"

        let clock = DateFormatter()
        clock.locale = locale
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm"

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now

        let offset = timeZone.secondsFromGMT(for: now)
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 3600
        let minutes = (abs(offset) % 3600) / 60
        let utc = String(format: "UTC%@%02d:%02d", sign, hours, minutes)

        let weekStart = calendar.weekdaySymbols[max(0, min(6, calendar.firstWeekday - 1))]

        return """
        Current date and time: \(long.string(from: now)), \(clock.string(from: now)) (\(timeZone.identifier), \(utc)). \
        Yesterday was \(long.string(from: yesterday)). Tomorrow is \(long.string(from: tomorrow)). \
        The user's locale is \(locale.identifier) and the week starts on \(weekStart).
        """
    }

    /// Prepends the date to the system turn, creating one if the client sent
    /// none — most OpenAI-compatible clients do not.
    public static func inject(into messages: [ChatMessage], now: Date = Date()) -> [ChatMessage] {
        let line = sentence(now: now)
        guard let index = messages.firstIndex(where: { $0.role == .system }) else {
            return [ChatMessage.system(line)] + messages
        }
        var updated = messages
        updated[index].content = line + "\n\n" + updated[index].content
        return updated
    }
}
