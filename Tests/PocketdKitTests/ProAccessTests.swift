import Foundation
import Testing
@testable import PocketdKit

/// Pocketd Pro: who has it, what it opens, and what the sheet says.
///
/// The cases that matter most are the early-supporter ones, and they matter in
/// both directions. A v1 user who had the laptop server for free must keep it;
/// and App Review, whose sandbox reports an original version of "1.0", must
/// never be waved through as early — a reviewer who cannot see the purchase is
/// a rejection.
@Suite("Pocketd Pro")
struct ProAccessTests {

    // MARK: - Early supporters

    @Test("an App Store install of 1.0.1 is an early supporter")
    func productionV1IsEarly() {
        #expect(ProAccess.isEarlySupporter(environment: .production, originalAppVersion: "1789638888"))
        #expect(ProAccess.isEarlySupporter(environment: .production, originalAppVersion: "1789244768"))
        #expect(ProAccess.entitlement(purchased: false, environment: .production, originalAppVersion: "1789638888") == .earlySupporter)
    }

    @Test("the same build number from the sandbox is never early", arguments: [
        ProAccess.StoreEnvironment.sandbox, .xcode, .other,
    ])
    func sandboxIsNeverEarly(environment: ProAccess.StoreEnvironment) {
        #expect(!ProAccess.isEarlySupporter(environment: environment, originalAppVersion: "1789638888"))
        #expect(ProAccess.entitlement(purchased: false, environment: environment, originalAppVersion: "1789638888") == .locked)
    }

    @Test("no environment at all is never early")
    func missingEnvironment() {
        #expect(!ProAccess.isEarlySupporter(environment: nil, originalAppVersion: "1789638888"))
    }

    @Test("placeholder and missing versions never grant, even in production", arguments: [
        "1.0", "1", "", "0", "1.0.0", "1.1.0",
    ])
    func placeholdersNeverGrant(version: String) {
        #expect(!ProAccess.isEarlySupporter(environment: .production, originalAppVersion: version))
        #expect(ProAccess.entitlement(purchased: false, environment: .production, originalAppVersion: version) == .locked)
    }

    @Test("a missing version never grants")
    func nilVersion() {
        #expect(!ProAccess.isEarlySupporter(environment: .production, originalAppVersion: nil))
    }

    @Test("the line itself and everything after it are not early", arguments: [
        "1789700000", "1789700001", "1792600000", "9999999999",
    ])
    func atAndAfterTheLine(version: String) {
        #expect(!ProAccess.isEarlySupporter(environment: .production, originalAppVersion: version))
    }

    @Test("the newest 1.1.0 TestFlight build before Pro is still below the line")
    func lastBuildBeforePro() {
        #expect(ProAccess.isEarlySupporter(environment: .production, originalAppVersion: "1789676232"))
        #expect(ProAccess.isEarlySupporter(environment: .production, originalAppVersion: "1789699999"))
    }

    @Test("anything that is not a bare whole number is refused", arguments: [
        " 1789638888", "1789638888 ", "+1789638888", "-1789638888", "1789638888.0",
        "1,789,638,888", "1_789_638_888", "17896388e2", "0x6AAD4E68", "0001789638",
        "１７８９６３８８８８", "1789638888\n", "abc", "1789638888abc",
        "99999999999999999999", // too long for a build number, and for an Int
    ])
    func malformedVersions(version: String) {
        #expect(ProAccess.originalBuild(version) == nil)
        #expect(!ProAccess.isEarlySupporter(environment: .production, originalAppVersion: version))
    }

    @Test("fewer than nine digits is not a build number; nine is")
    func digitCountBoundary() {
        #expect(ProAccess.originalBuild("17896388") == nil)
        #expect(ProAccess.originalBuild("12345678") == nil)
        #expect(ProAccess.originalBuild("123456789") == 123_456_789)
        #expect(ProAccess.originalBuild("1789638888") == 1_789_638_888)
    }

    // MARK: - Buying

