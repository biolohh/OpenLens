import Foundation
import Testing
@testable import OpenLens

struct OCTerminalEmulatorTests {
    @Test func plainOutputWrapsAndScrollsIntoTheHistory() {
        var term = OCTerminalEmulator(cols: 5, rows: 2)
        term.feed("abcdefg\r\nxy\r\nz")
        #expect(term.screenText == ["xy", "z"])
        #expect(term.lines(showCursor: false).map(\.text) == ["abcde", "fg", "xy", "z"])
        #expect(term.historyCount == 2)
    }

    @Test func historyIdsStayStableWhileLinesScroll() {
        var term = OCTerminalEmulator(cols: 10, rows: 2)
        term.feed("one\r\ntwo")
        let before = term.lines(showCursor: false)
        term.feed("\r\nthree")
        let after = term.lines(showCursor: false)
        #expect(before.map(\.id) == [0, 1])
        #expect(after.map(\.id) == [0, 1, 2])
        #expect(after[0].text == "one")
    }

    @Test func bashPromptColoursAndTitleAreParsed() {
        var term = OCTerminalEmulator(cols: 40, rows: 3)
        let prompt = "\u{1b}]0;docker@host: ~\u{07}\u{1b}[01;32mdocker@host\u{1b}[00m:\u{1b}[01;34m~\u{1b}[00m$ "
        term.feed("\u{1b}[?2004h" + prompt)
        #expect(term.title == "docker@host: ~")
        let line = term.lines(showCursor: false)[0]
        #expect(line.text == "docker@host:~$")
        #expect(line.runs[0] == OCTerminalRun(text: "docker@host", style: OCTerminalStyle(foreground: .ansi(2), bold: true)))
        #expect(line.runs[2].style.foreground == .ansi(4))
        #expect(term.cursorX == 15)
    }

    @Test func echoRoundTripLeavesTheOutputOnItsOwnLine() {
        var term = OCTerminalEmulator(cols: 40, rows: 4)
        term.feed("$ ")
        term.feed("echo openlens-smoke\r\n\u{1b}[?2004l\ropenlens-smoke\r\n\u{1b}[?2004h$ ")
        #expect(term.screenText == ["$ echo openlens-smoke", "openlens-smoke", "$", ""])
    }

    @Test func checkpointWithTabStopsAndCursorPositionRestoresTheScreen() {
        var term = OCTerminalEmulator(cols: 40, rows: 20)
        let checkpoint = "\u{1b}[?2004h\u{1b}[0m\u{1b}[1m\u{1b}[38;5;2mdocker@szupiszerver\u{1b}[0m:\u{1b}[0m\u{1b}[1m\u{1b}[38;5;4m~\u{1b}[0m$ \u{1b}[0m\u{1b}[3g\u{1b}[9G\u{1b}H\u{1b}[17G\u{1b}H\u{1b}[1;24H"
        term.feed(checkpoint)
        #expect(term.screenText[0] == "docker@szupiszerver:~$")
        #expect(term.cursorX == 23)
        #expect(term.cursorY == 0)
        #expect(term.lines(showCursor: false)[0].runs[0].style.foreground == .ansi(2))
    }

    @Test func eraseAndCursorMovesEditTheLine() {
        var term = OCTerminalEmulator(cols: 20, rows: 2)
        term.feed("hello world\r\u{1b}[6C\u{1b}[K")
        #expect(term.screenText[0] == "hello")
        term.feed("\u{08}\u{08}\u{1b}[P")
        #expect(term.screenText[0] == "hell")
        term.feed("\u{1b}[2J\u{1b}[H!")
        #expect(term.screenText == ["!", ""])
    }

    @Test func utf8SplitAcrossChunksStaysOneCharacter() {
        var term = OCTerminalEmulator(cols: 10, rows: 1)
        let bytes = Array("ő✓".utf8)
        term.feed(Data(bytes[0..<1]))
        term.feed(Data(bytes[1..<3]))
        term.feed(Data(bytes[3...]))
        #expect(term.screenText == ["ő✓"])
        #expect(term.cursorX == 2)
    }

