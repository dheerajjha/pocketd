import Testing
import Foundation
@testable import PocketdKit

/// The guard on what this app is allowed to say about its users.
///
/// Worth more than a test that asserts a call happened. The realistic failure
/// is not that we forget to send an event — someone notices that within a day
/// of opening a dashboard. It is that a property with something personal in it
/// gets added later, by someone reasonable, to debug something real, and ships
/// because nothing objected.
@Suite("Analytics taxonomy")
struct AnalyticsTaxonomyTests {

    /// One of every event. Exhaustiveness is enforced by `everyCaseIsSampled`.
    private static let sample: [AnalyticsEvent] = [
        .appOpened(isFirstLaunch: true),
        .onboardingCompleted(via: .skipped, destination: .models),
        .modelDownloadStarted(modelID: "llama-3.2-1b", sizeBytes: 807_700_000),
        .modelDownloadCompleted(modelID: "llama-3.2-1b", durationSeconds: 41.2),
        .modelDownloadCancelled(modelID: "gemma-4-e2b", percentComplete: 14),
        .modelDownloadFailed(modelID: "qwen3-4b", reason: .offline),
        .oversizeOverride(modelID: "gemma-4-e2b"),
        .modelLoadSucceeded(modelID: "smollm2-360m", ramClass: "6gb", loadMilliseconds: 3_200),
        .modelLoadFailed(modelID: "qwen3-4b", ramClass: "6gb", reason: .outOfMemory),
        .chatMessageSent(modelID: "smollm2-360m"),
        .serverStarted,
        .serverStopped(servedSeconds: 742.5),
        .externalClientConnected(dialect: .openai),
        .onDeviceClientConnected(dialect: .ollama),
        .generationRefused(reason: .thermal)
    ]

    @Test("every event's properties match the schema exactly")
    func propertiesMatchSchema() throws {
        // Exactly, not "is a subset". A missing property is a silently empty
        // column in a dashboard nobody notices for a month; an extra one is
        // the thing this suite exists to stop.
        for event in Self.sample {
            let allowed = try #require(AnalyticsSchema.allowedProperties[event.name],
                                       "\(event.name) has no schema entry")
            #expect(Set(event.properties.keys) == allowed,
                    "\(event.name) sends \(Set(event.properties.keys).sorted()) but the schema allows \(allowed.sorted())")
        }
    }

    @Test("no event carries a forbidden property name")
    func noForbiddenProperties() {
        for event in Self.sample {
            for key in event.properties.keys {
                #expect(AnalyticsSchema.forbiddenProperties.contains(key) == false,
                        "\(event.name) carries forbidden property '\(key)'")
            }
        }
    }

    @Test("the schema itself declares nothing forbidden")
    func schemaIsClean() {
        // Checks the table rather than the code, so adding a banned name to
        // the schema fails even before anything emits it.
        for (event, keys) in AnalyticsSchema.allowedProperties {
            for key in keys {
                #expect(AnalyticsSchema.forbiddenProperties.contains(key) == false,
                        "schema for \(event) allows forbidden property '\(key)'")
            }
        }
    }

    @Test("every event case is covered by the sample")
    func everyCaseIsSampled() {
        // Without this, adding a case and forgetting to sample it means every
        // other test in this file silently stops covering it. The count is
        // hand-maintained on purpose: bumping it is the moment you notice you
        // must also add a sample.
        #expect(Self.sample.count == 15)
        #expect(Set(Self.sample.map(\.name)).count == Self.sample.count, "duplicate event in sample")
        #expect(Set(Self.sample.map(\.name)) == Set(AnalyticsSchema.allowedProperties.keys),
                "sample and schema disagree about which events exist")
    }

    @Test("reasons are closed sets, so no free text can reach the wire")
    func reasonsAreBounded() {
        // The failure this prevents: piping LocalizedError.errorDescription or
        // ModelTransfer.State.failed's message straight into `reason`. A
        // URLError's userInfo here carries the signed CDN URL and the whole
        // resume blob — that has already leaked onto a screen in this app once.
        #expect(DownloadFailureReason.allCases.isEmpty == false)
        #expect(LoadFailureReason.allCases.isEmpty == false)
        #expect(RefusalReason.allCases.count == 3)
        for raw in DownloadFailureReason.allCases.map(\.rawValue)
            + LoadFailureReason.allCases.map(\.rawValue)
            + RefusalReason.allCases.map(\.rawValue)
            + ClientDialect.allCases.map(\.rawValue) {
            #expect(raw.count <= 24, "'\(raw)' is long enough to be carrying a message")
            #expect(raw.allSatisfy { $0.isLowercase || $0 == "_" || $0.isNumber })
        }
    }

    @Test("no string value in any event looks like a network address")
    func noAddresses() {
        // is_loopback is a bool precisely so the LAN address never has to be.
        for event in Self.sample {
            for (key, value) in event.properties {
                guard case let .string(text) = value else { continue }
                #expect(text.contains("://") == false, "\(event.name).\(key) looks like a URL")
                let dotted = text.split(separator: ".")
                let looksLikeIPv4 = dotted.count == 4 && dotted.allSatisfy { Int($0) != nil }
                #expect(looksLikeIPv4 == false, "\(event.name).\(key) looks like an IP address")
            }
        }
    }
}

