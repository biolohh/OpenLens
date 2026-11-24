import Foundation

/// A cell colour as the program asked for it; the view maps it to the theme.
nonisolated enum OCTerminalColor: Hashable, Sendable {
    /// 0–15: the ANSI and bright colours.
    case ansi(Int)
    /// 16–255 of the xterm 256-colour table.
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
}

nonisolated struct OCTerminalStyle: Hashable, Sendable {
    var foreground: OCTerminalColor?
    var background: OCTerminalColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
    /// The cursor sits on this cell.
    var cursor = false

    static let plain = OCTerminalStyle()
}

/// A stretch of one line drawn in one style.
nonisolated struct OCTerminalRun: Hashable, Sendable {
    var text: String
    var style: OCTerminalStyle
}

/// One rendered line; `id` stays the same while the line scrolls into the history.
nonisolated struct OCTerminalLine: Hashable, Sendable, Identifiable {
    let id: Int
    let runs: [OCTerminalRun]

    var text: String { runs.map(\.text).joined() }
}

/// A minimal VT100/xterm screen for line-based shell use: UTF-8, cursor movement, erase, scroll
/// regions, SGR colours (16, 256, RGB), the alternate screen, tab stops, OSC titles, and a capped
/// history. Not thread-safe; `OCTerminalEngine` owns one on its queue.
nonisolated struct OCTerminalEmulator {
    private struct Cell: Equatable {
        var text: String = " "
        var style: OCTerminalStyle = .plain
        /// The right half of a wide character; drawn as nothing.
        var continuation = false
    }

    private enum ParseState {
        case ground
        case escape
        /// ESC followed by an intermediate ( ) * + # %: the next byte is consumed.
        case escapeIntermediate
        case csi
        case osc
        case oscEscape
        /// DCS / SOS / PM / APC: ignored until ST.
        case string
        case stringEscape
    }

    private(set) var cols: Int
    private(set) var rows: Int
    private var screen: [[Cell]]
    private var history: [OCTerminalLine] = []
    private let historyLimit: Int
    /// Id of the first screen row; screen row r has id `firstScreenID + r`.
    private var firstScreenID = 0

    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private var wrapPending = false
    private var pen = OCTerminalStyle.plain
    private var saved: (x: Int, y: Int, pen: OCTerminalStyle) = (0, 0, .plain)
    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabStops: Set<Int>
    private var autowrap = true
    private var mainScreen: (cells: [[Cell]], x: Int, y: Int)?

    private(set) var cursorVisible = true
    /// DECCKM: arrow keys send `ESC O A` instead of `ESC [ A`.
    private(set) var applicationCursorKeys = false
    private(set) var title: String?

    private var state = ParseState.ground
    private var params = ""
    private var oscBuffer: [UInt8] = []
    private var utf8: [UInt8] = []
    private var utf8Needed = 0
    private var lastPrinted: String?

    init(cols: Int = 80, rows: Int = 24, historyLimit: Int = 2000) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.historyLimit = historyLimit
        screen = Array(repeating: Array(repeating: Cell(), count: max(1, cols)), count: max(1, rows))
        scrollBottom = max(1, rows) - 1
        tabStops = Self.defaultTabStops(cols: max(1, cols))
    }

    var alternateScreen: Bool { mainScreen != nil }

    // MARK: Output

    /// The history, then every screen row; trailing blanks in default colours are dropped.
    func lines(showCursor: Bool) -> [OCTerminalLine] {
        history + screenLines(showCursor: showCursor)
    }

    func screenLines(showCursor: Bool) -> [OCTerminalLine] {
        screen.enumerated().map { row, cells in
            let cursorColumn = showCursor && cursorVisible && row == cursorY ? min(cursorX, cols - 1) : nil
            return Self.render(cells, id: firstScreenID + row, cursorColumn: cursorColumn)
        }
    }

    var historyCount: Int { history.count }

    /// Plain text of the screen rows, trailing blanks trimmed (tests, accessibility).
    var screenText: [String] { screenLines(showCursor: false).map(\.text) }

    // MARK: Input

    mutating func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(1, newCols)
        let newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }
        // Rows that no longer fit above the cursor go to the history, like a shell's screen.
        if newRows < rows {
            let overflow = max(0, cursorY - (newRows - 1))
            for _ in 0..<overflow { pushHistory(screen.removeFirst()) }
            screen.removeLast(rows - newRows - overflow)
            cursorY -= overflow
        } else if newRows > rows {
            screen += Array(repeating: Array(repeating: Cell(), count: cols), count: newRows - rows)
        }
        screen = screen.map { row in
            row.count >= newCols ? Array(row.prefix(newCols)) : row + Array(repeating: Cell(), count: newCols - row.count)
        }
        if var main = mainScreen {
            main.cells = main.cells.map { row in
                row.count >= newCols ? Array(row.prefix(newCols)) : row + Array(repeating: Cell(), count: newCols - row.count)
            }
            if main.cells.count > newRows { main.cells.removeFirst(main.cells.count - newRows) }
            while main.cells.count < newRows { main.cells.append(Array(repeating: Cell(), count: newCols)) }
            mainScreen = main
        }
        cols = newCols
        rows = newRows
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Self.defaultTabStops(cols: cols)
        cursorX = min(cursorX, cols - 1)
        cursorY = min(max(0, cursorY), rows - 1)
        wrapPending = false
    }

    /// RIS: clears the screen and modes; the history stays.
    mutating func reset() {
        if mainScreen != nil { exitAlternateScreen() }
        screen = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        cursorX = 0
        cursorY = 0
        wrapPending = false
        pen = .plain
        saved = (0, 0, .plain)
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Self.defaultTabStops(cols: cols)
        autowrap = true
        cursorVisible = true
        applicationCursorKeys = false
        state = .ground
        utf8 = []
        utf8Needed = 0
    }

    mutating func feed(_ data: Data) {
        for byte in data { feed(byte) }
    }

    mutating func feed(_ text: String) { feed(Data(text.utf8)) }

    private mutating func feed(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            escape(byte)
        case .escapeIntermediate:
            state = .ground
        case .csi:
            if byte >= 0x40 && byte <= 0x7e {
                state = .ground
                csi(final: byte)
            } else if byte == 0x1b {
                state = .escape
            } else if byte == 0x18 || byte == 0x1a {
                state = .ground
            } else if byte < 0x20 {
                control(byte)
            } else {
                params.unicodeScalars.append(UnicodeScalar(byte))
            }
        case .osc:
            if byte == 0x07 {
                finishOSC()
            } else if byte == 0x1b {
                state = .oscEscape
            } else if oscBuffer.count < 4096 {
                oscBuffer.append(byte)
            }
        case .oscEscape:
            if byte == 0x5c {
                finishOSC()
            } else {
                state = .escape
                escape(byte)
            }
        case .string:
            if byte == 0x1b { state = .stringEscape } else if byte == 0x07 { state = .ground }
        case .stringEscape:
            state = byte == 0x5c ? .ground : .string
        }
    }

    private mutating func ground(_ byte: UInt8) {
        if utf8Needed > 0 {
            if byte & 0xc0 == 0x80 {
                utf8.append(byte)
                utf8Needed -= 1
                if utf8Needed == 0 {
                    let scalarText = String(decoding: utf8, as: UTF8.self)
                    utf8 = []
                    print(scalarText)
                }
                return
            }
            // A broken sequence: drop it and read this byte afresh.
            utf8 = []
            utf8Needed = 0
            print("\u{FFFD}")
        }
        switch byte {
        case 0x1b:
            state = .escape
        case 0x00..<0x20, 0x7f:
            control(byte)
        case 0x20..<0x80:
            print(String(UnicodeScalar(byte)))
        case 0xc0..<0xe0:
            utf8 = [byte]; utf8Needed = 1
        case 0xe0..<0xf0:
            utf8 = [byte]; utf8Needed = 2
        case 0xf0..<0xf8:
            utf8 = [byte]; utf8Needed = 3
        default:
            print("\u{FFFD}")
        }
    }

    private mutating func control(_ byte: UInt8) {
        switch byte {
        case 0x08: // BS
            cursorX = max(0, min(cursorX, cols - 1) - 1)
            wrapPending = false
        case 0x09: // TAB
            let next = tabStops.filter { $0 > cursorX }.min() ?? (cols - 1)
            cursorX = min(next, cols - 1)
            wrapPending = false
        case 0x0a, 0x0b, 0x0c: // LF VT FF
            lineFeed()
        case 0x0d: // CR
            cursorX = 0
            wrapPending = false
        default:
            break
        }
    }

    private mutating func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case 0x5b: // [
            state = .csi
            params = ""
        case 0x5d: // ]
            state = .osc
            oscBuffer = []
        case 0x50, 0x58, 0x5e, 0x5f: // P X ^ _
            state = .string
        case 0x28, 0x29, 0x2a, 0x2b, 0x23, 0x25: // ( ) * + # %
            state = .escapeIntermediate
        case 0x63: // c
            reset()
        case 0x37: // 7
            saved = (cursorX, cursorY, pen)
        case 0x38: // 8
            restoreCursor()
        case 0x44: // D
            lineFeed()
        case 0x45: // E
            cursorX = 0
            lineFeed()
        case 0x4d: // M
            reverseIndex()
        case 0x48: // H
            tabStops.insert(cursorX)
        default:
            break
        }
    }

    private mutating func finishOSC() {
        state = .ground
        let text = String(decoding: oscBuffer, as: UTF8.self)
        oscBuffer = []
        guard let separator = text.firstIndex(of: ";") else { return }
        let code = text[..<separator]
        if code == "0" || code == "2" {
            title = String(text[text.index(after: separator)...])
        }
    }

    // MARK: Printing

    private mutating func print(_ text: String) {
        guard let scalar = text.unicodeScalars.first else { return }
        // Combining marks join the previous cell.
        if scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark
            || scalar.value == 0x200d || (0xfe00...0xfe0f).contains(scalar.value) {
            let x = wrapPending ? cursorX : max(0, cursorX - 1)
            if screen[cursorY][x].continuation, x > 0 {
                screen[cursorY][x - 1].text += text
            } else {
                screen[cursorY][x].text += text
            }
            return
        }
        let width = Self.width(of: scalar)
        if wrapPending {
            if autowrap {
                cursorX = 0
                lineFeed()
            }
            wrapPending = false
        }
        if width == 2 && cursorX == cols - 1 {
            if autowrap {
                screen[cursorY][cursorX] = Cell(style: pen)
                cursorX = 0
                lineFeed()
            } else {
                return
            }
        }
        var style = pen
        style.cursor = false
        screen[cursorY][cursorX] = Cell(text: text, style: style)
        if width == 2, cursorX + 1 < cols {
            screen[cursorY][cursorX + 1] = Cell(text: "", style: style, continuation: true)
        }
        lastPrinted = text
        let advanced = cursorX + width
        if advanced >= cols {
            cursorX = cols - 1
            wrapPending = true
        } else {
            cursorX = advanced
        }
    }

    private mutating func lineFeed() {
        wrapPending = false
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private mutating func reverseIndex() {
        wrapPending = false
        if cursorY == scrollTop {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    private mutating func scrollUp(_ count: Int) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            let line = screen.remove(at: scrollTop)
            // Only a full-screen scroll on the main screen feeds the history.
            if scrollTop == 0 && mainScreen == nil {
                pushHistory(line)
            }
            screen.insert(blankRow(), at: scrollBottom)
        }
    }

    private mutating func scrollDown(_ count: Int) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(blankRow(), at: scrollTop)
        }
    }

    private mutating func pushHistory(_ row: [Cell]) {
        history.append(Self.render(row, id: firstScreenID, cursorColumn: nil))
        firstScreenID += 1
        if history.count > historyLimit + 200 {
            history.removeFirst(history.count - historyLimit)
        }
    }

    private func blankRow() -> [Cell] {
        Array(repeating: Cell(style: OCTerminalStyle(background: pen.background)), count: cols)
    }

    private func blankCell() -> Cell {
        Cell(style: OCTerminalStyle(background: pen.background))
    }

    // MARK: CSI

    private mutating func csi(final: UInt8) {
        var raw = params
        var marker: Character?
        if let first = raw.first, "?<=>".contains(first) {
            marker = first
            raw.removeFirst()
        }
        // Intermediates (space, !, ", $ …) mark sequences this screen doesn't implement.
        if raw.contains(where: { " !\"#$%&'".contains($0) }) {
            if final == 0x70, raw.hasSuffix("!") { reset() } // DECSTR
            return
        }
        let values = raw.split(separator: ";", omittingEmptySubsequences: false).map { part -> Int in
            Int(part.split(separator: ":").first ?? "") ?? 0
        }
        func arg(_ index: Int, _ fallback: Int = 1) -> Int {
            index < values.count && values[index] > 0 ? values[index] : fallback
        }
        if marker == "?" {
            if final == 0x68 || final == 0x6c { setPrivateModes(values, on: final == 0x68) }
            return
        }
        guard marker == nil else { return }

        switch final {
        case 0x41: moveCursor(y: cursorY - arg(0)) // A
        case 0x42, 0x65: moveCursor(y: cursorY + arg(0)) // B e
        case 0x43, 0x61: moveCursor(x: cursorX + arg(0)) // C a
        case 0x44: moveCursor(x: cursorX - arg(0)) // D
        case 0x45: moveCursor(x: 0, y: cursorY + arg(0)) // E
        case 0x46: moveCursor(x: 0, y: cursorY - arg(0)) // F
        case 0x47, 0x60: moveCursor(x: arg(0) - 1) // G `
        case 0x48, 0x66: moveCursor(x: arg(1) - 1, y: arg(0) - 1) // H f
        case 0x64: moveCursor(y: arg(0) - 1) // d
        case 0x4a: eraseDisplay(values.first ?? 0) // J
        case 0x4b: eraseLine(values.first ?? 0) // K
        case 0x4c: insertLines(arg(0)) // L
        case 0x4d: deleteLines(arg(0)) // M
        case 0x50: deleteChars(arg(0)) // P
        case 0x40: insertChars(arg(0)) // @
        case 0x58: eraseChars(arg(0)) // X
        case 0x53: scrollUp(arg(0)) // S
        case 0x54: scrollDown(arg(0)) // T
        case 0x62: // b: repeat the last character
            if let lastPrinted { for _ in 0..<min(arg(0), cols * rows) { print(lastPrinted) } }
        case 0x6d: sgr(raw) // m
        case 0x72: // r
            let top = arg(0) - 1
            let bottom = arg(1, rows) - 1
            if top < bottom, bottom < rows {
                scrollTop = top
                scrollBottom = bottom
                moveCursor(x: 0, y: 0)
            }
        case 0x73: saved = (cursorX, cursorY, pen) // s
        case 0x75: restoreCursor() // u
        case 0x67: // g
            let mode = values.first ?? 0
            if mode == 0 { tabStops.remove(cursorX) } else if mode == 3 { tabStops.removeAll() }
        case 0x68, 0x6c: // h l (ANSI modes: nothing this screen draws)
            break
        default:
            break
        }
    }

    private mutating func setPrivateModes(_ modes: [Int], on: Bool) {
        for mode in modes {
            switch mode {
            case 1: applicationCursorKeys = on
            case 7: autowrap = on
            case 25: cursorVisible = on
            case 47, 1047, 1049:
                if on { enterAlternateScreen(saveCursor: mode == 1049) } else { exitAlternateScreen() }
            default: break // 2004 bracketed paste, mouse modes, focus events…
            }
        }
    }

    private mutating func enterAlternateScreen(saveCursor: Bool) {
        guard mainScreen == nil else { return }
        mainScreen = (screen, cursorX, cursorY)
        screen = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        if !saveCursor { return }
        cursorX = 0
        cursorY = 0
    }

    private mutating func exitAlternateScreen() {
        guard let main = mainScreen else { return }
        screen = main.cells
        cursorX = min(main.x, cols - 1)
        cursorY = min(main.y, rows - 1)
        mainScreen = nil
        wrapPending = false
    }

    private mutating func restoreCursor() {
        cursorX = min(saved.x, cols - 1)
        cursorY = min(saved.y, rows - 1)
        pen = saved.pen
        wrapPending = false
    }

    private mutating func moveCursor(x: Int? = nil, y: Int? = nil) {
        if let x { cursorX = min(max(0, x), cols - 1) }
        if let y { cursorY = min(max(0, y), rows - 1) }
        wrapPending = false
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for row in (cursorY + 1)..<max(cursorY + 1, rows) { screen[row] = blankRow() }
        case 1:
            eraseLine(1)
            for row in 0..<cursorY { screen[row] = blankRow() }
        case 2, 3:
            for row in 0..<rows { screen[row] = blankRow() }
        default:
            break
        }
        wrapPending = false
    }

    private mutating func eraseLine(_ mode: Int) {
        let range: Range<Int>
        switch mode {
        case 0: range = min(cursorX, cols)..<cols
        case 1: range = 0..<min(cursorX + 1, cols)
        default: range = 0..<cols
        }
        for x in range { screen[cursorY][x] = blankCell() }
        wrapPending = false
    }

    private mutating func insertLines(_ count: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorY + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(blankRow(), at: cursorY)
        }
        cursorX = 0
    }

    private mutating func deleteLines(_ count: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorY + 1) {
            screen.remove(at: cursorY)
            screen.insert(blankRow(), at: scrollBottom)
        }
        cursorX = 0
    }

    private mutating func deleteChars(_ count: Int) {
        let n = min(count, cols - cursorX)
        screen[cursorY].removeSubrange(cursorX..<(cursorX + n))
        screen[cursorY] += Array(repeating: blankCell(), count: n)
        wrapPending = false
    }

    private mutating func insertChars(_ count: Int) {
        let n = min(count, cols - cursorX)
        screen[cursorY].insert(contentsOf: Array(repeating: blankCell(), count: n), at: cursorX)
        screen[cursorY].removeLast(n)
        wrapPending = false
    }

    private mutating func eraseChars(_ count: Int) {
        for x in cursorX..<min(cols, cursorX + count) { screen[cursorY][x] = blankCell() }
        wrapPending = false
    }

    // MARK: SGR

    private mutating func sgr(_ raw: String) {
        let parts = raw.isEmpty ? ["0"] : raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        func next() -> Int? {
            index += 1
            return index < parts.count ? Int(parts[index]) : nil
        }
        while index < parts.count {
            let part = parts[index]
            // Colon form: 38:2::r:g:b / 38:5:n.
            if part.contains(":") {
                let sub = part.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
                if let kind = sub.first ?? nil, kind == 38 || kind == 48 || kind == 58 {
                    var color: OCTerminalColor?
                    if sub.count >= 3, sub[1] == 5, let n = sub[2] { color = Self.indexed(n) }
                    if sub.count >= 5, sub[1] == 2 {
                        let rgb = Array(sub.suffix(3))
                        if let r = rgb[0], let g = rgb[1], let b = rgb[2] {
                            color = .rgb(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
                        }
                    }
                    if kind == 38 { pen.foreground = color } else if kind == 48 { pen.background = color }
                } else if let kind = sub.first ?? nil, kind == 4 {
                    pen.underline = (sub.count > 1 ? sub[1] ?? 1 : 1) != 0
                }
                index += 1
                continue
            }
            let code = Int(part) ?? 0
            switch code {
            case 0: pen = .plain
            case 1: pen.bold = true
            case 2: pen.dim = true
            case 3: pen.italic = true
            case 4: pen.underline = true
            case 7: pen.inverse = true
            case 21, 22: pen.bold = false; pen.dim = false
            case 23: pen.italic = false
            case 24: pen.underline = false
            case 27: pen.inverse = false
            case 30...37: pen.foreground = .ansi(code - 30)
            case 39: pen.foreground = nil
            case 40...47: pen.background = .ansi(code - 40)
            case 49: pen.background = nil
            case 90...97: pen.foreground = .ansi(code - 90 + 8)
            case 100...107: pen.background = .ansi(code - 100 + 8)
            case 38, 48, 58:
                var color: OCTerminalColor?
                switch next() {
                case 5:
                    if let n = next() { color = Self.indexed(n) }
                case 2:
                    if let r = next(), let g = next(), let b = next() {
                        color = .rgb(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
                    }
                default:
                    break
                }
                if code == 38 { pen.foreground = color } else if code == 48 { pen.background = color }
            default:
                break
            }
            index += 1
        }
    }

    private static func indexed(_ n: Int) -> OCTerminalColor {
        let n = min(max(0, n), 255)
        return n < 16 ? .ansi(n) : .indexed(n)
    }

    // MARK: Helpers

    private static func defaultTabStops(cols: Int) -> Set<Int> {
        Set(stride(from: 8, to: cols, by: 8))
    }

    /// 2 for East Asian wide characters and emoji, else 1.
    static func width(of scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x1100 { return 1 }
        if (0x1100...0x115f).contains(v) || (0x2e80...0xa4cf).contains(v) || (0xac00...0xd7a3).contains(v)
            || (0xf900...0xfaff).contains(v) || (0xfe30...0xfe4f).contains(v) || (0xff00...0xff60).contains(v)
            || (0xffe0...0xffe6).contains(v) || (0x1f300...0x1f64f).contains(v) || (0x1f900...0x1f9ff).contains(v)
            || (0x20000...0x3fffd).contains(v) {
            return 2
        }
        return 1
    }

    private static func render(_ cells: [Cell], id: Int, cursorColumn: Int?) -> OCTerminalLine {
        // Trailing blanks without a background are not drawn.
        var end = cells.count
        while end > 0, cells[end - 1].text == " " || cells[end - 1].text.isEmpty,
              cells[end - 1].style.background == nil, !cells[end - 1].style.inverse {
            end -= 1
        }
        if let cursorColumn { end = max(end, cursorColumn + 1) }
        var runs: [OCTerminalRun] = []
        for x in 0..<end {
            let cell = cells[x]
            if cell.continuation { continue }
            var style = cell.style
            style.cursor = x == cursorColumn
            let text = cell.text.isEmpty ? " " : cell.text
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append(OCTerminalRun(text: text, style: style))
            }
        }
        return OCTerminalLine(id: id, runs: runs)
    }
}

