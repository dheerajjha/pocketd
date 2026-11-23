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

    func testExplicitOnboardingChoiceAnswersPersistsAndCanSwitchBack() throws {
        let app = launch("available", completedIntro: false, choice: "")
        tap(app.buttons["intro.meet.start"])
        let option = app.buttons[introCloud]
        appears(option)
        XCTAssertFalse(option.isSelected, "Cloud must never be a first-run default")
        XCTAssertFalse(option.label.contains("Recommended"))
        XCTAssertTrue(option.label.localizedCaseInsensitiveContains("internet"))
        let next = app.buttons["intro.brain.continue"]
        let onDevice = app.buttons["intro.brain.builtIn"]
        let localDefaults = [onDevice, app.buttons["intro.brain.download"]].filter { $0.exists && $0.isSelected }
        XCTAssertEqual(localDefaults.count, 1, "The existing local default must remain selected")
        XCTAssertTrue(next.isEnabled, "Continue must still work without tapping the local default")
        // Walk the default path itself where it requires no network. A download
        // default is checked above, but fetching its weights is not part of this test.
        if onDevice.exists && onDevice.isSelected {
            tap(next)
            appears(app.buttons["intro.connect.continue"])
            tap(app.buttons["intro.back"])
            appears(option)
            XCTAssertTrue(onDevice.isSelected)
            XCTAssertFalse(option.isSelected)
        }

        tap(option, scrolling: app)
        XCTAssertTrue(option.isSelected)
        revealForCapture(option, in: app, top: app.buttons["intro.back"].frame.maxY, bottom: next.frame.minY)
        XCTAssertTrue(option.isSelected)
        attach(app, "01-onboarding-cloud-selected")
        tap(next)
        appears(app.staticTexts["Connect your day."])
        tap(app.buttons["intro.connect.continue"]) // No personal-data grant.
        tap(app.buttons["Not now"])  // No notification or scheduled work.
        tap(app.buttons["Open Pocketd"])

        openBrain(app)
        selected(cloud, in: app)
        revealForCapture(element(cloud + ".card", in: app), in: app,
                         top: app.navigationBars.firstMatch.frame.maxY, bottom: app.frame.maxY - 24)
        selected(cloud, in: app)
        attach(app, "02-settings-cloud-selected")
        todayFromBrain(app)
        let first = ask(in: app)
        appears(reply(first, in: app))
        appears(app.buttons["Good answer"]) // Only rendered under a completed assistant turn.
        attach(app, "03-ask-test-cloud-reply")
        let local = ProcessInfo.processInfo.environment["POCKETD_UI_INSTALLED_GGUF"]
        if local != nil { try stageLocalFixture() }

        // No provider or onboarding preference in this launch's arguments.
        // A stale answer restored from history cannot match the next challenge.
        app.terminate()
        let restarted = launch("available")
        openBrain(restarted)
        selected(cloud, in: restarted)
        let useOnDevice = restarted.buttons[builtIn + ".use"]
        if useOnDevice.exists {
            tap(useOnDevice, scrolling: restarted)
            selected(builtIn, in: restarted)
            XCTAssertFalse(element(cloud + ".selection", in: restarted).exists)
        } else {
            XCTAssertNotNil(local, "No on-device Apple option. Run scripts/test-pcc-ui.py to stage the offline GGUF.")
        }
        // The manual CI runner stages genuine llama.cpp weights only after
        // first-run onboarding. Never tap Download to obtain them.
        if let local {
            tap(restarted.buttons["More brains"], scrolling: restarted)
            tap(restarted.buttons["Use \(local)"], scrolling: restarted)
            back(restarted)
            let id = "brain.currentDownload"
            selected(id, in: restarted)
            XCTAssertEqual(element(id + ".title", in: restarted).label, local)
            XCTAssertFalse(element(cloud + ".selection", in: restarted).exists)
            attach(restarted, "Local GGUF selected in Settings")
        }
        restarted.terminate()
        let restored = launch("available") // No preference override: verify the local choice was saved.
        openBrain(restored)
        selected(local == nil ? builtIn : "brain.currentDownload", in: restored)
        XCTAssertFalse(element(cloud + ".selection", in: restored).exists)
        if let local {
            XCTAssertEqual(element("brain.currentDownload.title", in: restored).label, local)
            tap(restored.buttons["More brains"], scrolling: restored)
            let details = restored.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Technical details")).firstMatch
            tap(details, scrolling: restored)
            // Technical details displays a download's identifier only if the
            // real phone engine reports it resident. A saved preference is not enough.
            appears(text(containing: "pcc-ui-local-fixture", in: restored))
            attach(restored, "Actual resident GGUF after restart")
            back(restored)
            back(restored)
        }
        todayFromBrain(restored)
        tap(restored.buttons["Ask about your day"])
        appears(element("ask.composer", in: restored))
        XCTAssertFalse(element("ask.cloud.provider", in: restored).exists)
        tap(restored.buttons["Close"])
        openBrain(restored)
        tap(restored.buttons[cloud + ".use"], scrolling: restored)
        selected(cloud, in: restored)
        XCTAssertFalse(element(builtIn + ".selection", in: restored).exists)
        XCTAssertFalse(element("brain.currentDownload.selection", in: restored).exists)
        todayFromBrain(restored)
        let again = ask(in: restored)
        appears(reply(again, in: restored))
    }

    func testUnsupportedHidesCloudInBothPickers() {
        let app = launch("unsupported", completedIntro: true, choice: "")
        openBrain(app)
        appears(element(download + ".title", in: app)) // The local picker actually rendered.
        XCTAssertFalse(element(cloud + ".card", in: app).exists)
        XCTAssertFalse(app.buttons[cloud + ".use"].exists)

        back(app)
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

    /// The host prepares the GGUF in the disposable app's sandbox. Signal
    /// from the runner's own Documents after the genuine first-run flow, and
    /// wait for the manifest before relaunching. No app-side seeding hook.
    private func stageLocalFixture() throws {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try Data().write(to: documents.appendingPathComponent("pcc-ui-stage-request"), options: .withoutOverwriting)
        let ready = documents.appendingPathComponent("pcc-ui-stage-ready")
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: ready.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 20), .completed, "The host did not install the test weights")
    }

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
        XCTAssertTrue(badge.isSelected)
    }

    private func back(_ app: XCUIApplication) {
        tap(app.navigationBars.buttons.element(boundBy: 0))
    }

    private func todayFromBrain(_ app: XCUIApplication) {
        back(app)
        appears(app.buttons["settings.brain.open"])
        back(app)
        appears(app.buttons["Ask about your day"])
    }

    /// A fresh conversation per assertion, plus a new challenge. Restoring a
    /// previous transcript or displaying a user bubble cannot pass as routing.
    private func ask(in app: XCUIApplication) -> String {
        tap(app.buttons["Ask about your day"])
        let field = element("ask.composer", in: app)
        appears(field)
        appears(element("ask.cloud.provider", in: app))
        let new = app.buttons["New conversation"]
        if new.isEnabled { tap(new) }
        let nonce = String(Int.random(in: 10_000_000...99_999_999))
        XCTAssertFalse(reply(nonce, in: app).exists)
        tap(field)
        field.typeText(nonce)
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

    /// Hittable can mean only a sliver of a card is visible. Frame the whole
    /// card between the actual navigation bar and pinned footer before capture.
    private func revealForCapture(_ card: XCUIElement, in app: XCUIApplication, top: CGFloat, bottom: CGFloat) {
        appears(card)
        let viewport = app.frame
        for _ in 0..<4 {
            let frame = card.frame
            if !frame.isEmpty, frame.minY >= top - 2, frame.maxY <= bottom + 2 { return }
            let up = frame.maxY > bottom
            let distance = min(max(50, up ? frame.maxY - bottom + 12 : top - frame.minY + 12), (bottom - top) / 2)
            let delta = up ? distance : -distance
            let middle = (top + bottom) / 2 - viewport.minY
            func point(_ y: CGFloat) -> XCUICoordinate {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y / viewport.height))
            }
            point(middle + delta / 2).press(forDuration: 0.05, thenDragTo: point(middle - delta / 2),
                                           withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        let frame = card.frame
        XCTAssertTrue(!frame.isEmpty && frame.minY >= top - 2 && frame.maxY <= bottom + 2,
                      "Selected card is clipped: \(frame), visible y=\(top)...\(bottom)")
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
#endif
