#if DEBUG && targetEnvironment(simulator)
import XCTest

@MainActor
final class ShortcutCloudHandoffTests: XCTestCase {
    func testPreOnboardingShortcutStaysEditableAndFreshAuthorizedShortcutAnswers() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let challenge = Int.random(in: 10_000_000...99_999_998)
        let original = String(challenge), fresh = String(challenge + 1)
        let fixture = ["-pocketd.testPCC", "available", "-pocketd.proOverride", "off", "-pocketd.proOffer", "unavailable",
                       "-pocketd.analyticsConsent", "refused", "-pocketd.serverShouldRun", "NO",
                       "-pocketd.calendarTools", "NO", "-pocketd.reminderTools", "NO", "-pocketd.healthTools", "NO"]
        // Deliver the first question at cold launch, before choosing a provider.
        app.launchArguments = fixture + ["-pocketd.completedOnboarding", "NO", "-pocketd.brainChoice", "",
                                         "-pocketd.loadedModel", "", "-pocketd.siriAsk", original]
        app.launch()

        func tap(_ name: String) {
            let button = app.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 12))
            XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 12))
            button.tap()
        }
        func reply(_ nonce: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@", "PCC test fixture replied to probe \(nonce)."
            )).firstMatch
        }
        func assertCloudDisclosure() {
            let provider = app.descendants(matching: .any).matching(identifier: "ask.cloud.provider").firstMatch
            XCTAssertTrue(provider.waitForExistence(timeout: 12))
            XCTAssertEqual(provider.label, "Selected: Apple Private Cloud Compute")
            XCTAssertFalse(provider.frame.intersection(app.frame).isEmpty, "The selected provider must be on screen")
        }

        tap("intro.meet.start")
        PCCPickerUI.selectCloudRow(in: app)
        tap("intro.brain.continue")
        tap("intro.connect.continue")
        tap("Not now")
        tap("Open Pocketd")
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND value == %@", "ask.composer", original
        )).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 12))
        XCTAssertTrue(field.isEnabled)
        XCTAssertEqual(field.value as? String, original)
        assertCloudDisclosure()
        XCTAssertFalse(reply(original).exists)

        // The preference and draft are now real persisted values. Only the
        // *new* invocation authorizes an automatic Send on the next launch.
        app.terminate()
        app.launchArguments = fixture + ["-pocketd.siriAsk", fresh]
        app.launch()
        XCTAssertTrue(reply(fresh).waitForExistence(timeout: 12))
        assertCloudDisclosure()
        XCTAssertFalse(reply(original).exists)
    }
}
#endif