/// Owns an emulator on a serial queue, so output is parsed off the main actor in arrival order,
/// and hands throttled snapshots of the lines to the main actor.
nonisolated final class OCTerminalEngine: @unchecked Sendable {
    struct Snapshot: Sendable {
        var lines: [OCTerminalLine]
        var cols: Int
        var rows: Int
        var title: String?
        var applicationCursorKeys: Bool
        var generation: Int
    }

    private let queue = DispatchQueue(label: "openlens.terminal.engine", qos: .userInitiated)
    private var emulator = OCTerminalEmulator()
    private var showCursor = true
    private var scheduled = false
    private var generation = 0
    private let publish: @MainActor @Sendable (Snapshot) -> Void

    /// `publish` runs on the main actor, at most about every 30 ms.
    init(publish: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        self.publish = publish
    }

    func write(_ data: Data) {
        queue.async { [self] in
            emulator.feed(data)
            schedule()
        }
    }

    /// A canonical size from the server, optionally after a reset and with a checkpoint redrawing the screen.
    func resize(cols: Int, rows: Int, reset: Bool = false, checkpoint: Data? = nil) {
        queue.async { [self] in
            if reset { emulator.reset() }
            emulator.resize(cols: cols, rows: rows)
            if let checkpoint { emulator.feed(checkpoint) }
            schedule()
        }
    }

    func setCursorShown(_ shown: Bool) {
        queue.async { [self] in
            showCursor = shown
            schedule()
        }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + 0.03) { [self] in
            scheduled = false
            generation += 1
            let snapshot = Snapshot(
                lines: emulator.lines(showCursor: showCursor),
                cols: emulator.cols,
                rows: emulator.rows,
                title: emulator.title,
                applicationCursorKeys: emulator.applicationCursorKeys,
                generation: generation
            )
            let publish = self.publish
            Task { @MainActor in publish(snapshot) }
        }
    }
}