    @Test func extendedColoursAndInverse() {
        var term = OCTerminalEmulator(cols: 10, rows: 1)
        term.feed("\u{1b}[38;2;1;2;3;48;5;200;7mX\u{1b}[0m")
        let style = term.lines(showCursor: false)[0].runs[0].style
        #expect(style.foreground == .rgb(1, 2, 3))
        #expect(style.background == .indexed(200))
        #expect(style.inverse)
    }

    @Test func alternateScreenKeepsTheMainScreen() {
        var term = OCTerminalEmulator(cols: 10, rows: 2)
        term.feed("shell")
        term.feed("\u{1b}[?1049h\u{1b}[Hfull\u{1b}[?1h")
        #expect(term.screenText == ["full", ""])
        #expect(term.applicationCursorKeys)
        term.feed("\u{1b}[?1049l\u{1b}[?1l")
        #expect(term.screenText == ["shell", ""])
        #expect(!term.applicationCursorKeys)
    }

    @Test func resetClearsTheScreenAndResizeKeepsTheCursorRow() {
        var term = OCTerminalEmulator(cols: 10, rows: 4)
        term.feed("a\r\nb\r\nc\r\nd")
        term.resize(cols: 6, rows: 2)
        #expect(term.screenText == ["c", "d"])
        #expect(term.cursorY == 1)
        term.reset()
        #expect(term.screenText == ["", ""])
        #expect(term.historyCount == 2)
    }

    @Test func hugeCSIParametersClampInsteadOfTrapping() {
        var term = OCTerminalEmulator(cols: 20, rows: 5)
        term.feed("ab\r\n")
        term.feed("x\u{1b}[9223372036854775807C")
        #expect(term.cursorX == 19)
        term.feed("\u{1b}[9223372036854775807B\u{1b}[9223372036854775807E\u{1b}[9223372036854775807X")
        #expect(term.cursorY == 4)
        // Past Int: unparsable, so the default of 1 applies.
        term.feed("\u{1b}[99999999999999999999999A")
        #expect(term.cursorY == 3)
    }

    @Test func overlongCSISequenceIsDroppedWhole() {
        var term = OCTerminalEmulator(cols: 20, rows: 2)
        term.feed("\u{1b}[" + String(repeating: "1;", count: 400) + "mok")
        #expect(term.screenText[0] == "ok")
        #expect(term.lines(showCursor: false)[0].runs[0].style == .plain)
    }

    @Test func checkpointRestoreDoesNotDuplicateTheHistory() {
        let output = (1...50).map(String.init).joined(separator: "\r\n") + "\r\n$ "
        var term = OCTerminalEmulator(cols: 20, rows: 10)
        term.feed(output)
        let before = term.historyCount
        #expect(before == 41)
        // The server's checkpoint carries the scrollback too; a resize sends it again each time.
        term.restore(cols: 20, rows: 10, checkpoint: Data(output.utf8))
        term.restore(cols: 18, rows: 10, checkpoint: Data(output.utf8))
        #expect(term.historyCount == before)
        #expect(term.screenText.last == "$")
        let ids = term.lines(showCursor: false).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first! > 41)
    }

    @Test func eraseScrollbackClearsTheHistoryOnly() {
        var term = OCTerminalEmulator(cols: 10, rows: 2)
        term.feed("a\r\nb\r\nc")
        #expect(term.historyCount == 1)
        term.feed("\u{1b}[3J")
        #expect(term.historyCount == 0)
        #expect(term.screenText == ["b", "c"])
    }

    @Test func cursorCellIsMarkedWhenShown() {
        var term = OCTerminalEmulator(cols: 10, rows: 1)
        term.feed("ab")
        let runs = term.lines(showCursor: true)[0].runs
        #expect(runs.last == OCTerminalRun(text: " ", style: OCTerminalStyle(cursor: true)))
        term.feed("\u{1b}[?25l")
        #expect(term.lines(showCursor: true)[0].runs.allSatisfy { !$0.style.cursor })
    }
}

