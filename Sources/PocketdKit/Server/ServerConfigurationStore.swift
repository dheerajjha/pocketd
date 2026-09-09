import Foundation

/// Persists the server configuration, including the generated API key.
///
/// This is a type rather than two lines in the app because of how the first
/// version failed. The configuration was a property with a `didSet` that saved
/// it, assigned once in the owner's initialiser — and Swift does not run
/// property observers during initialisation. So the generated key was never
/// written, a fresh one was minted on every launch, and every client that had
/// been given a key started getting 401s after the next app restart, with
/// nothing in the UI to suggest why. Persisting the default on first read is
/// the whole job, and it now has a test.
// UserDefaults is thread-safe but not marked Sendable, so the conformance is
// unchecked rather than absent — the alternative is that this type cannot cross
// an isolation boundary at all.
public struct ServerConfigurationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "pocketd.configuration") {
        self.defaults = defaults
        self.key = key
    }

    /// Returns the stored configuration, or creates and immediately persists a
    /// new one. The write is not deferred: an API key that exists only in
    /// memory is worse than no API key, because the user has already handed it
    /// to a client by the time it disappears.
    public func load() -> ServerConfiguration {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ServerConfiguration.self, from: data) {
            return decoded
        }
        let fresh = ServerConfiguration()
        save(fresh)
        return fresh
    }

    public func save(_ configuration: ServerConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}
