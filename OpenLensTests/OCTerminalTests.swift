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
        #expect(OCTerminalText.titleNumber("Terminal 2") == 2)
        #expect(OCTerminalText.titleNumber("docker@host: ~") == nil)
        #expect(OCTerminalText.titleNumber("Terminal 02") == nil)
        #expect(OCTerminalText.nextNumber(after: []) == 1)
        #expect(OCTerminalText.nextNumber(after: ["Terminal 1", "bash", "Terminal 3"]) == 2)
    }
}