@Suite("Analytics consent")
struct AnalyticsConsentTests {
    @Test("only an explicit yes permits sending")
    func onlyGrantedSends() {
        // The default has to be the safe one. If `undecided` ever starts
        // permitting transmission, this app has sent data from a device whose
        // owner was never shown the sentence explaining it — which for this
        // product is worse than having no analytics at all.
        #expect(AnalyticsConsent.undecided.permitsSending == false)
        #expect(AnalyticsConsent.refused.permitsSending == false)
        #expect(AnalyticsConsent.granted.permitsSending)
        #expect(AnalyticsConsent.allCases.filter(\.permitsSending).count == 1)
    }

    @Test("a stopped sink forgets what it already held")
    func stopAndForgetDropsTheQueue() {
        // "Stop sending" is not enough. Someone who opts out expects what was
        // queued and not yet flushed to go too, and the identifier with it.
        let sink = RecordingAnalytics()
        sink.record(.serverStarted)
        sink.record(.chatMessageSent(modelID: "smollm2-360m"))
        #expect(sink.events.count == 2)

        sink.stopAndForget()
        #expect(sink.events.isEmpty, "opting out must discard the queue, not just close it")
        #expect(sink.wasStopped)

        sink.record(.serverStarted)
        #expect(sink.events.isEmpty, "a stopped sink must stay stopped")
    }

    @Test("the no-op sink cannot transmit")
    func noAnalyticsIsInert() {
        let sink = NoAnalytics()
        sink.record(.appOpened(isFirstLaunch: true))
        sink.stopAndForget()
        // Nothing to assert beyond it existing and compiling: the point is
        // that there is no code path here that could send anything, which is
        // a stronger guarantee than a flag.
    }
}

@Suite("Consent is reversible")
struct ConsentReversibilityTests {
    @Test("a refused sink can be turned back on")
    func refusalIsNotAOneWayDoor() {
        // The failure this prevents is invisible from inside the app: the SDK
        // persists an opt-out across launches, so a switch that only knew how
        // to stop would turn off once and then render a control that does
        // nothing, forever, while still looking like a choice.
        let sink = RecordingAnalytics()
        sink.record(.serverStarted)
        #expect(sink.events.count == 1)

        sink.stopAndForget()
        sink.record(.serverStarted)
        #expect(sink.events.isEmpty, "a stopped sink records nothing")

        sink.resume()
        sink.record(.serverStarted)
        #expect(sink.events.count == 1, "resume must actually reopen the tap")
        #expect(sink.wasStopped == false)
    }

    @Test("resuming does not resurrect what was discarded")
    func resumeIsNotUndo() {
        // Turning it back on must not recover events the person had already
        // been told were thrown away.
        let sink = RecordingAnalytics()
        sink.record(.serverStarted)
        sink.record(.chatMessageSent(modelID: "smollm2-360m"))
        sink.stopAndForget()
        sink.resume()
        #expect(sink.events.isEmpty)
    }
}
