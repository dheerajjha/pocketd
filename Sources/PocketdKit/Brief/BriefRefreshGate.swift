/// Serializes reads of the day. An ordinary calendar edit asks for another
/// pass; a change of source access also disqualifies the pass already running.
@MainActor
public final class BriefRefreshGate<Access: Equatable & Sendable> {
    public struct Ticket: Equatable, Sendable {
        public let access: Access
        fileprivate let revision: UInt64

        /// A previously accepted read may still be waiting to call the model,
        /// or to publish a stream's last token, when a source is withdrawn.
        @MainActor
        public func permitsDelivery(current: @MainActor () -> Self?) -> Bool {
            !Task.isCancelled && self == current()
        }
    }

    private var current: Ticket?
    public private(set) var isRefreshing = false
    public private(set) var isStale = true
    private var wantsForcedPass = false

    public init() {}

    /// A switch changing off and back on is still a new permission to read,
    /// even if the effective access looks the same when an old read resumes.
    @discardableResult
    public func observe(_ access: Access, newRevision: Bool = false, onChange: @MainActor () -> Void) -> Ticket {
        if !newRevision, let current, current.access == access { return current }
        let previous = current
        let next = Ticket(access: access, revision: (previous?.revision ?? 0) &+ 1)
        current = next
        isStale = true
        if previous != nil || newRevision { onChange() }
        return next
    }

    public func markStale() { isStale = true }

    /// `current` samples the live switches and reportable grants. Check again
    /// after the suspension, in the same actor turn that publishes the result.
    /// No ticket means the app is in the background: leave the read due, but
    /// do not keep retrying until the foreground asks again.
    public func refresh<Value: Sendable>(
        force: Bool,
        current: @MainActor () -> Ticket?,
        read: @MainActor (Access) async -> Value,
        publish: @MainActor (Value, Ticket, Bool) -> Void
    ) async {
        if isRefreshing {
            if force { wantsForcedPass = true }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var forced = force || wantsForcedPass
        wantsForcedPass = false
        repeat {
            guard let ticket = current() else { deferUntilForeground(force: forced); return }
            isStale = false
            let value = await read(ticket.access)
            guard let latest = current() else { deferUntilForeground(force: forced); return }
            let accepted = ticket == latest
            if accepted { publish(value, ticket, forced) }
            forced = wantsForcedPass || (!accepted && forced)
            wantsForcedPass = false
        } while isStale || forced
    }

    private func deferUntilForeground(force: Bool) {
        isStale = true
        if force { wantsForcedPass = true }
    }
}