struct OCTerminalProtocolTests {
    @Test func framesAreBigEndianWithTheTypeFirst() {
        #expect(OCTerminalProtocol.frame(cols: 300, rows: 40) == Data([0, 0x01, 0x2c, 0x00, 0x28]))
        #expect(OCTerminalProtocol.frame(cols: 42, rows: 37, data: Data("ls\r".utf8))
            == Data([1, 0, 42, 0, 37, 0x6c, 0x73, 0x0d]))
    }

    @Test func socketMessagesDecode() {
        #expect(OCTerminalProtocol.decode(#"{"type":"attached","attachmentID":"a","inputProtocol":1,"info":{"id":"p","size":{"cols":42,"rows":37}},"role":"controller"}"#)
            == .attached(inputProtocol: 1, cols: 42, rows: 37, role: "controller"))
        #expect(OCTerminalProtocol.decode(#"{"type":"replay_complete","endOffset":84}"#) == .replayComplete)
        #expect(OCTerminalProtocol.decode(#"{"type":"resized","cols":40,"rows":20,"generation":2,"checkpoint":"G1tI"}"#)
            == .resized(cols: 40, rows: 20, checkpoint: Data("\u{1b}[H".utf8)))
        #expect(OCTerminalProtocol.decode(#"{"type":"controller_changed","attachmentID":"x","generation":2}"#)
            == .controllerChanged(attachmentID: "x"))
        #expect(OCTerminalProtocol.decode(#"{"type":"exited","exitCode":0}"#) == .exited(code: 0))
        #expect(OCTerminalProtocol.decode(#"{"type":"title_changed","title":"vim"}"#) == .titleChanged("vim"))
        #expect(OCTerminalProtocol.decode(#"{"type":"something_new"}"#) == .other)
        #expect(OCTerminalProtocol.decode("not json") == nil)
    }

    @Test func snapshotCheckpointDecodesFromBase64() throws {
        let json = #"{"data":{"info":{"id":"pty_1","title":"Terminal 1","size":{"cols":80,"rows":24},"output":{"head":0,"tail":165}},"text":"$","checkpoint":"G1s/MjAwNGg=","cursor":{"x":2,"y":0}}}"#
        let snapshot = try OCTerminalClient.decodeSnapshot(Data(json.utf8))
        #expect(snapshot.info.output?.tail == 165)
        #expect(snapshot.checkpoint == Data("\u{1b}[?2004h".utf8))
    }

    @Test func socketRequestCarriesTicketCursorAndAuth() {
        let client = OCTerminalClient(baseURL: URL(string: "http://host:4097")!, authHeader: "Basic abc")
        let request = client.socketRequest(ptyID: "pty_1", ticket: "t", cursor: 7, attachmentID: "a")
        let url = request.url!.absoluteString
        #expect(url.hasPrefix("ws://host:4097/api/experimental/persistent-pty/pty_1/connect?"))
        #expect(url.contains("ticket=t") && url.contains("cursor=7") && url.contains("attachment_id=a"))
        #expect(url.contains("takeover=true") && url.contains("input_protocol=1"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic abc")
    }

    @Test func statusCodesMapLikeTheWeb() {
        #expect(OCTerminalClient.error(status: 503, data: Data(), sessionRoute: true) == .unavailable)
        #expect(OCTerminalClient.error(status: 404, data: Data(), sessionRoute: true) == .outdated)
        #expect(OCTerminalClient.error(status: 405, data: Data(), sessionRoute: true) == .outdated)
        #expect(OCTerminalClient.error(status: 404, data: Data(), sessionRoute: false) == .notFound)
    }
}

struct OCTerminalKeysTests {
    @Test func returnSendsCarriageReturn() {
        #expect(OCTerminalKeys.encode("ls\n", control: false) == Data("ls\r".utf8))
    }

    @Test func controlTurnsLettersIntoControlCodes() {
        #expect(OCTerminalKeys.encode("c", control: true) == Data([0x03]))
        #expect(OCTerminalKeys.encode("D", control: true) == Data([0x04]))
        #expect(OCTerminalKeys.encode("[", control: true) == Data([0x1b]))
        #expect(OCTerminalKeys.encode("ab", control: true) == Data("ab".utf8))
    }

