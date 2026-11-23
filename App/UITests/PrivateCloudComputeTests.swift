#if DEBUG && targetEnvironment(simulator)
import XCTest

/// Simulator-only UI coverage. The picker, persisted preference, PhoneBrain,
/// composer, stream consumer and failure UI are real; Apple's service is not.
@MainActor
final class PrivateCloudComputeTests: XCTestCase {
    private let cloud = "brain.cloud"
    private let builtIn = "brain.builtIn"
    private let download = "brain.download"
    private let introCloud = "intro.brain.cloud"

    func testExplicitOnboardingChoiceAnswersPersistsAndCanSwitchBack() {
        let app = launch("available", completedIntro: false, choice: "")
        tap(app.buttons["intro.meet.start"])
        let option = app.buttons[introCloud]
        appears(option)
        XCTAssertFalse(option.isSelected, "Cloud must never be a first-run default")
        XCTAssertFalse(option.label.contains("Recommended"))
        XCTAssertTrue(option.label.localizedCaseInsensitiveContains("internet"))
        let next = app.buttons["intro.brain.continue"]
        let onDevice = app.buttons["intro.brain.builtIn"]
        let offeredOnDevice = onDevice.exists
        let localOptions = [onDevice, app.buttons["intro.brain.download"]]
        XCTAssertEqual(localOptions.filter { $0.exists && $0.isSelected }.count, 1, "The existing local default must remain selected")
        XCTAssertTrue(next.isEnabled, "Continue must still work without tapping the local default")
        // Walk the default path itself where it requires no network. A download
        // default is checked above, but fetching its weights is not part of this test.
        if offeredOnDevice && onDevice.isSelected {
            tap(next)
            appears(app.buttons["intro.connect.continue"])
            tap(app.buttons["intro.back"])
            appears(option)
            XCTAssertTrue(onDevice.isSelected)
            XCTAssertFalse(option.isSelected)
        }

        PCCPickerUI.selectCloudRow(in: app)
        XCTAssertFalse(localOptions.contains { $0.exists && $0.isSelected }, "Cloud must be the only selected row")
        attach(app, "01-onboarding-cloud-selected")
        tap(next)
        appears(app.staticTexts["Connect your day."])
        tap(app.buttons["intro.connect.continue"]) // No personal-data grant.
        tap(app.buttons["Not now"])  // No notification or scheduled work.
        tap(app.buttons["Open Pocketd"])

        openBrain(app)
        selected(cloud, in: app)
        let bar = app.navigationBars.firstMatch
        PCCPickerUI.revealCard(element(cloud + ".card", in: app), in: app,
                               top: bar.exists ? bar.frame.maxY : app.scrollViews.firstMatch.frame.minY, bottom: app.frame.maxY - 24)
        selected(cloud, in: app)
        attach(app, "02-settings-cloud-selected")
        todayFromBrain(app)
        let challenge = Int.random(in: 10_000_000...99_999_998)
        let first = ask(in: app, challenge: challenge)
        appears(reply(first, in: app))
        appears(app.buttons["Good answer"]) // Only rendered under a completed assistant turn.
        attach(app, "03-ask-test-cloud-reply")

        // No provider or onboarding preference in this launch's arguments.
        // A stale answer restored from history cannot match the next challenge.
        app.terminate()
        let restarted = launch("available")
        openBrain(restarted)
        selected(cloud, in: restarted)
        if offeredOnDevice || element(builtIn + ".card", in: restarted).exists {
            tap(restarted.buttons[builtIn + ".use"], scrolling: restarted)
            selected(builtIn, in: restarted)
            XCTAssertFalse(element(cloud + ".selection", in: restarted).exists)

            restarted.terminate()
            restarted.launch() // Still no preference override.
            openBrain(restarted)
            selected(builtIn, in: restarted)
            XCTAssertFalse(element(cloud + ".selection", in: restarted).exists)
            checkLocalComposerAndReturnToBrain(restarted)
            chooseCloudInSettings(restarted)
        }
        todayFromBrain(restarted)
        let again = ask(in: restarted, challenge: challenge + 1)
        appears(reply(again, in: restarted))
    }

