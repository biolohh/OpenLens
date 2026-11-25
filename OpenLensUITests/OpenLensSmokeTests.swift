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

        // Composer of a throw-away session: the web card (+, agent, model, variant, square send),
        // one short prompt, then the session is deleted again.
        try throwawayComposerRoundTrip(in: app, home: home)

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

    /// Creates "zz-smoke-composer", checks the composer card, sends one short prompt, waits for
    /// the answer and deletes the session (context menu on Home). Skipped when the sheet has no
    /// usable workspace, so a server without a default project does not fail the whole run.
    private func throwawayComposerRoundTrip(in app: XCUIApplication, home: XCUIElement) throws {
        // Unique per run so a leftover from an aborted run can never be mistaken for this one.
        let title = "zz-smoke-composer-\(UUID().uuidString.prefix(6))"
        app.buttons["oc.newSession"].tap()
        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 10), "New session sheet did not open")
        let titleField = app.textFields["Title (optional)"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "No title field")
        titleField.tap()
        titleField.typeText(title)
        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "No Create button")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: create)
        guard XCTWaiter().wait(for: [enabled], timeout: 15) == .completed else {
            XCTFail("Create stayed disabled (no workspace)")
            return
        }
        create.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.session").firstMatch
            .waitForExistence(timeout: 15), "New session did not open")

        let card = app.descendants(matching: .any).matching(identifier: "oc.composer").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Composer card missing")
        XCTAssertTrue(app.buttons["oc.composer.attach"].exists, "Composer + button missing")
        XCTAssertTrue(app.buttons["oc.composer.model"].exists, "Composer model chip missing")
        XCTAssertTrue(app.textViews["Ask anything, / for commands, @ for context..."].exists
            || app.textFields["Ask anything, / for commands, @ for context..."].exists, "Web placeholder missing")
        XCTAssertFalse(app.buttons["session-summary"].exists, "Old summary chip must be gone")
        snapshot("03e-composer-card")

        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        // "/" opens the command list, "@" the context picker with the repository files.
        field.typeText("/")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.slashPicker").firstMatch
            .waitForExistence(timeout: 8), "Slash command picker did not open")
        snapshot("03e2-composer-slash")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("@")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.mentionPicker").firstMatch
            .waitForExistence(timeout: 8), "@ context picker did not open")
        XCTAssertTrue(app.buttons["Repository File"].exists, "@ picker has no repository file row")
        snapshot("03e3-composer-mention")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("Reply with the single word ok.")
        snapshot("03f-composer-typed")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "No Send button")
        send.tap()
        let stop = app.buttons["Stop"]
        _ = stop.waitForExistence(timeout: 15)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 240), .completed, "Answer did not finish in 240 s")
        sleep(2)
        snapshot("03g-composer-answered")

        // Back to Home (edge swipe, else the Tabs sheet), then delete every zz-smoke-composer*
        // session: this run's and any leftover of an aborted one.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.003, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        if !app.buttons["oc.projectPicker"].waitForExistence(timeout: 8) {
            app.buttons["oc.menu"].firstMatch.tap()
            let homeRow = app.buttons["oc.menu.chat"]
            if homeRow.waitForExistence(timeout: 5) { homeRow.tap() }
        }
        XCTAssertTrue(app.buttons["oc.projectPicker"].waitForExistence(timeout: 8), "Did not return to Home")
        let prefix = "zz-smoke-composer"
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", prefix))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "Throw-away session not listed on Home")
        var deleted = 0
        while rows.firstMatch.exists, deleted < 6 {
            let row = rows.firstMatch
            row.press(forDuration: 1.2)
            let delete = app.buttons["Delete"]
            guard delete.waitForExistence(timeout: 5) else { break }
            delete.tap()
            let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Delete", prefix)).firstMatch
            guard confirm.waitForExistence(timeout: 5) else { break }
            confirm.tap()
            deleted += 1
            sleep(2)
        }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", prefix)).firstMatch
            .waitForExistence(timeout: 5), "Throw-away session(s) were not deleted")
        XCTAssertTrue(home.waitForExistence(timeout: 10), "Home missing after cleanup")
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
        // New sessions push older ones below the fold of the lazy list: scroll until it is realized.
        var scrolls = 0
        while !row.waitForExistence(timeout: 3), scrolls < 12 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(row.exists, "Session '\(sessionTitle)' is not listed")
        guard row.exists else { return }
        row.tap()
        sleep(3)
        snapshot("03-chat-empty")
        walkSessionScreen(in: app, expectsFileCard: sessionTitle.contains("Wondednet"), expectsChanges: sessionTitle.contains("implementer"))

        guard let prompt, !prompt.isEmpty else {
            // The navigation bar is hidden: the interactive edge-swipe back must still work.
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.003, dy: 0.5))
            edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            XCTAssertTrue(app.buttons["oc.projectPicker"].waitForExistence(timeout: 6), "Edge swipe did not return to Home")
            // Back to the top of the list: the later Home steps expect the header row.
            for _ in 0..<(scrolls + 1) { app.swipeDown() }
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
    private func walkSessionScreen(in app: XCUIApplication, expectsFileCard: Bool = false, expectsChanges: Bool = false) {
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
                dismissSheet(in: app, marker: "oc.toolDetail")
            }
            // Edit / Write rows are the web's file card; its chevron opens the diff inline.
            var card = app.buttons["oc.fileCard"].firstMatch
            if !card.exists {
                // The Edit / Write may sit in a later "Used" group: open the others too.
                let groups = app.buttons.matching(identifier: "oc.used")
                for index in 1..<max(groups.count, 1) where groups.element(boundBy: index).exists {
                    groups.element(boundBy: index).tap()
                }
                card = app.buttons["oc.fileCard"].firstMatch
            }
            // The known-edit session must show the file card: no silent pass.
            let cardShown = card.waitForExistence(timeout: 8)
            if expectsFileCard { XCTAssertTrue(cardShown, "No file card in the session that edited files") }
            if cardShown {
                // A card right above the composer sits under its hit area: bring it to the middle.
                var nudges = 0
                while card.frame.maxY > app.frame.height * 0.6, nudges < 4 {
                    app.swipeUp()
                    nudges += 1
                    sleep(1)
                }
                let repinsBefore = repinCount(in: app)
                card.tap()
                sleep(3)
                // The screenshot name carries the numbers: repins before the tap and after 3 s.
                snapshot("03-chat-repins-\(repinsBefore)-\(repinCount(in: app))")
                snapshot("03-chat-used-card-after-tap")
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.diff").firstMatch
                    .waitForExistence(timeout: 8), "File card did not open its diff (card value: \(String(describing: card.value)))")
                snapshot("03-chat-used-card-expanded")
                card.tap()
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
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.changes").firstMatch
            .waitForExistence(timeout: 8), "Changes tab missing")
        sleep(3)
        if app.descendants(matching: .any).matching(identifier: "oc.placeholder").firstMatch.exists {
            // "Create Git repository" must exist, and is never tapped: the smoke project is a real folder.
            XCTAssertTrue(app.buttons["oc.changes.createGit"].waitForExistence(timeout: 5), "No-git state lacks Create Git repository")
            snapshot("03-chat-changes-nogit")
        } else {
            // Same state as the web pair: the "Last turn changes" mode of a git project.
            let mode = app.descendants(matching: .any).matching(identifier: "oc.changes.mode").firstMatch
            if !mode.waitForExistence(timeout: 5) {
                let dump = app.debugDescription.split(separator: "\n").filter { $0.contains("Changes") || $0.contains("changes") || $0.contains("Git") }.prefix(25).joined(separator: " | ")
                XCTFail("Changes mode control not found. Hierarchy: \(dump)")
            }
            if mode.exists {
                mode.tap()
                let turn = app.descendants(matching: .any).matching(identifier: "oc.changes.mode.turn").firstMatch
                XCTAssertTrue(turn.waitForExistence(timeout: 4), "Mode panel did not open")
                XCTAssertTrue(app.buttons["oc.changes.mode.git"].exists, "Mode panel lacks Git changes")
                snapshot("03-chat-changes-modes")
                // Branch changes only exist off the default branch: open it when offered.
                let branch = app.buttons["oc.changes.mode.branch"]
                if branch.exists {
                    branch.tap()
                    sleep(3)
                    snapshot("03-chat-changes-branch")
                    mode.tap()
                    XCTAssertTrue(turn.waitForExistence(timeout: 4), "Mode panel did not reopen")
                }
                turn.tap()
            }
            sleep(3)
            snapshot("03-chat-changes")
            let file = app.buttons["oc.changes.file"].firstMatch
            let fileShown = file.waitForExistence(timeout: 8)
            if expectsChanges { XCTAssertTrue(fileShown, "Changes lists no files for the session that changed files") }
            if fileShown {
                app.buttons["oc.changes.expandAll"].tap()
                sleep(2)
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.diff").firstMatch
                    .waitForExistence(timeout: 8), "Expand all did not show a diff")
                snapshot("03-chat-changes-expanded")
                // Wrap lines off (sideways scroll) and back on: the toggle sits in the mode panel.
                let modeButton = app.descendants(matching: .any).matching(identifier: "oc.changes.mode").firstMatch
                modeButton.tap()
                let wrap = app.buttons["oc.changes.wrap"]
                XCTAssertTrue(wrap.waitForExistence(timeout: 4), "Mode panel lacks the Wrap lines toggle")
                wrap.tap()
                modeButton.tap()
                sleep(1)
                snapshot("03-chat-changes-nowrap")
                modeButton.tap()
                wrap.tap()
                modeButton.tap()
                sleep(1)
                // A line comment: select a diff line, write it, see it in the composer, remove it (never sent).
                let line = app.descendants(matching: .any).matching(identifier: "oc.diff.line").firstMatch
                if line.waitForExistence(timeout: 5) {
                    line.tap()
                    // Like the web, the comment editor opens as soon as a line is selected.
                    let field = app.textFields["oc.changes.comment.field"].exists
                        ? app.textFields["oc.changes.comment.field"] : app.textViews["oc.changes.comment.field"]
                    XCTAssertTrue(field.waitForExistence(timeout: 4), "Comment field missing")
                    field.tap()
                    field.typeText("smoke comment")
                    snapshot("03-chat-changes-comment-editor")
                    app.buttons["oc.changes.comment.submit"].tap()
                    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.changes.comment").firstMatch
                        .waitForExistence(timeout: 4), "Comment was not added")
                    snapshot("03-chat-changes-comment-added")
                    // It waits in the composer of the Session tab as a chip.
                    app.buttons["oc.tab.session"].tap()
                    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.composer.comment").firstMatch
                        .waitForExistence(timeout: 6), "Comment chip missing in the composer")
                    snapshot("03-chat-composer-comment")
                    app.buttons["oc.composer.comment.remove"].firstMatch.tap()
                    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.composer.comment").firstMatch
                        .waitForNonExistence(timeout: 4), "Comment chip was not removed")
                    app.buttons["oc.tab.changes"].tap()
                    _ = app.buttons["oc.changes.file"].firstMatch.waitForExistence(timeout: 6)
                }
                let open = app.buttons["oc.changes.openFile"].firstMatch
                if open.waitForExistence(timeout: 3) {
                    open.tap()
                    XCTAssertTrue(app.buttons["oc.files.tab"].firstMatch.waitForExistence(timeout: 8), "Open file did not show the file")
                    snapshot("03-chat-changes-open-file")
                }
            }
        }
        app.buttons["oc.tab.session"].tap()

        // Files (More... > Files): the project tree, then one file.
        app.buttons["oc.tab.more"].tap()
        XCTAssertTrue(app.buttons["oc.more.files"].waitForExistence(timeout: 5), "More sheet missing Files")
        app.buttons["oc.more.files"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.files").firstMatch
            .waitForExistence(timeout: 8), "Files view missing")
        sleep(1)
        let allFiles = app.buttons["oc.files.all"]
        if allFiles.exists { allFiles.tap() }
        XCTAssertTrue(app.buttons["oc.files.row"].firstMatch.waitForExistence(timeout: 10), "File tree is empty")
        snapshot("03-chat-files")
        // Typed filter (server-side name search): rows narrow, the clear button restores the tree.
        let filter = app.textFields["oc.files.filter"]
        if filter.exists {
            filter.tap()
            filter.typeText("a")
            sleep(3)
            snapshot("03-chat-files-filter")
            XCTAssertTrue(app.buttons["oc.files.row"].firstMatch.exists || app.staticTexts["No results"].exists, "Filter shows neither results nor No results")
            filter.typeText(XCUIKeyboardKey.delete.rawValue)
            sleep(2)
        }
        let rows = app.buttons.matching(identifier: "oc.files.row")
        let folder = rows.matching(NSPredicate(format: "value == 'collapsed'")).firstMatch
        if folder.exists {
            folder.tap()
            sleep(2)
            snapshot("03-chat-files-expanded")
        }
        let fileRow = rows.matching(NSPredicate(format: "value == ''")).firstMatch
        if fileRow.exists {
            fileRow.tap()
            XCTAssertTrue(app.buttons["oc.files.tab"].firstMatch.waitForExistence(timeout: 8), "Tapping a file did not open it")
            snapshot("03-chat-files-file")
        }
        app.buttons["oc.tab.session"].tap()

        walkTerminal(in: app)

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

    /// Terminal (More... > Terminal): attaches to the session's terminal (the app creates one when
    /// the session has none), runs `echo openlens-smoke` and `ls`, checks the output came back and
    /// survives a tab switch, then closes only the terminals this run created.
    private func walkTerminal(in app: XCUIApplication) {
        app.buttons["oc.tab.more"].tap()
        let entry = app.buttons["oc.more.terminal"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "More sheet missing Terminal")
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "oc.terminal").firstMatch
            .waitForExistence(timeout: 8), "Terminal view missing")
        XCTAssertTrue(app.buttons["oc.terminal.tab"].firstMatch.waitForExistence(timeout: 15), "No terminal tab")
        // Whatever happens below, close what this run created; terminals that already existed stay.
        defer { closeOwnTerminals(in: app) }
        // Type only into a terminal this run created: a terminal that already existed may be
        // someone's, in another folder or inside a program. If the app reused one, open a new one.
        let ownSelected = app.buttons.matching(NSPredicate(
            format: "identifier == 'oc.terminal.tab' AND value == 'new' AND selected == true"
        )).firstMatch
        if !ownSelected.waitForExistence(timeout: 3) {
            app.buttons["oc.terminal.new"].tap()
        }
        guard ownSelected.waitForExistence(timeout: 15) else {
            XCTFail("No terminal created by this run is selected; not typing into someone else's terminal")
            return
        }
        // The prompt is on screen once the replay arrived.
        let prompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '$'")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "No shell prompt in the terminal")
        snapshot("03-chat-terminal")

        let screen = app.descendants(matching: .any).matching(identifier: "oc.terminal.screen").firstMatch
        XCTAssertTrue(screen.exists, "Terminal screen missing")
        screen.tap()
        sleep(1)
        app.typeText("echo openlens-smoke\n")
        // The echoed command line also contains the word: only a line that is exactly the
        // output proves the round trip.
        let output = app.staticTexts["openlens-smoke"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10), "echo output did not come back from the terminal")
        app.typeText("ls\n")
        sleep(2)
        snapshot("03-chat-terminal-ls")
        XCTAssertTrue(app.buttons["oc.terminal.key.esc"].exists, "Key bar missing")
        XCTAssertTrue(app.buttons["oc.terminal.key.ctrl"].exists, "Key bar Ctrl missing")
        // Hide the keyboard, so the tab row is free.
        let keyboardToggle = app.buttons["oc.terminal.key.keyboard"]
        if keyboardToggle.exists { keyboardToggle.tap() }
        sleep(1)

        // Survives a tab switch: same attachment, the output is still there.
        app.buttons["oc.tab.session"].tap()
        sleep(1)
        app.buttons["oc.tab.more"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "More sheet missing Terminal")
        entry.tap()
        XCTAssertTrue(app.staticTexts["openlens-smoke"].firstMatch.waitForExistence(timeout: 8),
                      "Terminal output lost after switching tabs")
    }

    /// Closes the terminals this run created (value `new`), from wherever `walkTerminal` stopped.
    private func closeOwnTerminals(in app: XCUIApplication) {
        let terminal = app.descendants(matching: .any).matching(identifier: "oc.terminal").firstMatch
        if !terminal.exists {
            app.buttons["oc.tab.more"].tap()
            let entry = app.buttons["oc.more.terminal"]
            if entry.waitForExistence(timeout: 5) { entry.tap() }
            _ = terminal.waitForExistence(timeout: 8)
        }
        let keyboardToggle = app.buttons["oc.terminal.key.keyboard"]
        if app.keyboards.count > 0, keyboardToggle.exists { keyboardToggle.tap() }
        let created = app.buttons.matching(NSPredicate(format: "identifier == 'oc.terminal.close' AND value == 'new'"))
        var guardCount = 0
        while created.firstMatch.waitForExistence(timeout: 2), guardCount < 4 {
            created.firstMatch.tap()
            guardCount += 1
            sleep(2)
        }
        XCTAssertFalse(created.firstMatch.exists, "The terminal the smoke created is still open")
        snapshot("03-chat-terminal-closed")
        app.buttons["oc.tab.session"].tap()
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

    /// Closes a sheet reliably: drags it from its grabber, then taps the dimmed area, until its
    /// marker is gone (a plain swipe sometimes leaves the sheet up and swallows the next tap).
    private func dismissSheet(in app: XCUIApplication, marker: String) {
        let probe = app.descendants(matching: .any).matching(identifier: marker).firstMatch
        for attempt in 0..<4 {
            sleep(1)
            guard probe.exists else { return }
            if attempt % 2 == 0 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            }
        }
        XCTAssertFalse(probe.exists, "Sheet \(marker) did not close")
    }

    /// `ChatStreamInstrumentation.scrollToBottomCount`, read from the debug overlay.
    private func repinCount(in app: XCUIApplication) -> Int {
        let element = app.descendants(matching: .any).matching(identifier: "oc.debug.repins").firstMatch
        return Int(element.label) ?? -1
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