    @Test func arrowsFollowCursorKeyMode() {
        #expect(OCTerminalKeys.sequence(for: .up, applicationCursorKeys: false) == Data("\u{1b}[A".utf8))
        #expect(OCTerminalKeys.sequence(for: .left, applicationCursorKeys: true) == Data("\u{1b}OD".utf8))
        #expect(OCTerminalKeys.sequence(for: .escape, applicationCursorKeys: true) == Data([0x1b]))
        #expect(OCTerminalKeys.sequence(for: .tab, applicationCursorKeys: false) == Data([0x09]))
    }

    @Test func defaultTitlesNumberLikeTheWeb() {
        #expect(OCTerminalTitles.number("Terminal 2") == 2)
        #expect(OCTerminalTitles.number("docker@host: ~") == nil)
        #expect(OCTerminalTitles.number("Terminal 02") == nil)
        #expect(OCTerminalTitles.next(after: []) == 1)
        #expect(OCTerminalTitles.next(after: ["Terminal 1", "bash", "Terminal 3"]) == 2)
    }
}

struct OCTerminalPaletteTests {
    /// One table for both appearances, the web emulator's (ghostty-web) defaults.
    @Test func ansiColoursAreTheWebEmulatorTable() {
        #expect(OCTerminalPalette.rgb(.ansi(1)) == .init(0xcd, 0x31, 0x31))
        #expect(OCTerminalPalette.rgb(.ansi(2)) == .init(0x0d, 0xbc, 0x79))
        #expect(OCTerminalPalette.rgb(.ansi(12)) == .init(0x3b, 0x8e, 0xea))
        #expect(OCTerminalPalette.rgb(.ansi(15)) == .init(0xff, 0xff, 0xff))
        #expect(OCTerminalPalette.ansi.count == 16)
    }

    @Test func the256ColourTableIsXterms() {
        #expect(OCTerminalPalette.rgb(.indexed(196)) == .init(255, 0, 0))
        #expect(OCTerminalPalette.rgb(.indexed(208)) == .init(255, 135, 0))
        #expect(OCTerminalPalette.rgb(.indexed(27)) == .init(0, 95, 255))
        #expect(OCTerminalPalette.rgb(.indexed(232)) == .init(8, 8, 8))
        #expect(OCTerminalPalette.rgb(.indexed(244)) == .init(128, 128, 128))
        #expect(OCTerminalPalette.rgb(.indexed(255)) == .init(238, 238, 238))
        #expect(OCTerminalPalette.rgb(.rgb(1, 2, 3)) == .init(1, 2, 3))
    }
}

struct OCTerminalSelectionTests {
    private func lines(_ texts: [String], cols: Int = 20) -> [OCTerminalLine] {
        var term = OCTerminalEmulator(cols: cols, rows: texts.count)
        term.feed(texts.joined(separator: "\r\n"))
        return term.lines(showCursor: false)
    }

    @Test func selectionAcrossLinesCopiesCellsInReadingOrder() {
        let all = lines(["first line", "second line", "third"])
        // Dragged upwards: head before anchor still reads top to bottom.
        let selection = OCTerminalSelection(
            anchor: OCTerminalPoint(line: all[2].id, column: 2),
            head: OCTerminalPoint(line: all[0].id, column: 6)
        )
        #expect(selection.text(in: all) == "line\nsecond line\nthi")
        #expect(selection.columns(line: all[1].id) == 0...OCTerminalSelection.lineEnd)
        #expect(selection.columns(line: all[0].id) == 6...OCTerminalSelection.lineEnd)
        #expect(selection.columns(line: all[2].id) == 0...2)
    }

    @Test func wideCharactersCountTwoCells() {
        // "a界b": a at 0, 界 at 1–2, b at 3.
        let all = lines(["a界b", "日本x"])
        #expect(all[0].cellStart(2) == 1)
        #expect(all[0].cellStart(3) == 3)
        #expect(all[0].text(columns: 2...3) == "界b")
        let selection = OCTerminalSelection(
            anchor: OCTerminalPoint(line: all[0].id, column: 2),
            head: OCTerminalPoint(line: all[1].id, column: 2)
        )
        #expect(selection.text(in: all) == "界b\n日本")
    }