    func testInstalledDownloadReplacesCloudAndSurvivesRelaunch() throws {
        continueAfterFailure = false
        guard let local = ProcessInfo.processInfo.environment["POCKETD_UI_INSTALLED_GGUF"] else {
            throw XCTSkip("Requires the dedicated simulator with the preinstalled offline GGUF")
        }
        XCTAssertEqual(local, "Local picker test fixture")
        let app = launch("available") // Installed weights are already in this fresh QA container.
        openBrain(app)
        XCTAssertFalse(element(cloud + ".selection", in: app).exists)
        chooseCloudInSettings(app)
        todayFromBrain(app)
        let challenge = Int.random(in: 10_000_000...99_999_998)
        let first = ask(in: app, challenge: challenge)
        appears(reply(first, in: app))

        tap(app.buttons["Close"])
        openBrain(app)
        tap(app.buttons["More brains"], scrolling: app)
        tap(app.buttons["Use \(local)"], scrolling: app) // Only an installed download offers Use.
        back(app, to: element(download + ".title", in: app))
        checkResidentDownload(local, in: app, afterRelaunch: false)
        checkLocalComposerAndReturnToBrain(app)

        app.terminate()
        app.launch() // Same transport fixture, no provider or model preference in the arguments.
        openBrain(app)
        checkResidentDownload(local, in: app, afterRelaunch: true)
        checkLocalComposerAndReturnToBrain(app)
        chooseCloudInSettings(app)
        XCTAssertFalse(element("brain.currentDownload.selection", in: app).exists)
        todayFromBrain(app)
        let again = ask(in: app, challenge: challenge + 1)
        appears(reply(again, in: app))
    }

    func testUnsupportedHidesCloudInBothPickers() {
        let app = launch("unsupported", completedIntro: true, choice: "")
        openBrain(app)
        appears(element(download + ".title", in: app)) // The local picker actually rendered.
        XCTAssertFalse(element(cloud + ".card", in: app).exists)
        XCTAssertFalse(app.buttons[cloud + ".use"].exists)

        back(app, to: app.buttons["settings.brain.open"])
        tap(app.buttons["Replay intro"], scrolling: app)
        tap(app.buttons["intro.meet.start"])
        appears(app.buttons["intro.brain.download"])
        XCTAssertFalse(app.buttons[introCloud].exists)
    }

    func testRealSigningGateCannotOfferCloudFromARestoredPreference() {
        // No -pocketd.testPCC: read this simulator build's actual signing
        // receipt. A restored preference cannot make an unentitled app eligible.
        let app = launch(nil, completedIntro: true, choice: "privateCloudCompute")
        openBrain(app)
        XCTAssertEqual(element(download + ".title", in: app).label, "Private download")
        XCTAssertFalse(element(cloud + ".card", in: app).exists)
        XCTAssertFalse(app.buttons[cloud + ".use"].exists)
        todayFromBrain(app)
        tap(app.buttons["Ask about your day"])
        appears(element("ask.composer", in: app))
        XCTAssertFalse(element("ask.cloud.provider", in: app).exists)
        attach(app, "Actual unentitled QA build: local composer without cloud provider")
        // The composer is inspected only. No question is entered or sent.
    }