    @Test("a purchase is Pro whatever the app transaction says", arguments: [
        ProAccess.StoreEnvironment?.none, .production, .sandbox, .xcode, .other,
    ])
    func purchaseIsAlwaysPro(environment: ProAccess.StoreEnvironment?) {
        for version in [nil, "1.0", "1789638888", "1792600000"] as [String?] {
            let entitlement = ProAccess.entitlement(purchased: true, environment: environment, originalAppVersion: version)
            #expect(entitlement == .purchased)
            #expect(entitlement.isPro)
        }
    }

    @Test("only locked is not Pro")
    func isPro() {
        #expect(!ProEntitlement.locked.isPro)
        #expect(ProEntitlement.purchased.isPro)
        #expect(ProEntitlement.earlySupporter.isPro)
    }

    @Test("a new install with no purchase is locked")
    func newInstallIsLocked() {
        #expect(ProAccess.entitlement(purchased: false, environment: .production, originalAppVersion: "1792600000") == .locked)
    }

    // MARK: - Routines

    @Test("the morning brief and the overdue nudge are free; the rest are Pro")
    func templates() {
        #expect(!RoutineTemplate.morningBrief.needsPro)
        #expect(!RoutineTemplate.overdueWatcher.needsPro)
        #expect(RoutineTemplate.eveningWrapUp.needsPro)
        #expect(RoutineTemplate.weeklyReview.needsPro)
        #expect(RoutineTemplate.sleepWatcher.needsPro)
    }

    @Test("the routines sheet offers exactly two free templates")
    func offeredSplit() {
        let free = RoutineTemplate.offered.filter { !$0.needsPro }
        #expect(free == [.morningBrief, .overdueWatcher])
    }

    @Test("the free templates have the free shapes")
    func templateShapes() {
        #expect(RoutineShape(RoutineTemplate.morningBrief.body).isFree)
        #expect(RoutineShape(RoutineTemplate.overdueWatcher.body) == .overdueNudge)
        #expect(RoutineShape(RoutineTemplate.weeklyReview.body) == .question)
    }

    @Test("a new routine from the editor is Custom, and Custom is Pro")
    func newRoutineNeedsPro() {
        #expect(ProAccess.routineNeedsPro(saving: .brief, replacing: nil))
        #expect(ProAccess.routineNeedsPro(saving: .prompt("Anything due?"), replacing: nil))
    }

    @Test("moving or renaming a free routine stays free")
    func editKeepingShape() {
        #expect(!ProAccess.routineNeedsPro(saving: .brief, replacing: .brief))
        let overdue = TaskBody.watcher(rule: .reminders(.overdue), notifyWhenEmpty: false)
        let overdueLoud = TaskBody.watcher(rule: .reminders(.overdue), notifyWhenEmpty: true)
        #expect(!ProAccess.routineNeedsPro(saving: overdueLoud, replacing: overdue))
    }

    @Test("turning a free routine into something else is Custom the long way round")
    func editChangingShape() {
        let overdue = TaskBody.watcher(rule: .reminders(.overdue), notifyWhenEmpty: false)
        #expect(ProAccess.routineNeedsPro(saving: .prompt("What's on?"), replacing: .brief))
        #expect(ProAccess.routineNeedsPro(saving: .watcher(rule: .reminders(.today), notifyWhenEmpty: false), replacing: overdue))
        #expect(ProAccess.routineNeedsPro(saving: .watcher(rule: .events(.tomorrow), notifyWhenEmpty: false), replacing: .brief))
        #expect(ProAccess.routineNeedsPro(saving: .brief, replacing: overdue))
    }

    @Test("a routine that already needed Pro stays editable")
    func grandfathered() {
        #expect(!ProAccess.routineNeedsPro(saving: .prompt("New words"), replacing: .prompt("Old words")))
        #expect(!ProAccess.routineNeedsPro(saving: .brief, replacing: .prompt("Old words")))
    }

    // MARK: - Brains

    @Test("the recommended brain, the built-in brain and anything on the phone are free")
    func freeBrains() {
        #expect(!ProAccess.brainNeedsPro(id: "qwen3-1.7b", recommendedID: "qwen3-1.7b", onPhone: []))
        #expect(!ProAccess.brainNeedsPro(id: ModelRecord.builtInID, recommendedID: "qwen3-1.7b", onPhone: []))
        #expect(!ProAccess.brainNeedsPro(id: "smollm2-360m", recommendedID: "qwen3-1.7b", onPhone: ["smollm2-360m"]))
    }