    @Test func longPressTakesTheWordUnderTheFinger() {
        let line = lines(["ls -la /home/docker"])[0]
        #expect(line.word(at: 9) == 7...18)
        #expect(line.word(at: 2) == nil)
    }

    @Test func quoteTextIsTrimmedLikeTheWeb() {
        #expect(OCTerminalSelection.quoteText("\n\nopenlens-ref\nblack red  \n\n") == "openlens-ref\nblack red")
        let all = lines(["one", "two"])
        let everything = OCTerminalSelection.all(all)
        #expect(everything?.text(in: all) == "one\ntwo")
    }
}

struct OCTerminalQuoteTests {
    @Test func quoteBlockIsTheWebsFormat() {
        var quote = OCDiffComment.terminalQuote(sessionID: "s", text: "openlens-ref\n\nblack red")
        #expect(quote.quoteBlock == "From the terminal:\n> openlens-ref\n>\n> black red")
        quote.text = "why red?"
        #expect(quote.quoteBlock == "From the terminal:\n> openlens-ref\n>\n> black red\n\nwhy red?")
    }

    @Test func quotesLeadThePromptThenTypedTextAndComments() {
        let quote = OCDiffComment.terminalQuote(sessionID: "s", text: "ls output")
        let comment = OCDiffComment(
            id: UUID(), sessionID: "s", file: "a.swift", startLine: 2, endLine: 2, text: "fix", preview: ""
        )
        let prompt = OCDiffCommentStore.composedPrompt(comments: [comment, quote], typed: " look ")
        #expect(prompt == "From the terminal:\n> ls output\n\nlook\nThe user made the following comment regarding line 2 of a.swift: fix")
        #expect(OCDiffCommentStore.composedPrompt(comments: [quote], typed: "") == "From the terminal:\n> ls output")
    }

    @Test @MainActor func quotesStayOutOfTheChangesTabsComments() {
        let store = OCDiffCommentStore()
        store.addQuote(sessionID: "q-test", text: "x")
        #expect(store.comments(sessionID: "q-test").count == 1)
        #expect(store.comments(sessionID: "q-test", file: "").isEmpty)
        let id = store.comments(sessionID: "q-test")[0].id
        store.setQuoteComment(id, text: " note ")
        #expect(store.comments(sessionID: "q-test")[0].text == "note")
        store.remove(id)
        #expect(store.comments(sessionID: "q-test").isEmpty)
    }
}

struct OCTerminalFullScreenTests {
    @Test func alternateScreenHidesTheHistoryAndRestoresIt() {
        var term = OCTerminalEmulator(cols: 10, rows: 3)
        term.feed("a\r\nb\r\nc\r\nd\r\ne")
        #expect(term.historyCount == 2)
        let before = term.lines(showCursor: false).map(\.text)
        term.feed("\u{1b}[?1049h\u{1b}[H\u{1b}[2Jless view")
        #expect(term.lines(showCursor: false).map(\.text) == ["less view", "", ""])
        term.feed("\u{1b}[?1049l")
        #expect(term.historyCount == 2)
        #expect(term.lines(showCursor: false).map(\.text) == before)
    }

    @Test func scrollRegionScrollsOnlyInside() {
        var term = OCTerminalEmulator(cols: 10, rows: 4)
        term.feed("\u{1b}[?1049h\u{1b}[1;1Htop\u{1b}[2;3r\u{1b}[2;1Hx\r\ny\r\nz")
        #expect(term.screenText == ["top", "y", "z", ""])
        #expect(term.historyCount == 0)
    }
}