    func testNearLimitStillRequiresOptInAndAnswers() {
        let app = launch("near", completedIntro: true, choice: "")
        openBrain(app)
        let status = element(cloud + ".status", in: app)
        appears(status)
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("approaching"))
        XCTAssertFalse(element(cloud + ".selection", in: app).exists)
        tap(app.buttons[cloud + ".use"], scrolling: app)
        selected(cloud, in: app)
        todayFromBrain(app)
        let nonce = ask(in: app)
        appears(reply(nonce, in: app))
    }

    func testLimitKnownBeforeAskingBlocksNewSelectionAndKeepsAnExistingOne() {
        let unchosen = launch("limited", completedIntro: true, choice: "")
        openBrain(unchosen)
        let status = element(cloud + ".status", in: unchosen)
        appears(status)
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("limit reached"))
        let useCloud = unchosen.buttons[cloud + ".use"]
        XCTAssertFalse(useCloud.exists && useCloud.isEnabled, "An exhausted provider can't be newly selected")
        XCTAssertFalse(element(cloud + ".selection", in: unchosen).exists)
        unchosen.terminate()

        let app = launch("limited", completedIntro: true, choice: "privateCloudCompute")
        openBrain(app)
        selected(cloud, label: "Selected", in: app)
        XCTAssertFalse(element(builtIn + ".selection", in: app).exists)
        todayFromBrain(app)
        let nonce = ask(in: app)
        appears(text(containing: "Daily Apple cloud limit reached", in: app))
        XCTAssertEqual(element("ask.composer", in: app).value as? String, nonce, "A preflight-blocked question stays editable")
        XCTAssertFalse(reply(nonce, in: app).exists)
        XCTAssertFalse(app.buttons["Good answer"].exists, "A blocked Ask must not get an answer from a local provider")
        attach(app, "Simulated PCC: limit already reached")
    }

    func testLimitDuringStreamPreservesThePartialFixtureReplyAndReportsQuota() {
        let app = launch("requestLimit", completedIntro: true, choice: "privateCloudCompute")
        let nonce = ask(in: app)
        appears(text(exactly: "PCC test fixture began probe \(nonce).", in: app))
        appears(text(containing: "Private Cloud Compute limit", in: app))
        XCTAssertFalse(reply(nonce, in: app).exists)
        attach(app, "Simulated PCC: limit after first token")
        tap(app.buttons["Close"])
        openBrain(app)
        selected(cloud, label: "Selected", in: app)
        XCTAssertTrue(element(cloud + ".status", in: app).label.localizedCaseInsensitiveContains("limit reached"))
        XCTAssertFalse(element(builtIn + ".selection", in: app).exists)
    }

    func testOfflineDoesNotAnswerFromAnotherProvider() {
        let app = launch("offline", completedIntro: true, choice: "privateCloudCompute")
        let nonce = ask(in: app)
        appears(text(containing: "reach Apple Private Cloud Compute", in: app))
        XCTAssertFalse(reply(nonce, in: app).exists)
        XCTAssertFalse(app.buttons["Good answer"].exists, "Offline before the first token must leave no assistant reply")
        tap(app.buttons["Close"])
        openBrain(app)
        selected(cloud, in: app)
        XCTAssertFalse(element(builtIn + ".selection", in: app).exists)
    }

    // MARK: - Drive the app as the person holding it

    private func launch(_ mode: String?, completedIntro: Bool? = nil, choice: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-pocketd.proOverride", "off", "-pocketd.proOffer", "unavailable",
            "-pocketd.analyticsConsent", "refused", "-pocketd.serverShouldRun", "NO",
            "-pocketd.calendarTools", "NO", "-pocketd.reminderTools", "NO", "-pocketd.healthTools", "NO",
            // A real local row even on a low-memory simulator. Never start its download.
            "-pocketd.introDownload", "smollm2-360m",
        ]
        if let mode { app.launchArguments += ["-pocketd.testPCC", mode] }
        if let completedIntro { app.launchArguments += ["-pocketd.completedOnboarding", completedIntro ? "YES" : "NO"] }
        if let choice { app.launchArguments += ["-pocketd.brainChoice", choice, "-pocketd.loadedModel", ""] }
        app.launch()
        return app
    }

    private func openBrain(_ app: XCUIApplication) {
        tap(app.buttons["You"])
        tap(app.buttons["settings.brain.open"], scrolling: app)
        appears(element(download + ".title", in: app))
    }

    private func selected(_ id: String, label: String = "In use", in app: XCUIApplication) {
        let badge = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label == %@", id + ".selection", label
        )).firstMatch
        appears(badge)
        XCTAssertTrue(badge.wait(for: \.isSelected, toEqual: true, timeout: 12))
    }

    private func chooseCloudInSettings(_ app: XCUIApplication) {
        tap(app.buttons[cloud + ".use"], scrolling: app)
        selected(cloud, in: app)
        XCTAssertFalse(element(builtIn + ".selection", in: app).exists)
    }

    private func checkResidentDownload(_ name: String, in app: XCUIApplication, afterRelaunch: Bool) {
        let current = "brain.currentDownload"
        selected(current, in: app)
        XCTAssertEqual(element(current + ".title", in: app).label, name)
        XCTAssertFalse(element(cloud + ".selection", in: app).exists)
        if !afterRelaunch { attach(app, "Local GGUF selected in Settings") }

        tap(app.buttons["More brains"], scrolling: app)
        let details = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Technical details")).firstMatch
        tap(details, scrolling: app)
        // Only the real phone engine's resident-download branch renders these
        // rows. The catalogue entry and a saved preference cannot supply them.
        let identifier = text(exactly: "Identifier, pcc-ui-local-fixture", in: app)
        XCTAssertTrue(identifier.waitForExistence(timeout: 30), "The preinstalled GGUF never became resident")
        appears(text(exactly: "Brain, \(name)", in: app))
        if afterRelaunch { attach(app, "Actual resident GGUF after restart") }
        back(app, to: details)
        back(app, to: element(download + ".title", in: app))
    }

    private func checkLocalComposerAndReturnToBrain(_ app: XCUIApplication) {
        todayFromBrain(app)
        tap(app.buttons["Ask about your day"])
        appears(element("ask.composer", in: app))
        XCTAssertFalse(element("ask.cloud.provider", in: app).exists)
        tap(app.buttons["Close"])
        openBrain(app)
    }

    private func back(_ app: XCUIApplication, to destination: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // On iPhone Duo, UIKit puts BackButton in the side Toolbar, a sibling
        // of NavigationBar. Its identifier is independent of that layout.
        tap(app.buttons["BackButton"], file: file, line: line)
        appears(destination, file: file, line: line)
    }

    private func todayFromBrain(_ app: XCUIApplication) {
        back(app, to: app.buttons["settings.brain.open"])
        back(app, to: app.buttons["Ask about your day"])
    }

    /// A fresh conversation per assertion, plus a new challenge. Restoring a
    /// previous transcript or displaying a user bubble cannot pass as routing.
    private func ask(in app: XCUIApplication, challenge: Int = Int.random(in: 10_000_000...99_999_999)) -> String {
        tap(app.buttons["Ask about your day"])
        let field = element("ask.composer", in: app)
        appears(field)
        appears(element("ask.cloud.provider", in: app))
        let new = app.buttons["New conversation"]
        if new.isEnabled {
            tap(new)
            XCTAssertTrue(new.wait(for: \.isEnabled, toEqual: false, timeout: 12), "The new conversation did not open")
        }
        let nonce = String(challenge)
        XCTAssertFalse(reply(nonce, in: app).exists)
        tap(field)
        // A draft-only chat can be restored with New conversation disabled
        // (notably after a quota block). Replace it instead of appending a probe.
        if let draft = field.value as? String, !draft.isEmpty, draft != field.placeholderValue {
            field.typeKey("a", modifierFlags: .command)
        }
        field.typeText(nonce)
        XCTAssertEqual(field.value as? String, nonce, "Send only this scenario's challenge")
        tap(app.buttons["ask.send"])
        return nonce
    }

    private func reply(_ nonce: String, in app: XCUIApplication) -> XCUIElement {
        text(exactly: "PCC test fixture replied to probe \(nonce).", in: app)
    }

    private func text(exactly value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", value)).firstMatch
    }

    private func text(containing value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", value)).firstMatch
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func appears(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 12), "Missing \(element)", file: file, line: line)
    }

    private func tap(_ element: XCUIElement, scrolling app: XCUIApplication? = nil, file: StaticString = #filePath, line: UInt = #line) {
        if let app {
            // SwiftUI exposes some off-screen rows but creates others lazily.
            // Select a direction from the frame when possible: switching to a
            // local card after scrolling down to cloud also has to scroll up.
            for _ in 0..<5 where !element.isHittable {
                if element.exists, !element.frame.isEmpty, element.frame.midY < app.frame.midY {
                    app.swipeDown()
                } else {
                    app.swipeUp()
                }
            }
        }
        appears(element, file: file, line: line)
        XCTAssertTrue(element.isHittable, "Cannot tap \(element)", file: file, line: line)
        element.tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(data: app.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        image.name = name + ".png"
        image.lifetime = .keepAlways
        add(image)
    }
}