    @Test("any other download is Pro, including when nothing is recommended")
    func proBrains() {
        #expect(ProAccess.brainNeedsPro(id: "qwen3-4b", recommendedID: "qwen3-1.7b", onPhone: ["smollm2-360m"]))
        #expect(ProAccess.brainNeedsPro(id: "qwen3-4b", recommendedID: nil, onPhone: []))
        #expect(ProAccess.brainNeedsPro(id: "someone/model:q4", recommendedID: "qwen3-1.7b", onPhone: []))
    }

    // MARK: - Words

    @Test("the sheet lists the three features in order, in the agreed words")
    func featureRows() {
        #expect(ProFeature.allCases == [.laptop, .routines, .brains])
        #expect(ProFeature.laptop.title == "Use from your laptop")
        #expect(ProFeature.laptop.detail == "Chat with Pocketd from a browser on your Wi-Fi.")
        #expect(ProFeature.routines.title == "Every routine")
        #expect(ProFeature.routines.detail == "Evening wrap-ups, weekly reviews and your own.")
        #expect(ProFeature.brains.title == "Any brain")
        #expect(ProFeature.brains.detail == "Choose from more brains, or search for one.")
    }

    @Test("the price button carries the App Store's own price string")
    func unlockTitle() {
        #expect(ProCopy.unlockTitle(displayPrice: "$9.99") == "Unlock for $9.99")
        #expect(ProCopy.unlockTitle(displayPrice: "9,99 €") == "Unlock for 9,99 €")
        #expect(ProCopy.unlockTitle(displayPrice: "₹899.00") == "Unlock for ₹899.00")
        #expect(ProCopy.unlockTitle(displayPrice: nil) == "Unlock Pro")
        #expect(ProCopy.unlockTitle(displayPrice: "") == "Unlock Pro")
    }

    @Test("the You row says which kind of on")
    func rowState() {
        #expect(ProCopy.rowState(.locked) == "Unlock")
        #expect(ProCopy.rowState(.purchased) == "On")
        #expect(ProCopy.rowState(.earlySupporter) == "On — thanks for being early")
    }

    @Test("every sentence is short, plain, and names no other vendor")
    func copyRules() {
        let sentences = [
            ProCopy.name, ProCopy.tagline, ProCopy.restore, ProCopy.notNow, ProCopy.footer,
            ProCopy.waitingForApproval, ProCopy.unlocked, ProCopy.nothingToRestore,
            ProCopy.badge, ProCopy.badgeSpoken, ProCopy.unlockTitle(displayPrice: "$9.99"),
        ]
        + ProFeature.allCases.flatMap { [$0.title, $0.detail] }
        + ProFailure.allCases.map(\.sentence)
        + ProEntitlement.allCases.map(ProCopy.rowState)

        for sentence in sentences {
            #expect(sentence.split(whereSeparator: \.isWhitespace).count <= 25, "\(sentence)")
            for banned in ["OpenAI", "ChatGPT", "GPT"] {
                #expect(!sentence.contains(banned), "\(sentence)")
            }
        }
        #expect(ProCopy.unlocked == "Pocketd Pro is on. Thank you.")
        #expect(ProFailure.unavailable.sentence == "Pocketd Pro isn't available right now. Try again later.")
    }

    // MARK: - The StoreKit configuration

    @Test("the Xcode StoreKit configuration sells this product, once")
    func storeKitConfiguration() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketdKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
        let file = repository.appendingPathComponent("App/Resources/Pocketd.storekit")
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
            "App/Resources/Pocketd.storekit must be readable JSON"
        )
        let products = try #require(json["products"] as? [[String: Any]])
        #expect(products.count == 1)
        #expect(products.first?["productID"] as? String == ProAccess.productID)
        #expect(products.first?["type"] as? String == "NonConsumable")
        #expect((json["subscriptionGroups"] as? [Any])?.isEmpty ?? true)
    }
}
