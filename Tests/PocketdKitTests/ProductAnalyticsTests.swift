import Foundation
import Testing
@testable import PocketdKit

@Suite("Product analytics runtime", .serialized)
@MainActor
struct ProductAnalyticsTests {
    @Test("cancelled then genuine completion latches only the latter", arguments: [
        "/v1/chat/completions", "/v1/completions", "/api/chat", "/api/generate"
    ], [false, true])
    func cancelledThenCompleted(path: String, streaming: Bool) async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey); defaults.removeObject(forKey: ProductAnalytics.firstValueKey) }
        let sink = RecordingAnalytics()
        let start = Date()
        let tracker = ProductAnalytics(sink: sink, defaults: defaults, now: start)
        let harness = try await TestServer.start(engine: AnalyticsOutcomeEngine())
        defer { Task { await harness.stop() } }
        for attempt in 0..<2 {
            let body: [String: Any] = path == "/api/generate" || path == "/v1/completions"
                ? ["model": "echo", "prompt": "fixture", "stream": streaming]
                : ["model": "echo", "messages": [["role": "user", "content": "fixture"]], "stream": streaming]
            var request = try harness.request("POST", path)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            #expect(try await harness.send(request).0 == 200, "wire behavior is unchanged, even on engine cancellation")
            let entries = await harness.server.log.all()
            #expect(entries.count == attempt + 1)
            let entry = try #require(entries.first)
            #expect(entry.generationCompleted == (attempt == 1))
            // Keep the actual route-gathered outcome; substitute only the peer to
            // exercise the external branch without treating forwarded headers as peers.
            let external = RequestLogEntry(id: entry.id, date: entry.date, method: entry.method,
                path: entry.path, clientAddress: "192.168.1.42", statusCode: entry.statusCode,
                streamed: entry.streamed, generationCompleted: entry.generationCompleted)
            tracker.observeRequests([external], consent: .granted, now: start.addingTimeInterval(Double(attempt + 1)))
            if attempt == 0 {
                #expect(sink.events.isEmpty)
                #expect(!defaults.bool(forKey: ProductAnalytics.firstValueKey))
            }
        }
        #expect(sink.events.count == 2)
        #expect(sink.events.last == .firstValueReached(secondsSinceInstall: 2))
        #expect(defaults.bool(forKey: ProductAnalytics.firstValueKey))
        defaults.removeObject(forKey: ProductAnalytics.installKey)
        defaults.removeObject(forKey: ProductAnalytics.firstValueKey)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "pocketd.tests.analytics.\(UUID().uuidString)")!
    }

    @Test("completed external HTTP actions emit first value, not failures or pending requests")
    func successfulExternalAction() async {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey); defaults.removeObject(forKey: ProductAnalytics.firstValueKey) }
        let sink = RecordingAnalytics()
        let start = Date(timeIntervalSince1970: 100_000)
        let tracker = ProductAnalytics(sink: sink, defaults: defaults, now: start)
        let log = RequestLog()
        let request = RequestLogEntry(method: "POST", path: "/v1/chat/completions", clientAddress: "192.168.1.42")
        await log.record(request)
        tracker.observeRequests(await log.all(), consent: .granted, now: start.addingTimeInterval(12))
        #expect(sink.events.isEmpty)
        await log.update(id: request.id) { $0.statusCode = 200; $0.duration = 1; $0.generationCompleted = true }
        tracker.observeRequests(await log.all(), consent: .granted, now: start.addingTimeInterval(15))
        #expect(sink.events == [.externalClientConnected(dialect: .openai), .firstValueReached(secondsSinceInstall: 15)])
        #expect(defaults.bool(forKey: ProductAnalytics.firstValueKey))
        tracker.observeRequests(await log.all(), consent: .granted, now: start.addingTimeInterval(18))
        #expect(sink.events.count == 2, "updating/broadcasting the same request is not another action")
        #expect(sink.events.last?.properties(installEnvironment: .appStore)["action"] == .string("external_client"))
    }

    @Test("loopback, missing peers, non-API paths and failed HTTP never latch first value")
    func rejectsNonValue() {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey) }
        let sink = RecordingAnalytics()
        let tracker = ProductAnalytics(sink: sink, defaults: defaults)
        for peer in [nil, "127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1"] as [String?] {
            tracker.observeRequests([.init(method: "GET", path: "/api/tags", clientAddress: peer, statusCode: 200, generationCompleted: true)], consent: .granted)
        }
        tracker.observeRequests([.init(method: "GET", path: "/v1/models", clientAddress: "192.168.1.42", statusCode: 401, generationCompleted: true)], consent: .granted)
        tracker.observeRequests([.init(method: "GET", path: "/health", clientAddress: "192.168.1.42", statusCode: 200, generationCompleted: true)], consent: .granted)
        #expect(!defaults.bool(forKey: ProductAnalytics.firstValueKey))
        #expect(!sink.events.contains { if case .externalClientConnected = $0 { return true }; return false })
    }

    @Test("relaunch, SDK reset and consent cycles keep one install latch")
    func latchSurvives() {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey); defaults.removeObject(forKey: ProductAnalytics.firstValueKey) }
        let sink = RecordingAnalytics()
        let tracker = ProductAnalytics(sink: sink, defaults: defaults)
        tracker.firstValue(consent: .granted)
        sink.stopAndForget(); sink.resume()
        let relaunched = ProductAnalytics(sink: sink, defaults: defaults)
        relaunched.firstValue(consent: .granted)
        #expect(sink.events.isEmpty)
        #expect(defaults.bool(forKey: ProductAnalytics.firstValueKey))
    }

    @Test("refusal and NoAnalytics neither send nor consume first value")
    func consentBoundary() {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey) }
        let sink = RecordingAnalytics()
        let tracker = ProductAnalytics(sink: sink, defaults: defaults)
        tracker.record(.shareUsed(kind: .address), consent: .refused)
        tracker.firstValue(consent: .undecided)
        let request = RequestLogEntry(method: "GET", path: "/v1/models", clientAddress: "192.168.1.42", statusCode: 200, generationCompleted: true)
        tracker.observeRequests([request], consent: .refused)
        tracker.observeRequests([request], consent: .granted)
        #expect(sink.events.isEmpty, "never replay an action performed while opted out")
        #expect(!defaults.bool(forKey: ProductAnalytics.firstValueKey))
        ProductAnalytics(sink: NoAnalytics(), defaults: defaults).firstValue(consent: .granted)
        #expect(!defaults.bool(forKey: ProductAnalytics.firstValueKey))
    }

    @Test("fresh install-age and verified-only plan context reach the runtime spy")
    func contextMapping() {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey) }
        let sink = RecordingAnalytics()
        let start = Date(timeIntervalSince1970: 100_000)
        let tracker = ProductAnalytics(sink: sink, defaults: defaults, now: start)
        tracker.context.plan = .lifetime
        tracker.context.appearance = .dark
        tracker.context.typeSize = .accessibility
        tracker.context.notifications = .authorized
        tracker.record(.appForegrounded, consent: .granted, now: start.addingTimeInterval(10 * 86_400))
        let properties = sink.events[0].properties(installEnvironment: .appStore, context: sink.contexts[0])
        #expect(properties["is_pro"] == .bool(true))
        #expect(properties["plan"] == .string("lifetime"))
        #expect(properties["install_age_days"] == .string("days_7_29"))
        #expect(properties["appearance"] == .string("dark"))
        #expect(properties["dynamic_type"] == .string("accessibility"))
        #expect(properties["notifications_authorised"] == .bool(true))
        #expect(Set(properties.keys) == AnalyticsSchema.allowedProperties["app_foregrounded"]!.union(AnalyticsSchema.contextProperties))
        tracker.context.plan = .unknown
        tracker.context.notifications = .unknown
        tracker.record(.restoreStarted, consent: .granted)
        #expect(sink.contexts.last?.properties["is_pro"] == nil)
        #expect(sink.contexts.last?.properties["notifications_authorised"] == nil)
    }

    @Test("new catalogue accepts only bounded context and event keys")
    func boundedContext() {
        let rawValues = AnalyticsPlan.allCases.map(\.rawValue)
            + AnalyticsAppearance.allCases.map(\.rawValue)
            + AnalyticsTypeSize.allCases.map(\.rawValue)
            + AnalyticsNotificationStatus.allCases.map(\.rawValue)
            + AnalyticsInstallAge.allCases.map(\.rawValue)
            + AnalyticsFeature.allCases.map(\.rawValue)
            + AnalyticsSurface.allCases.map(\.rawValue)
            + AnalyticsPaywallTrigger.allCases.map(\.rawValue)
            + AnalyticsRestoreOutcome.allCases.map(\.rawValue)
            + AnalyticsPermission.allCases.map(\.rawValue)
            + AnalyticsPermissionOutcome.allCases.map(\.rawValue)
            + AnalyticsSetting.allCases.map(\.rawValue)
            + AnalyticsShare.allCases.map(\.rawValue)
            + AnalyticsErrorArea.allCases.map(\.rawValue)
            + AnalyticsScreen.allCases.map(\.rawValue)
        for raw in rawValues {
            #expect(raw.count <= 24)
            #expect(raw.allSatisfy { $0.isLowercase || $0 == "_" || $0.isNumber })
        }
        for plan in AnalyticsPlan.allCases {
            var context = AnalyticsContext(); context.plan = plan
            #expect(Set(context.properties.keys).isSubset(of: AnalyticsSchema.contextProperties))
            #expect(Set(context.properties.keys).isDisjoint(with: AnalyticsSchema.forbiddenProperties))
        }
        #expect(AnalyticsEvent.restoreCompleted(outcome: .failed, errorCode: 17).properties(installEnvironment: .appStore)["error_code"] == .int(17))
        #expect(AnalyticsEvent.permissionResult(permission: .health, outcome: .completed).properties(installEnvironment: .appStore)["outcome"] == .string("completed"))
    }

    @Test("purchase invalidation rejects older scans and directly publishes verified results")
    func planPublicationOrdering() {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey) }
        let sink = RecordingAnalytics()
        let tracker = ProductAnalytics(sink: sink, defaults: defaults)
        let publication = AnalyticsPlanPublication { tracker.context.plan = $0 }
        let oldScan = publication.invalidate()
        publication.accept(.earlySupporter, revision: oldScan)
        tracker.record(.appForegrounded, consent: .granted)
        publication.invalidate()
        tracker.record(.purchaseStarted(entry: .inApp), consent: .granted)
        publication.accept(.earlySupporter, revision: oldScan)
        tracker.record(.purchasePending(entry: .inApp), consent: .granted)
        publication.accept(.lifetime)
        tracker.record(.purchaseCompleted(entry: .inApp), consent: .granted)
        #expect(sink.contexts.map(\.plan) == [.earlySupporter, .unknown, .unknown, .lifetime])
        #expect(sink.contexts[1].properties["is_pro"] == nil)
        #expect(sink.contexts[3].properties["is_pro"] == .bool(true))
    }

    @Test("real HTTP log reaches the spy without trusting forwarded client addresses")
    func realHTTPGathering() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey) }
        let sink = RecordingAnalytics()
        let tracker = ProductAnalytics(sink: sink, defaults: defaults)
        let harness = try await TestServer.start()
        defer { Task { await harness.stop() } }
        let metadata = try harness.request("GET", "/v1/models")
        #expect(try await harness.send(metadata).0 == 200)
        tracker.observeRequests(await harness.server.log.all(), consent: .granted)
        #expect(sink.events.isEmpty, "successful metadata routes currently are not logged")
        var request = try harness.request("POST", "/v1/chat/completions", json: OpenAI.ChatCompletionRequest(
            model: "echo", messages: [OpenAI.Message(role: "user", content: "fixture")], stream: false
        ))
        request.setValue("192.168.1.42", forHTTPHeaderField: "X-Forwarded-For")
        #expect(try await harness.send(request).0 == 200)
        tracker.observeRequests(await harness.server.log.all(), consent: .granted)
        #expect(sink.events == [.onDeviceClientConnected(dialect: .openai)])
        #expect(!defaults.bool(forKey: ProductAnalytics.firstValueKey))
        tracker.observeRequests(await harness.server.log.all(), consent: .granted)
        #expect(sink.events.count == 1)
    }

    @Test("a delayed opt-out request is not replayed after opt-in")
    func delayedRequestConsent() {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: ProductAnalytics.installKey); defaults.removeObject(forKey: ProductAnalytics.firstValueKey) }
        let sink = RecordingAnalytics()
        let start = Date(timeIntervalSince1970: 100_000)
        let tracker = ProductAnalytics(sink: sink, defaults: defaults, now: start)
        tracker.consentChanged(now: start.addingTimeInterval(20))
        let old = RequestLogEntry(date: start.addingTimeInterval(15), method: "POST", path: "/api/chat", clientAddress: "192.168.1.42", statusCode: 200, generationCompleted: true)
        tracker.observeRequests([old], consent: .granted, now: start.addingTimeInterval(30))
        #expect(sink.events.isEmpty)
        #expect(!defaults.bool(forKey: ProductAnalytics.firstValueKey))
        let fresh = RequestLogEntry(date: start.addingTimeInterval(21), method: "POST", path: "/api/chat", clientAddress: "192.168.1.42", statusCode: 200, generationCompleted: true)
        tracker.observeRequests([fresh, old], consent: .granted, now: start.addingTimeInterval(31))
        #expect(sink.events == [.externalClientConnected(dialect: .ollama), .firstValueReached(secondsSinceInstall: 31)])
    }
}

private actor AnalyticsOutcomeEngine: InferenceEngine {
    nonisolated let backendName = "analytics_fixture"
    private var calls = 0
    func loadedModel() -> ModelRecord? { .echo }
    func load(model: ModelRecord) {}
    func unload() {}
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        calls += 1
        let reason: FinishReason = calls == 1 ? .cancelled : .stop
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("fixture"))
            continuation.yield(.finished(reason: reason, usage: .init(promptTokens: 1, completionTokens: 1)))
            continuation.finish()
        }
    }
}