/// UI gestures shared by the independent picker and cold-Shortcut tests.
@MainActor
enum PCCPickerUI {
    static func selectCloudRow(in app: XCUIApplication) {
        let cloud = app.buttons["intro.brain.cloud"]
        let back = app.buttons["intro.back"]
        let next = app.buttons["intro.brain.continue"]
        XCTAssertTrue(back.waitForExistence(timeout: 12))
        XCTAssertTrue(next.waitForExistence(timeout: 12))
        let top = back.frame.maxY + 8, bottom = next.frame.minY - 12
        // A card under the fixed footer can still be reported hittable.
        revealCard(cloud, in: app, top: top, bottom: bottom)
        XCTAssertTrue(cloud.isEnabled && cloud.isHittable)
        cloud.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(cloud.wait(for: \.isSelected, toEqual: true, timeout: 12), "The visible cloud card did not become selected")
        revealCard(cloud, in: app, top: top, bottom: bottom)
    }

    /// Drag inside the card's content column, clear of the Duo's side toolbar.
    /// A card must fit between the fixed controls, not just intersect the window.
    static func revealCard(_ card: XCUIElement, in app: XCUIApplication, top: CGFloat, bottom: CGFloat) {
        XCTAssertTrue(card.waitForExistence(timeout: 12), "Missing \(card)")
        let viewport = app.frame
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 12))
        let top = max(top, scroll.frame.minY), bottom = min(bottom, scroll.frame.maxY)
        XCTAssertGreaterThan(bottom, top)
        for _ in 0..<6 {
            let frame = card.frame
            if frame.height >= 44, frame.minY >= top - 2, frame.maxY <= bottom + 2 { return }
            let up = frame.isEmpty || frame.maxY > bottom
            let maximum = (bottom - top) / 2
            let distance = frame.isEmpty ? maximum : min(max(50, up ? frame.maxY - bottom + 12 : top - frame.minY + 12), maximum)
            let delta = up ? distance : -distance
            let middle = (top + bottom) / 2 - viewport.minY
            let x = frame.isEmpty ? scroll.frame.midX : frame.midX
            func point(_ y: CGFloat) -> XCUICoordinate {
                app.coordinate(withNormalizedOffset: CGVector(dx: (x - viewport.minX) / viewport.width, dy: y / viewport.height))
            }
            point(middle + delta / 2).press(forDuration: 0.05, thenDragTo: point(middle - delta / 2),
                                           withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        let frame = card.frame
        XCTAssertTrue(frame.height >= 44 && frame.minY >= top - 2 && frame.maxY <= bottom + 2,
                      "Card is clipped: \(frame), visible y=\(top)...\(bottom)")
    }
}
#endif
