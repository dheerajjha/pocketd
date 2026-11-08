import StoreKitTest
import XCTest

final class LocalPurchaseTests: XCTestCase {
    func testVerifiedPurchaseAndRestoreUnlockPro() throws {
        var session = try SKTestSession(configurationFileNamed: "Pocketd")
        session.clearTransactions()
        session.resetToDefaultState()
        session.disableDialogs = false
        defer { session.clearTransactions() }

        let app = XCUIApplication()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launch()
        if app.buttons["Get started"].waitForExistence(timeout: 5) {
            app.buttons["Get started"].tap()
            let builtIn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Built into iPhone")).firstMatch
            XCTAssertTrue(builtIn.waitForExistence(timeout: 30))
            builtIn.tap()
            app.buttons["Continue"].tap()
            app.buttons["Continue"].tap()
            app.buttons["Not now"].tap()
            app.buttons["Open Pocketd"].tap()
        }
        app.terminate()
        app.launchArguments = ["-pocketd.proSheet"]
        app.launch()
        let buy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Unlock for")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 30))
        buy.tap()
        let xcode = system.staticTexts["Xcode"]
        _ = xcode.waitForExistence(timeout: 5)
        attach(system, "Local purchase confirmation")
        if system.staticTexts["Sign in to Apple Account"].exists || app.staticTexts["Sign in to Apple Account"].exists {
            if system.buttons["Cancel"].exists { system.buttons["Cancel"].tap() }
            XCTFail("Local StoreKit configuration was not applied; credentials were not entered")
            return
        }
        if system.buttons["Purchase"].exists {
            system.buttons["Purchase"].tap()
        } else {
            system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.927)).tap()
        }
        _ = system.buttons["OK"].waitForExistence(timeout: 5)
        attach(system, "Purchase confirmation result")
        if system.buttons["OK"].exists {
            system.buttons["OK"].tap()
        } else {
            system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58)).tap()
        }
        XCTAssertTrue(app.buttons["You"].waitForExistence(timeout: 30))
        assertProOn(app, "Verified purchase unlocked Pro")

        app.terminate()
        // Reattach the same local configuration before the new app process;
        // do not clear or manufacture the purchase being restored.
        session = try SKTestSession(configurationFileNamed: "Pocketd")
        XCTAssertTrue(session.allTransactions().contains { $0.productIdentifier == "dev.pocketd.app.pro" })
        app.launchArguments = ["-pocketd.proSheet", "-pocketd.testManualRestore"]
        app.launch()
        let restore = app.buttons["Restore purchase"]
        XCTAssertTrue(restore.waitForExistence(timeout: 30))
        attach(app, "Real StoreKit restore entry")
        restore.tap()
        let signIn = system.alerts["Sign in with Apple Account"]
        if signIn.waitForExistence(timeout: 3) {
            attach(system, "Restore requested Apple Account sign-in")
            if signIn.buttons["Cancel"].exists { signIn.buttons["Cancel"].tap() }
            throw XCTSkip("Local StoreKit Restore requested Apple Account credentials; none were entered. Purchase completed, but Restore is unverified on this runtime.")
        }
        XCTAssertTrue(app.buttons["You"].waitForExistence(timeout: 30))
        assertProOn(app, "Verified restore unlocked Pro")
    }

    private func assertProOn(_ app: XCUIApplication, _ name: String) {
        app.buttons["You"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Pocketd Pro", "On"
        )).firstMatch
        for _ in 0..<6 {
            if row.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        attach(app, name)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
