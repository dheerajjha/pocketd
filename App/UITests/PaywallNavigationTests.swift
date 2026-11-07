import XCTest

final class PaywallNavigationTests: XCTestCase {
    func testPurchaseSheetHasLegalLinksAndCanBeDismissed() {
        let app = XCUIApplication()
        app.launchArguments = ["-pocketd.skipIntro", "-pocketd.proSheet"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Pocketd Pro"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.links["Terms"].exists || app.buttons["Terms"].exists)
        XCTAssertTrue(app.links["Privacy"].exists || app.buttons["Privacy"].exists)
        XCTAssertTrue(app.buttons["Restore purchase"].exists)
        let dismiss = app.buttons["Not now"]
        XCTAssertTrue(dismiss.isHittable)
        dismiss.tap()
        XCTAssertTrue(app.buttons["You"].waitForExistence(timeout: 10))
    }
}
