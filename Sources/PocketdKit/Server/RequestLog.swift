import Foundation

public struct RequestLogEntry: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let method: String
    public let path: String
    public let clientAddress: String?
    public var statusCode: Int
    public var model: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var duration: TimeInterval?
    public var streamed: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        method: String,
        path: String,
        clientAddress: String? = nil,
        statusCode: Int = 0,
        model: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        duration: TimeInterval? = nil,
        streamed: Bool = false
    ) {
        self.id = id
        self.date = date
        self.method = method
        self.path = path
        self.clientAddress = clientAddress
        self.statusCode = statusCode
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.duration = duration
        self.streamed = streamed
    }

    public var tokensPerSecond: Double? {
        guard let completionTokens, let duration, duration > 0 else { return nil }
        return Double(completionTokens) / duration
    }
}

/// A bounded, in-memory record of what the server has been asked to do.
///
/// Bounded because this runs on a phone: an unbounded log of a server left on
/// overnight is a memory leak that competes with the weights for the same
/// jetsam budget. Nothing is written to disk — the point of the app is that
/// requests do not leave the device, and that includes not persisting them.
public actor RequestLog {
    public static let defaultCapacity = 200

    private var entries: [RequestLogEntry] = []
    private let capacity: Int
    private var observers: [UUID: AsyncStream<[RequestLogEntry]>.Continuation] = [:]

    public init(capacity: Int = RequestLog.defaultCapacity) {
        self.capacity = capacity
    }

    public func record(_ entry: RequestLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        broadcast()
    }

    public func update(id: UUID, transform: @Sendable (inout RequestLogEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        transform(&entries[index])
        broadcast()
    }

    public func all() -> [RequestLogEntry] { entries }

    public func clear() {
        entries.removeAll()
        broadcast()
    }

    /// Live view for the UI. The continuation is dropped when the consumer goes
    /// away, so a closed screen stops costing anything.
    public func stream() -> AsyncStream<[RequestLogEntry]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(entries)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func broadcast() {
        for continuation in observers.values { continuation.yield(entries) }
    }
}
