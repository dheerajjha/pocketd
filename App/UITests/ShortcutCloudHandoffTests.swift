#if DEBUG && targetEnvironment(simulator)
import XCTest

@MainActor
final class ShortcutCloudHandoffTests: XCTestCase {
    func testPreOnboardingShortcutStaysEditableAndFreshAuthorizedShortcutAnswers() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let external = ProcessInfo.processInfo.environment["POCKETD_UI_PRELAUNCHED_SHORTCUT"]
        let original = external.flatMap(Int.init) ?? Int.random(in: 10_000_000...89_999_999)
        let fresh = String(original + 1)
        let fixture = ["-pocketd.testPCC", "available", "-pocketd.proOverride", "off",
                       "-pocketd.analyticsConsent", "refused", "-pocketd.serverShouldRun", "NO",
                       "-pocketd.calendarTools", "NO", "-pocketd.reminderTools", "NO", "-pocketd.healthTools", "NO"]
        if let external {
            XCTAssertEqual(external, String(original))
            XCTAssertTrue([.runningForeground, .runningBackground, .runningBackgroundSuspended].contains(app.state),
                          "The app must already be running from the external Shortcut launch")
            app.activate()
        } else {
            app.launchArguments = fixture + ["-pocketd.completedOnboarding", "NO", "-pocketd.brainChoice", "",
                                             "-pocketd.loadedModel", "", "-pocketd.siriAsk", String(original)]
            app.launch()
        }

        func tap(_ name: String) {
            let button = app.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 12))
            for _ in 0..<4 where !button.isHittable { app.swipeUp() }
            button.tap()
        }
        func reply(_ nonce: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@", "PCC test fixture replied to probe \(nonce)."
            )).firstMatch
        }

        tap("intro.meet.start")
        let cloud = app.buttons["intro.brain.cloud"]
        let next = app.buttons["intro.brain.continue"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 12))
        // The bottom of a hittable card can still lie under the pinned footer.
        for _ in 0..<4 where !cloud.isHittable || cloud.frame.maxY > next.frame.minY - 4 {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(cloud.isHittable && cloud.frame.maxY <= next.frame.minY - 4)
        cloud.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == YES"), object: cloud)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: 8), .completed)
        tap("intro.brain.continue")
        tap("intro.connect.continue")
        tap("Not now")
        tap("Open Pocketd")
        let field = app.descendants(matching: .any).matching(identifier: "ask.composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ask.cloud.provider").firstMatch.exists)
        XCTAssertEqual(field.value as? String, String(original))
        XCTAssertFalse(reply(String(original)).exists)

        // The preference and draft are now real persisted values. Only the
        // *new* invocation authorizes an automatic Send on the next launch.
        app.terminate()
        app.launchArguments = fixture + ["-pocketd.siriAsk", fresh]
        app.launch()
        XCTAssertTrue(reply(fresh).waitForExistence(timeout: 12))
        XCTAssertFalse(reply(String(original)).exists)
    }
}
#endif
