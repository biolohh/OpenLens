import XCTest

/// iOS 18 smoke test for the ios18 branch (run with scripts/smoke-ios18.sh).
///
/// Connects the app to a real OpenCode server through the `openlens://connect`
/// deep link and walks the main tabs, attaching a screenshot of every screen so
/// the iOS 18 fallbacks of the Liquid Glass UI can be reviewed. The server is
/// passed in through the environment (xcodebuild forwards `TEST_RUNNER_*`):
///   TEST_RUNNER_OPENLENS_SMOKE_URL   e.g. http://192.168.1.10:4096
///   TEST_RUNNER_OPENLENS_SMOKE_USER  (default: opencode)
///   TEST_RUNNER_OPENLENS_SMOKE_PASS
/// Without a URL the test is skipped.
final class OpenLensSmokeTests: XCTestCase {
    func testConnectAndWalkMainScreens() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let serverURL = environment["OPENLENS_SMOKE_URL"], !serverURL.isEmpty else {
            throw XCTSkip("OPENLENS_SMOKE_URL is not set")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-onboardingCompleted", "YES"]
        app.launch()
        snapshot("01-connect-screen")

        var link = URLComponents()
        link.scheme = "openlens"
        link.host = "connect"
        link.queryItems = [
            URLQueryItem(name: "url", value: serverURL),
            URLQueryItem(name: "user", value: environment["OPENLENS_SMOKE_USER"] ?? "opencode"),
            URLQueryItem(name: "pass", value: environment["OPENLENS_SMOKE_PASS"] ?? ""),
        ]
        app.open(try XCTUnwrap(link.url))
        confirmSystemOpenPromptIfShown()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 45), "No tab bar after connecting: connection failed?")
        sleep(3)
        snapshot("02-sessions")

        if let title = environment["OPENLENS_SMOKE_SESSION_TITLE"], !title.isEmpty {
            try chatRoundTrip(in: app, sessionTitle: title, prompt: environment["OPENLENS_SMOKE_PROMPT"])
        }

        let tabs = tabBar.buttons
        for index in 1..<tabs.count {
            tabs.element(boundBy: index).tap()
            sleep(3)
            snapshot(String(format: "%02d-tab-%d", 3 + index, index))
        }
        tabs.element(boundBy: 0).tap()
    }

    /// Real-UI check of the agent form's Submit state (no server: screenshot fixtures).
    /// The optional boolean shows a required text field; emptying it must disable Submit
    /// and typing again must re-enable it. Guards the iOS 18 toolbar update path.
    func testConditionalFormSubmitFollowsValidity() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments += [
            "-onboardingCompleted", "YES",
            "SCREENSHOT_MODE", "SCREENSHOT_FORM_SHEET", "SCREENSHOT_CONDITIONAL_FORM=optional",
        ]
        app.launch()

        let submit = app.navigationBars.buttons["Submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 30), "Form sheet did not open")
        snapshot("form-1-not-answered")
        XCTAssertTrue(submit.isEnabled, "Optional, unanswered form should be submittable")

        let cases = [("Yes", "Release summary", "Safer agent handoffs"), ("No", "Reason to wait", "Finish verification first")]
        for (segment, title, defaultText) in cases {
            app.segmentedControls.buttons[segment].tap()
            // Matched by placeholder (the field title), which survives editing the value.
            let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", title)).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "\(segment): '\(title)' field missing")
            guard field.exists else { continue }
            XCTAssertEqual(field.value as? String, defaultText, "\(segment): default text not prefilled")
            XCTAssertTrue(submit.isEnabled, "\(segment): defaults are valid, Submit should be enabled")

            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: defaultText.count + 2))
            wait(for: submit, enabled: false, "\(segment): Submit stayed enabled with an empty required field")
            snapshot("form-2-\(segment.lowercased())-empty")

            field.typeText("Okay now")
            wait(for: submit, enabled: true, "\(segment): Submit did not come back after typing")
        }
    }

    private func wait(for element: XCUIElement, enabled: Bool, _ message: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed, message)
    }

    /// Opens the given session, optionally sends one prompt through the composer and
    /// waits for the streamed answer to finish (the Stop button goes away).
    private func chatRoundTrip(in app: XCUIApplication, sessionTitle: String, prompt: String?) throws {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", sessionTitle))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Session '\(sessionTitle)' is not listed")
        guard row.exists else { return }
        row.tap()
        sleep(3)
        snapshot("03-chat-empty")

        guard let prompt, !prompt.isEmpty else { return }
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "No composer")
        composer.tap()
        composer.typeText(prompt)
        snapshot("03b-chat-typing")

        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "No Send button")
        send.tap()

        let stop = app.buttons["Stop"]
        _ = stop.waitForExistence(timeout: 15)
        sleep(2)
        snapshot("03c-chat-streaming")
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 180), .completed, "Answer did not finish in 180 s")
        sleep(2)
        app.swipeDown()
        snapshot("03d-chat-answer")

        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        sleep(1)
    }

    /// iOS asks "Open in OpenLens?" when a URL comes from outside the app.
    private func confirmSystemOpenPromptIfShown() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 4) else { return }
        let buttons = alert.buttons
        // The confirm button is the last one ("Open" / "Megnyitás").
        buttons.element(boundBy: buttons.count - 1).tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
