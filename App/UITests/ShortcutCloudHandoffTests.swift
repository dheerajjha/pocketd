#if DEBUG && targetEnvironment(simulator)
import XCTest

@MainActor
final class ShortcutCloudHandoffTests: XCTestCase {
    /// Both surfaces go through the real shell, composer and conversation
    /// store. Only inference and Health are fixtures; no permissions needed.
    func testTodayQuestionSeparatesFromMainAndHistoryRestoresExplicitSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-pocketd.testPCC", "available", "-pocketd.brainChoice", "privateCloudCompute",
                               "-pocketd.completedOnboarding", "YES", "-pocketd.demoHealth", "-pocketd.proOverride", "off",
                               "-pocketd.analyticsConsent", "refused", "-pocketd.serverShouldRun", "NO",
                               "-pocketd.calendarTools", "NO", "-pocketd.reminderTools", "NO", "-pocketd.healthTools", "NO"]
        let first = Int.random(in: 10_000_000...99_999_998), amber = String(first), copper = String(first + 1)
        let field = app.descendants(matching: .any).matching(identifier: "ask.composer").firstMatch
        func tap(_ label: String) {
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 10))
            button.tap()
        }
        func reply(_ nonce: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "PCC test fixture replied to probe \(nonce).")).firstMatch
        }
        func send(_ nonce: String) {
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap(); field.typeText(nonce); tap("ask.send")
            XCTAssertTrue(reply(nonce).waitForExistence(timeout: 10))
        }
        func openThreadID() -> String {
            tap("ask.history")
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value BEGINSWITH %@", "ask.history.row.", "Open now")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            let id = row.identifier
            tap("Done")
            return id
        }
        app.launch()
        tap("Ask about your day"); XCTAssertTrue(field.waitForExistence(timeout: 10))
        if app.buttons["ask.new"].isEnabled {
            tap("ask.new")
            XCTAssertTrue(app.buttons["ask.new"].wait(for: \.isEnabled, toEqual: false, timeout: 10))
        }
        send(amber); let mainID = openThreadID(); tap("ask.close")
        tap("How did I sleep?")
        let question = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: How did I sleep?")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10)); XCTAssertFalse(reply(amber).exists)
        send(copper); let sleepID = openThreadID(); XCTAssertNotEqual(mainID, sleepID)
        tap("ask.close"); tap("Ask about your day")
        XCTAssertTrue(reply(amber).waitForExistence(timeout: 10)); XCTAssertFalse(reply(copper).exists)
        XCTAssertEqual(openThreadID(), mainID)
        tap("ask.close"); tap("How did I sleep?"); XCTAssertTrue(reply(copper).waitForExistence(timeout: 10))
        XCTAssertEqual(openThreadID(), sleepID)
        tap("ask.history"); tap(amber); XCTAssertTrue(reply(amber).waitForExistence(timeout: 10))
        app.terminate(); app.launch(); tap("Ask about your day")
        XCTAssertTrue(reply(amber).waitForExistence(timeout: 10)); XCTAssertFalse(reply(copper).exists)
        XCTAssertEqual(openThreadID(), mainID)
    }

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
