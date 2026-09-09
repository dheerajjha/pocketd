import Foundation
import Testing
@testable import PocketdKit

@Suite("Configuration persistence")
struct ConfigurationStoreTests {

    private func makeDefaults() throws -> UserDefaults {
        let suite = "pocketd.tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    /// The regression this file exists for. The first version generated the API
    /// key in an initialiser and relied on a `didSet` to save it — an observer
    /// Swift does not run during initialisation. Every relaunch minted a new key
    /// and every configured client started getting 401s.
    @Test("the generated API key survives a relaunch")
    func keySurvivesRelaunch() throws {
        let defaults = try makeDefaults()

        let first = ServerConfigurationStore(defaults: defaults).load()
        // A second store is what the next launch sees.
        let second = ServerConfigurationStore(defaults: defaults).load()

        #expect(first.apiKey == second.apiKey, "a new key on every launch breaks every configured client")
        #expect(first == second)
    }

    @Test("a fresh configuration is written on first read, not deferred")
    func persistsOnFirstLoad() throws {
        let defaults = try makeDefaults()
        #expect(defaults.data(forKey: "pocketd.configuration") == nil)

        _ = ServerConfigurationStore(defaults: defaults).load()

        #expect(defaults.data(forKey: "pocketd.configuration") != nil,
                "an API key that exists only in memory is worse than none — the user has already given it to a client")
    }

    @Test("round-trips every field")
    func roundTrip() throws {
        let defaults = try makeDefaults()
        let store = ServerConfigurationStore(defaults: defaults)

        var configuration = store.load()
        configuration.port = 8080
        configuration.binding = .loopback
        configuration.requiresAuth = false
        configuration.maxContextTokens = 16_384
        configuration.keepAwakeWhileServing = false
        store.save(configuration)

        #expect(ServerConfigurationStore(defaults: defaults).load() == configuration)
    }

    @Test("a corrupt stored value falls back instead of crashing")
    func corruptValue() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("{ not json".utf8), forKey: "pocketd.configuration")

        let loaded = ServerConfigurationStore(defaults: defaults).load()
        #expect(loaded.apiKey.hasPrefix("pk-"))
        // ...and the replacement must itself be persisted, or the next launch
        // hits the same corrupt value and mints another key.
        #expect(ServerConfigurationStore(defaults: defaults).load().apiKey == loaded.apiKey)
    }
}
