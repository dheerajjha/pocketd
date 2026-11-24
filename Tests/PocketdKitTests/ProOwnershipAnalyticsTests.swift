import Foundation
import Testing
@testable import PocketdKit
#if canImport(StoreKit)
import StoreKit

@Suite("Verified StoreKit analytics evidence")
struct ProOwnershipAnalyticsTests {
    @Test("a verified revocation is not a completed empty entitlement scan")
    func updateIsNotAbsence() {
        var scan = ProOwnershipScan()
        scan.observe(VerificationResult<Int>.verified(0)) { $0 == 1 }
        #expect(scan.analyticsPlan(environment: .production, originalAppVersion: "1792600000") == .unknown)
        #expect(scan.analyticsPlan(environment: .production, originalAppVersion: "1789638888") == .earlySupporter)
        scan.observe(VerificationResult<Int>.verified(1)) { $0 == 1 }
        #expect(scan.analyticsPlan(environment: .production, originalAppVersion: "1792600000") == .lifetime)
    }

    @Test("the shipping listener invalidates unverifiable updates and cancellation guards early publication")
    func listenerUncertaintyWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Sources/Store/ProStore.swift"), encoding: .utf8)
        let invalidatesUnverified = source.contains("guard case let .verified(transaction) = update else {\n            analyticsPlan.invalidate()")
        let cancellable = source.contains("if !Task.isCancelled { analyticsPlan.accept(.lifetime, revision: analyticsScan) }")
        let completesScan = source.contains("scan.complete(cancelled: Task.isCancelled)")
        #expect(invalidatesUnverified)
        #expect(cancellable)
        #expect(completesScan)
    }

    @Test("an unverified row cannot become verified free or change the locked access verdict")
    func unverifiedThenVerified() {
        var scan = ProOwnershipScan()
        scan.observe(VerificationResult<Int>.unverified(1, .invalidSignature)) { $0 == 1 }
        scan.complete()
        #expect(!scan.ownsPurchase)
        let plan = scan.analyticsPlan(environment: .production, originalAppVersion: "1792600000")
        #expect(plan == .unknown)
        #expect(plan.isPro == nil)
        #expect(ProAccess.entitlement(purchased: scan.ownsPurchase, environment: .production,
                                     originalAppVersion: "1792600000") == .locked)
        scan.observe(VerificationResult<Int>.verified(1)) { $0 == 1 }
        #expect(scan.ownsPurchase)
        #expect(scan.analyticsPlan(environment: nil, originalAppVersion: nil) == .lifetime)
    }

    @Test("verified absence, early acquisition and cancellation stay distinct")
    func absenceAndEarly() {
        var scan = ProOwnershipScan()
        scan.observe(VerificationResult<Int>.verified(2)) { $0 == 1 }
        scan.complete()
        #expect(scan.analyticsPlan(environment: .production, originalAppVersion: "1792600000") == .free)
        scan.complete(cancelled: true)
        #expect(scan.analyticsPlan(environment: .production, originalAppVersion: "1792600000") == .unknown)
        scan.complete()
        #expect(scan.analyticsPlan(environment: nil, originalAppVersion: nil) == .unknown)
        #expect(scan.analyticsPlan(environment: .production, originalAppVersion: "1789638888") == .earlySupporter)
        #expect(scan.analyticsPlan(environment: .production, originalAppVersion: "1792600000", cancelled: true) == .unknown)
        scan.observe(VerificationResult<Int>.unverified(2, .invalidSignature)) { $0 == 1 }
        #expect(scan.analyticsPlan(environment: .production, originalAppVersion: "1792600000") == .unknown)
    }

    @Test("shipping StoreKit gathering consumes every verification result separately from access")
    func storeWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Sources/Store/ProStore.swift"), encoding: .utf8)
        #expect(source.contains("scan.observe(result)"))
        #expect(source.contains("let purchased = ownership.ownsPurchase"))
        #expect(source.contains("analyticsOwnership?.analyticsPlan("))
        #expect(!source.contains("private static func ownsPro() async -> Bool"))
    }
}
#endif