struct OCTerminalSyncTests {
    @Test func persistentPtyEventsDecode() {
        let added = OCTerminalEvent(type: "persistent-pty.added", data: [
            "sessionID": "ses_1",
            "terminal": ["id": "pty_1", "title": "Terminal 1", "status": "running"],
        ])
        #expect(added?.kind == .added)
        #expect(added?.ptyID == "pty_1")
        #expect(added?.terminal?.title == "Terminal 1")
        let removed = OCTerminalEvent(type: "persistent-pty.removed", data: ["sessionID": "ses_1", "ptyID": "pty_1"])
        #expect(removed == OCTerminalEvent(kind: .removed, sessionID: "ses_1", ptyID: "pty_1", terminal: nil))
        #expect(OCTerminalEvent(type: "persistent-pty.added", data: [:]) == nil)
    }

    /// The events carry no location: with a directory filter they must not count as undecodable.
    @Test func adapterRoutesTerminalEventsAroundTheChat() throws {
        var adapter = V2EventAdapter()
        let envelope: [String: Any] = [
            "type": "persistent-pty.removed", "data": ["sessionID": "ses_1", "ptyID": "pty_1"],
        ]
        #expect(try adapter.event(envelope, directory: "/home/docker") == nil)
    }

    @Test func aChangedEndpointRebuildsTheClient() throws {
        let url = try #require(URL(string: "http://host:4097"))
        let client = OCTerminalClient(baseURL: url, authHeader: "Basic a")
        #expect(OCTerminalStore.endpointChanged(nil, baseURL: url, authHeader: nil))
        #expect(!OCTerminalStore.endpointChanged(client, baseURL: url, authHeader: "Basic a"))
        #expect(OCTerminalStore.endpointChanged(client, baseURL: url, authHeader: "Basic b"))
        #expect(OCTerminalStore.endpointChanged(client, baseURL: try #require(URL(string: "http://other:4097")), authHeader: "Basic a"))
    }

