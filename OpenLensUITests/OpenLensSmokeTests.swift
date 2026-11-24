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

        // The web-style home replaces the tab bar: wait for it by identifier.
        let home = app.descendants(matching: .any).matching(identifier: "oc.home").firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 45), "No home screen after connecting: connection failed?")
        XCTAssertEqual(app.tabBars.count, 0, "The tab bar must be gone")
        sleep(3)
        snapshot("02-sessions")

        if let title = environment["OPENLENS_SMOKE_SESSION_TITLE"], !title.isEmpty {
            try chatRoundTrip(in: app, sessionTitle: title, prompt: environment["OPENLENS_SMOKE_PROMPT"])
            // Back to the home root: the chat is pushed on top of it; the web has no back
            // button, Home is reached from the header's Tabs sheet.
            if !app.buttons["oc.projectPicker"].exists {
                app.buttons["oc.menu"].firstMatch.tap()
                let homeRow = app.buttons["oc.menu.chat"]
                XCTAssertTrue(homeRow.waitForExistence(timeout: 5), "Home row missing in Tabs sheet")
                homeRow.tap()
                sleep(2)
            }
        }

        // Project picker and search, as on the web home.
        let picker = app.buttons["oc.projectPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Project picker missing")
        picker.tap()
        sleep(1)
        snapshot("02b-project-picker")
        let all = app.buttons["oc.project.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5), "'All projects' row missing")
        all.tap()

        let search = app.textFields["oc.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Search field missing")
        search.tap()
        search.typeText("a")
        sleep(1)
        snapshot("02c-search")
        let resultsHeader = app.staticTexts["Sessions"]
        XCTAssertTrue(resultsHeader.waitForExistence(timeout: 5), "Search results panel missing")
        // Typing a nonsense query must yield the empty result state.
        search.typeText("zzqxj")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 5), "Nonsense query still shows results")
        let clear = app.buttons["Dismiss"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "Search clear button missing")
        clear.tap()
        XCTAssertFalse(app.staticTexts["No results"].exists, "Results panel did not close after clearing")
        app.swipeDown()

        // New session opens the existing new-session flow; dismiss without creating anything.
        let newSession = app.buttons["oc.newSession"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "New session button missing")
        newSession.tap()
        let sheetTitle = app.navigationBars["New Session"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10), "New session sheet did not open")
        snapshot("02d-new-session-sheet")
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Sheet has no dismiss button")
        dismiss.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "Home did not come back after dismissing the sheet")

        // Every former tab screen is reachable from the header menu.
        let destinations: [(id: String, shot: String)] = [
            ("review", "04-review"), ("workspace", "05-workspace"),
            ("micro", "06-micro"), ("settings", "07-settings"),
        ]
        for destination in destinations {
            let menu = app.buttons["oc.menu"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "Menu button missing before \(destination.id)")
            menu.tap()
            let row = app.buttons["oc.menu.\(destination.id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Menu row \(destination.id) missing")
            if destination.id == "review" { snapshot("03b-menu-sheet") }
            row.tap()
            sleep(3)
            snapshot(destination.shot)
        }
        // Back home.
        app.buttons["oc.menu"].firstMatch.tap()
        let homeRow = app.buttons["oc.menu.chat"]
        if homeRow.waitForExistence(timeout: 5) { homeRow.tap() }
        XCTAssertTrue(home.waitForExistence(timeout: 10), "Home did not come back")
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
        walkSessionScreen(in: app)

        guard let prompt, !prompt.isEmpty else {
            // The navigation bar is hidden: the interactive edge-swipe back must still work.
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.003, dy: 0.5))
            edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            XCTAssertTrue(app.buttons["oc.projectPicker"].waitForExistence(timeout: 6), "Edge swipe did not return to Home")
            return
        }
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

    }

    /// The web-style session screen: header, Session | Changes | More... tabs, the "Used N" group.
    private func walkSessionScreen(in app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.session").firstMatch
            .waitForExistence(timeout: 10), "Session screen marker missing")
        XCTAssertTrue(app.buttons["oc.tab.session"].exists, "Session tab missing")
        XCTAssertTrue(app.buttons["oc.tab.changes"].exists, "Changes tab missing")
        XCTAssertTrue(app.buttons["oc.tab.more"].exists, "More tab missing")
        XCTAssertEqual(app.navigationBars.count, 0, "No navigation bar in the session screen")

        let used = app.buttons["oc.used"].firstMatch
        if used.waitForExistence(timeout: 10) {
            used.tap()
            sleep(1)
            snapshot("03-chat-used-expanded")
            let line = app.buttons["oc.toolLine"].firstMatch
            if line.waitForExistence(timeout: 5) {
                line.tap()
                sleep(1)
                snapshot("03-chat-tool-line-open")
                app.swipeDown()
                sleep(1)
            }
            used.tap()
        }

        // Rewind asks for confirmation (cancelled here: never revert the real session).
        let bubble = app.staticTexts["vondd vissza"].firstMatch
        if bubble.waitForExistence(timeout: 3) {
            bubble.tap()
            let rewind = app.buttons["oc.rewind"]
            if rewind.waitForExistence(timeout: 3), rewind.isEnabled {
                rewind.tap()
                let confirm = app.buttons["Rewind"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Rewind confirmation missing")
                snapshot("03-chat-rewind-confirm")
                let cancel = app.buttons["Cancel"]
                if cancel.exists { cancel.tap() }
            }
        }

        app.buttons["oc.tab.changes"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.placeholder").firstMatch
            .waitForExistence(timeout: 5), "Changes placeholder missing")
        snapshot("03-chat-changes")
        app.buttons["oc.tab.session"].tap()

        app.buttons["oc.tab.more"].tap()
        XCTAssertTrue(app.buttons["oc.more.files"].waitForExistence(timeout: 5), "More sheet missing Files")
        XCTAssertTrue(app.buttons["oc.more.usage"].exists, "More sheet missing Usage")
        snapshot("03-chat-more")
        // Session details opens after the More sheet finished dismissing.
        app.buttons["oc.more.details"].tap()
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 8), "Session details sheet missing")
        snapshot("03-chat-details")
        app.swipeDown()
        sleep(1)
        app.buttons["oc.tab.session"].tap()
        snapshot("03-chat-session")
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