    @Test func notificationIsPostedForTerminalEvents() throws {
        nonisolated final class Box: @unchecked Sendable { var events: [OCTerminalEvent] = [] }
        let box = Box()
        let token = NotificationCenter.default.addObserver(forName: OCTerminalEvent.notification, object: nil, queue: nil) { note in
            if let event = note.userInfo?["event"] as? OCTerminalEvent, event.sessionID == "ses_note" { box.events.append(event) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        var adapter = V2EventAdapter()
        _ = try adapter.event(["type": "persistent-pty.added", "data": [
            "sessionID": "ses_note", "terminal": ["id": "pty_9", "title": "Terminal 1"],
        ]], directory: "/home/docker")
        #expect(box.events.map(\.kind) == [.added])
        #expect(box.events.first?.ptyID == "pty_9")
    }

    @Test func otherEventsWithoutLocationStillThrow() {
        var adapter = V2EventAdapter()
        #expect(throws: (any Error).self) {
            _ = try adapter.event(["type": "session.status", "data": ["sessionID": "ses_1"]], directory: "/home/docker")
        }
    }

    /// The web re-lists terminals on every `server.connected` (first connection and reconnects).
    @Test func streamConnectAsksTheTerminalListsToResync() throws {
        nonisolated final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let token = NotificationCenter.default.addObserver(forName: OCTerminalEvent.resyncNotification, object: nil, queue: nil) { _ in
            box.count += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        var adapter = V2EventAdapter()
        #expect(try adapter.event(["type": "server.connected", "data": [String: Any]()], directory: "/home/docker") != nil)
        _ = try adapter.event(["type": "server.heartbeat", "data": [String: Any]()], directory: "/home/docker")
        #expect(box.count >= 1)
    }

    /// The edge fixed when the drag begins stays through every move, also after the handles swap.
    @Test func handleDragKeepsTheFixedEdgeAfterASwap() {
        let selection = OCTerminalSelection(
            anchor: OCTerminalPoint(line: 5, column: 4), head: OCTerminalPoint(line: 3, column: 2)
        )
        let fixed = selection.fixedPoint(dragging: .start)
        #expect(fixed == OCTerminalPoint(line: 5, column: 4))
        let first = OCTerminalSelection.dragged(fixed: fixed, to: OCTerminalPoint(line: 9, column: 0))
        #expect(first.start == OCTerminalPoint(line: 5, column: 4))
        #expect(first.end == OCTerminalPoint(line: 9, column: 0))
        let second = OCTerminalSelection.dragged(fixed: fixed, to: OCTerminalPoint(line: 9, column: 1))
        #expect(second.start == OCTerminalPoint(line: 5, column: 4))
        #expect(second.end == OCTerminalPoint(line: 9, column: 1))
        // The end handle dragged above the start: the start stays the far edge.
        let endFixed = selection.fixedPoint(dragging: .end)
        let up1 = OCTerminalSelection.dragged(fixed: endFixed, to: OCTerminalPoint(line: 1, column: 0))
        let up2 = OCTerminalSelection.dragged(fixed: endFixed, to: OCTerminalPoint(line: 0, column: 3))
        #expect(up1.end == OCTerminalPoint(line: 3, column: 2))
        #expect(up2.start == OCTerminalPoint(line: 0, column: 3))
        #expect(up2.end == OCTerminalPoint(line: 3, column: 2))
    }

    /// The web's 20 000 limit is a JavaScript length: UTF-16 units.
    @Test func quoteLimitCountsUTF16() {
        #expect(OCTerminalSelection.fitsQuote(String(repeating: "a", count: 20_000)))
        #expect(!OCTerminalSelection.fitsQuote(String(repeating: "😀", count: 10_001)))
        #expect(String(repeating: "😀", count: 10_001).count <= OCTerminalSelection.quoteLimit)
    }

    @Test @MainActor func listFromElsewhereDropsAClosedTerminalAndKeepsTheRest() throws {
        let store = OCTerminalStore(sessionID: "ses_1", directory: nil)
        let one = OCTerminalInfo(id: "pty_1", title: "Terminal 1", cwd: nil, status: nil, sessionID: "ses_1", size: nil, output: nil)
        let two = OCTerminalInfo(id: "pty_2", title: "Terminal 2", cwd: nil, status: nil, sessionID: "ses_1", size: nil, output: nil)
        store.apply([one, two])
        #expect(store.terminals.map(\.id) == ["pty_1", "pty_2"])
        store.apply([two])
        #expect(store.terminals.map(\.id) == ["pty_2"])
        store.apply([])
        #expect(store.terminals.isEmpty)
        #expect(store.activeID == nil)
    }

    /// Rotation and keyboard changes go through the pane size: a landscape pane is more columns,
    /// fewer rows, and the emulator follows the server's new size without losing the history.
    @Test @MainActor func landscapePaneMeansMoreColumns() {
        let metrics = OCTerminalMetrics.current(size: 13)
        let portrait = metrics.cells(in: CGSize(width: 366, height: 600))
        let landscape = metrics.cells(in: CGSize(width: 780, height: 260))
        #expect(landscape.cols > portrait.cols)
        #expect(landscape.rows < portrait.rows)
        var term = OCTerminalEmulator(cols: portrait.cols, rows: portrait.rows)
        term.feed((1...60).map(String.init).joined(separator: "\r\n"))
        let total = term.lines(showCursor: false).count
        term.resize(cols: landscape.cols, rows: landscape.rows)
        #expect(term.cols == landscape.cols)
        #expect(term.lines(showCursor: false).map(\.text).contains("60"))
        #expect(term.lines(showCursor: false).count <= total)
    }
}

/// Answers the terminal REST calls in memory: the list per session, 404 for snapshots (counted).
nonisolated final class OCTerminalStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lists: [String: [[String: Any]]] = [:]
    nonisolated(unsafe) private static var snapshots: [String: Int] = [:]

    static func setList(_ sessionID: String, ids: [String]) {
        lock.withLock { lists[sessionID] = ids.map { ["id": $0, "title": "Terminal"] } }
    }

    static func snapshotCount(_ ptyID: String) -> Int {
        lock.withLock { snapshots[ptyID] ?? 0 }
    }

    static func client() -> OCTerminalClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OCTerminalStubProtocol.self]
        return OCTerminalClient(
            baseURL: URL(string: "http://stub.invalid")!, authHeader: nil, session: URLSession(configuration: configuration)
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let parts = request.url?.path.split(separator: "/").map(String.init) ?? []
        var status = 404
        var body = Data("{}".utf8)
        if parts.count >= 5, parts[2] == "session", parts[4] == "terminal" {
            let items = Self.lock.withLock { Self.lists[parts[3]] ?? [] }
            status = 200
            body = (try? JSONSerialization.data(withJSONObject: ["data": items])) ?? body
        } else if parts.count >= 5, parts[2] == "persistent-pty", parts[4] == "snapshot" {
            Self.lock.withLock { Self.snapshots[parts[3], default: 0] += 1 }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct OCTerminalAttachTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Changes made elsewhere never attach (no takeover of someone else's terminal); the next
    /// visit does.
    @Test func listChangesFromElsewhereNeverAttach() async {
        OCTerminalStubProtocol.setList("ses_f1", ids: ["pty_f1a"])
        let store = OCTerminalStore(sessionID: "ses_f1", directory: nil, client: OCTerminalStubProtocol.client())
        await store.reload()
        #expect(store.phase == .ready)
        #expect(store.connection?.ptyID == "pty_f1a")

        // The shown terminal closed on the web: its neighbour is chosen, not attached.
        let b = OCTerminalInfo(id: "pty_f1b", title: "Terminal 2", cwd: nil, status: nil, sessionID: "ses_f1", size: nil, output: nil)
        store.apply([b])
        #expect(store.connection == nil)
        #expect(store.activeID == "pty_f1b")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(OCTerminalStubProtocol.snapshotCount("pty_f1b") == 0)

        // Closed everywhere, then one opened on the web: listed, not attached.
        store.apply([])
        #expect(store.activeID == nil)
        let c = OCTerminalInfo(id: "pty_f1c", title: "Terminal 1", cwd: nil, status: nil, sessionID: "ses_f1", size: nil, output: nil)
        store.apply([c])
        #expect(store.terminals.map(\.id) == ["pty_f1c"])
        #expect(store.activeID == nil)
        #expect(store.connection == nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(OCTerminalStubProtocol.snapshotCount("pty_f1c") == 0)
    }

    /// A session screen that is not shown (detached) is left alone by background / foreground:
    /// no reattach, so no takeover of a terminal nobody sees.
    @Test func detachedScreenIsNotReattachedOnForeground() async {
        OCTerminalStubProtocol.setList("ses_n2", ids: ["pty_n2"])
        let store = OCTerminalStore(sessionID: "ses_n2", directory: nil, client: OCTerminalStubProtocol.client())
        await store.reload()
        await waitUntil { OCTerminalStubProtocol.snapshotCount("pty_n2") >= 1 }
        try? await Task.sleep(for: .milliseconds(300))
        let before = OCTerminalStubProtocol.snapshotCount("pty_n2")
        store.disconnect()
        #expect(store.detached)
        store.background()
        await store.foreground(apiClient: nil)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(OCTerminalStubProtocol.snapshotCount("pty_n2") == before)
        // A chip tap (select) attaches again and ends the detached state.
        store.select("pty_n2")
        #expect(!store.detached)
    }

    /// Background detaches; the foreground starts one new attachment (one more snapshot).
    @Test func foregroundReattachesOnce() async {
        OCTerminalStubProtocol.setList("ses_fg", ids: ["pty_fg"])
        let store = OCTerminalStore(sessionID: "ses_fg", directory: nil, client: OCTerminalStubProtocol.client())
        await store.reload()
        await waitUntil { OCTerminalStubProtocol.snapshotCount("pty_fg") >= 1 }
        try? await Task.sleep(for: .milliseconds(300))
        let before = OCTerminalStubProtocol.snapshotCount("pty_fg")
        #expect(before == 1)
        store.background()
        await store.foreground(apiClient: nil)
        await waitUntil { OCTerminalStubProtocol.snapshotCount("pty_fg") > before }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(OCTerminalStubProtocol.snapshotCount("pty_fg") == before + 1)
        #expect(store.connection?.ptyID == "pty_fg")
        // Without a background in between, a foreground does nothing.
        await store.foreground(apiClient: nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(OCTerminalStubProtocol.snapshotCount("pty_fg") == before + 1)
    }
}
