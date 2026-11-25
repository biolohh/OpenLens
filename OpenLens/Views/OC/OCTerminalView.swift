import SwiftUI
import UIKit

/// The web's mobile Terminal view (More... > Terminal): a strip with the session's terminals
/// (title, close) and a new-terminal button, then the live screen with a key bar. Opening it
/// attaches to the session's first terminal, creating one only when the session has none.
struct OCTerminalView: View {
    let store: OCTerminalStore

    @Environment(\.connection) private var connection
    /// The web seeds a terminal on an empty session only in its mobile placement; a regular-width
    /// layout behaves like the desktop panel and waits for `+`.
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            strip
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.terminal")
        }
        .task(id: store.sessionID) {
            await store.appear(
                apiClient: connection.client,
                isV2: connection.serverCapabilities?.protocolVersion == .v2,
                seedsEmpty: sizeClass != .regular
            )
        }
        .alert(
            store.actionError ?? "",
            isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.terminals) { info in
                    chip(info)
                }
                Button {
                    Task { await store.create() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.creating || store.phase != .ready)
                .accessibilityIdentifier("oc.terminal.new")
                .accessibilityLabel(AppText.ocTerminalNew)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.appSeparator).frame(height: 1) }
    }

    private func chip(_ info: OCTerminalInfo) -> some View {
        let selected = info.id == store.activeID
        return HStack(spacing: 6) {
            Button {
                store.select(info.id)
            } label: {
                Text(store.title(for: info))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.appPrimary : Color.appSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.terminal.tab")
            .accessibilityValue(store.createdIDs.contains(info.id) ? "new" : "")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            Button {
                Task { await store.close(info.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.terminal.close")
            .accessibilityLabel(AppText.ocTerminalClose)
            .accessibilityValue(store.createdIDs.contains(info.id) ? "new" : "")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 28)
        .background(selected ? Color.appTertiary : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? Color.appBorder : Color.clear, lineWidth: 0.5)
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            message(AppText.ocTerminalLoading)
        case .unavailable(let text):
            message(text)
        case .failed(let text):
            VStack(spacing: 12) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                Button(AppText.ocTerminalRetry) { Task { await store.reload() } }
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityIdentifier("oc.terminal.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let terminal = store.connection {
                OCTerminalSurface(connection: terminal, sessionID: store.sessionID)
                    .id(terminal.ptyID)
            } else if store.creating {
                message(AppText.ocTerminalLoading)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Color.appSecondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Surface

/// The screen: history and screen rows in the mono font, bottom-anchored; a tap brings up the
/// keyboard. The pane's size in cells goes to the connection on every layout change (rotation,
/// keyboard).
private struct OCTerminalSurface: View {
    let connection: OCTerminalConnection
    let sessionID: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.ocPanelBackground) private var panelBackground
    @State private var keyboardFocused = false
    @State private var controlArmed = false
    /// The view follows new output; a user scroll away from the bottom pauses it until they
    /// scroll back down or type.
    @State private var followsOutput = true
    /// The last scroll position is at (or within a row of) the bottom.
    @State private var atBottom = true
    /// Long-press and drag select cells; the edit menu then offers Copy, Quote and Select All.
    @State private var selection: OCTerminalSelection?
    /// Where the edit menu points (in the viewport), set when a selection gesture ends.
    @State private var menuRequest: OCTerminalMenuRequest?
    @State private var quotedNotice = false
    /// When the long press last reported: the tap that ends the same touch must not clear the
    /// selection it just made.
    @State private var lastSelectGesture = Date.distantPast
    /// Where the menu was last shown, to show it again after a handle drag.
    @State private var lastMenuPoint = CGPoint(x: 80, y: 40)
    /// The selection as a handle drag began (the edge being moved and its cell centre).
    @State private var handleDrag: (origin: CGPoint, fixed: OCTerminalPoint)?

    private static let viewport = "oc.terminal.viewport"
    private static let rows = "oc.terminal.rows"

    private static let fontSize: CGFloat = 13
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 8

    private var metrics: OCTerminalMetrics { OCTerminalMetrics.current(size: Self.fontSize) }
    /// The panel the terminal sits on is its default background (the web's `bg-base`).
    private var terminalBackground: Color { panelBackground ?? Color.appBackground }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                screen
                if let banner {
                    HStack(spacing: 12) {
                        Text(banner)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appDanger)
                        Spacer(minLength: 0)
                        if case .failed = connection.status {
                            Button(AppText.ocTerminalReconnect) { connection.reconnect() }
                                .font(.system(size: 12, weight: .medium))
                                .accessibilityIdentifier("oc.terminal.reconnect")
                        }
                    }
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.vertical, 8)
                    .background(Color.appBackground.opacity(0.95))
                    .accessibilityIdentifier("oc.terminal.status")
                }
            }
            OCTerminalKeyBar(
                controlArmed: $controlArmed,
                keyboardFocused: $keyboardFocused,
                applicationCursorKeys: connection.applicationCursorKeys,
                send: { data in
                    followsOutput = true
                    endSelection()
                    connection.input(data)
                }
            )
        }
        .background(
            OCTerminalKeyboard(focused: $keyboardFocused) { event in
                followsOutput = true
                // Typing ends a selection, so the new output is followed again.
                endSelection()
                switch event {
                case .text(let text):
                    let data = OCTerminalKeys.encode(text, control: controlArmed)
                    controlArmed = false
                    connection.input(data)
                case .backspace:
                    connection.input(OCTerminalKeys.backspace)
                case .key(let key):
                    connection.input(OCTerminalKeys.sequence(for: key, applicationCursorKeys: connection.applicationCursorKeys))
                }
            }
            .frame(width: 1, height: 1)
        )
    }

    private var banner: String? {
        switch connection.status {
        case .failed(let text): text
        case .exited: AppText.ocTerminalExited
        default: nil
        }
    }

    private var screen: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(connection.lines) { line in
                            OCTerminalRow(
                                line: line, metrics: metrics, background: terminalBackground,
                                selected: selection?.columns(line: line.id),
                                selectionColor: OCTerminalPalette.selection(dark: colorScheme == .dark)
                            )
                            .id(line.id)
                        }
                    }
                    // Rows are exactly one cell tall, so a point maps to a line and column directly.
                    .gesture(OCTerminalSelectGesture(viewport: Self.viewport) { phase, point, viewportPoint in
                        select(phase, at: point, viewportPoint: viewportPoint)
                    })
                    .overlay(alignment: .topLeading) { handles }
                    .coordinateSpace(.named(Self.rows))
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.vertical, Self.verticalPadding)
                    // At least the pane's height, so the part of a row left over goes below the
                    // screen, not above its first line (the scroll view is anchored to the bottom).
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - metrics.lineHeight
                } action: { _, bottom in
                    atBottom = bottom
                }
                .onScrollPhaseChange { old, phase in
                    // Only the user's own scrolling decides; content growth alone never unpins.
                    if phase == .interacting {
                        followsOutput = false
                        menuRequest = nil
                    } else if phase == .idle, old == .interacting || old == .decelerating {
                        followsOutput = atBottom
                    }
                }
                .onChange(of: connection.revision) { _, _ in
                    // A selection whose first line left the history (or a redraw) is dropped.
                    if let selection, let first = connection.lines.first?.id, selection.start.line < first {
                        self.selection = nil
                        menuRequest = nil
                    }
                    // New output keeps the screen in view, unless the user is reading back.
                    guard followsOutput, selection == nil, let last = connection.lines.last?.id else { return }
                    reader.scrollTo(last, anchor: .bottom)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // The release of the long press that just selected is not a tap.
                guard Date().timeIntervalSince(lastSelectGesture) > 0.5 else { return }
                // A tap ends a selection first; otherwise it brings up the keyboard.
                if selection != nil {
                    selection = nil
                    menuRequest = nil
                } else {
                    keyboardFocused = true
                }
            }
            .background(
                OCTerminalEditMenu(
                    request: $menuRequest,
                    quoteAllowed: { quoteAllowed },
                    perform: perform
                )
            )
            .overlay(alignment: .top) {
                if quotedNotice {
                    Text(AppText.ocTerminalQuoted)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appTertiary, in: Capsule())
                        .padding(.top, 8)
                        .accessibilityIdentifier("oc.terminal.quoted")
                        .transition(.opacity)
                }
            }
            .coordinateSpace(.named(Self.viewport))
            .onAppear { report(proxy.size) }
            .onChange(of: proxy.size) { _, size in report(size) }
        }
        .accessibilityIdentifier("oc.terminal.screen")
    }

    // MARK: Selection

    private func endSelection() {
        guard selection != nil else { return }
        selection = nil
        menuRequest = nil
    }

    /// Index of a line by id: ids count up one per line, so it is the offset from the first.
    private func row(of id: Int) -> Int? {
        let lines = connection.lines
        guard let first = lines.first?.id else { return nil }
        let index = id - first
        if lines.indices.contains(index), lines[index].id == id { return index }
        return lines.firstIndex { $0.id == id }
    }

    /// Where an edge of the selection is drawn: the start at its first cell's top left, the end
    /// after its last cell (a row selected through its end stops at the row's text).
    private func handlePosition(_ edge: OCTerminalSelection.Edge, of selection: OCTerminalSelection) -> CGPoint? {
        let point = edge == .start ? selection.start : selection.end
        guard let index = row(of: point.line) else { return nil }
        let line = connection.lines[index]
        let y = CGFloat(index) * metrics.lineHeight
        switch edge {
        case .start:
            return CGPoint(x: CGFloat(point.column) * metrics.cellWidth, y: y)
        case .end:
            let textEnd = line.cells().last.map { $0.column + $0.width } ?? 0
            let column = point.column >= OCTerminalSelection.lineEnd ? max(textEnd, 1) : point.column + 1
            return CGPoint(x: CGFloat(column) * metrics.cellWidth, y: y + metrics.lineHeight)
        }
    }

    /// The two handles that adjust a selection, as text selection does elsewhere on iOS.
    @ViewBuilder
    private var handles: some View {
        if let selection {
            ForEach([OCTerminalSelection.Edge.start, .end], id: \.self) { edge in
                if let position = handlePosition(edge, of: selection) {
                    OCTerminalHandle(edge: edge, height: metrics.lineHeight)
                        // The bar spans the edge's row; the knob (10 pt) sits outside it.
                        .position(
                            x: position.x,
                            y: edge == .start ? position.y + metrics.lineHeight / 2 - 5 : position.y - metrics.lineHeight / 2 + 5
                        )
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rows))
                                .onChanged { value in moveHandle(edge, from: position, by: value.translation) }
                                .onEnded { _ in
                                    handleDrag = nil
                                    lastSelectGesture = Date()
                                    menuRequest = OCTerminalMenuRequest(point: lastMenuPoint)
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel(edge == .start ? AppText.ocTerminalSelectionStart : AppText.ocTerminalSelectionEnd)
                        .accessibilityIdentifier(edge == .start ? "oc.terminal.handle.start" : "oc.terminal.handle.end")
                        // The selected text (UI tests read it from the end handle).
                        .accessibilityValue(edge == .end ? String(selectedText.prefix(200)) : "")
                }
            }
        }
    }

    private func moveHandle(_ edge: OCTerminalSelection.Edge, from position: CGPoint, by translation: CGSize) {
        guard let selection else { return }
        if handleDrag == nil {
            // The centre of the edge's cell, so the finger moves that cell.
            let origin = edge == .start
                ? CGPoint(x: position.x + metrics.cellWidth / 2, y: position.y + metrics.lineHeight / 2)
                : CGPoint(x: position.x - metrics.cellWidth / 2, y: position.y - metrics.lineHeight / 2)
            handleDrag = (origin, selection.fixedPoint(dragging: edge))
            menuRequest = nil
        }
        guard let drag = handleDrag,
              let point = point(at: CGPoint(x: drag.origin.x + translation.width, y: drag.origin.y + translation.height))
        else { return }
        let moved = OCTerminalSelection.dragged(fixed: drag.fixed, to: point)
        if moved != selection { self.selection = moved }
    }

    /// The cell under a point of the rows (content coordinates).
    private func point(at location: CGPoint) -> OCTerminalPoint? {
        let lines = connection.lines
        guard !lines.isEmpty else { return nil }
        let row = min(max(0, Int(floor(location.y / metrics.lineHeight))), lines.count - 1)
        let column = max(0, Int(floor(location.x / metrics.cellWidth)))
        let line = lines[row]
        return OCTerminalPoint(line: line.id, column: line.cellStart(column))
    }

    private func select(_ phase: OCTerminalSelectGesture.Phase, at location: CGPoint, viewportPoint: CGPoint) {
        lastSelectGesture = Date()
        switch phase {
        case .began:
            guard let point = point(at: location) else { return }
            menuRequest = nil
            // The keyboard stays: hiding it resizes the terminal, and the server's redraw would
            // replace the lines the selection points at.
            // A long press takes the word under the finger, like text elsewhere on iOS.
            let line = connection.lines.first { $0.id == point.line }
            if let word = line?.word(at: point.column) {
                selection = OCTerminalSelection(
                    anchor: OCTerminalPoint(line: point.line, column: word.lowerBound),
                    head: OCTerminalPoint(line: point.line, column: word.upperBound)
                )
            } else {
                selection = OCTerminalSelection(anchor: point, head: point)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            guard var current = selection, let point = point(at: location) else { return }
            current.head = point
            selection = current
        case .ended:
            guard selection != nil else { return }
            lastMenuPoint = viewportPoint
            menuRequest = OCTerminalMenuRequest(point: viewportPoint)
        case .cancelled:
            break
        }
    }

    private var selectedText: String {
        selection?.text(in: connection.lines) ?? ""
    }

    private var quoteAllowed: Bool {
        OCTerminalSelection.fitsQuote(OCTerminalSelection.quoteText(selectedText))
    }

    private func perform(_ action: OCTerminalEditMenu.Action) {
        switch action {
        case .copy:
            let text = selectedText
            if !text.isEmpty { UIPasteboard.general.string = text }
            selection = nil
        case .quote:
            let text = OCTerminalSelection.quoteText(selectedText)
            guard !text.isEmpty, OCTerminalSelection.fitsQuote(text) else { return }
            OCDiffCommentStore.shared.addQuote(sessionID: sessionID, text: text)
            selection = nil
            withAnimation { quotedNotice = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { quotedNotice = false }
            }
        case .selectAll:
            selection = OCTerminalSelection.all(connection.lines)
            menuRequest = OCTerminalMenuRequest(point: lastMenuPoint)
        }
    }

    private func report(_ size: CGSize) {
        let cells = metrics.cells(
            in: CGSize(
                width: size.width - Self.horizontalPadding * 2,
                height: size.height - Self.verticalPadding * 2
            )
        )
        connection.resize(cols: cells.cols, rows: cells.rows)
    }
}

/// One line as attributed runs in the mono font; the row is exactly one cell tall.
private struct OCTerminalRow: View, Equatable {
    let line: OCTerminalLine
    let metrics: OCTerminalMetrics
    /// The terminal's default background (inverse cells without a colour take it as foreground).
    let background: Color
    /// Selected columns of this line (`OCTerminalSelection.lineEnd` = through the row's end).
    var selected: ClosedRange<Int>? = nil
    var selectionColor: Color = .clear

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: metrics.lineHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if let selected {
                    let columns = min(selected.upperBound, 4096) - selected.lowerBound + 1
                    selectionColor
                        .frame(width: CGFloat(columns) * metrics.cellWidth, height: metrics.lineHeight)
                        .offset(x: CGFloat(selected.lowerBound) * metrics.cellWidth)
                }
            }
            .clipped()
            .accessibilityLabel(line.text.trimmingCharacters(in: .whitespaces))
            .accessibilityIdentifier("oc.terminal.line")
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for run in line.runs {
            var part = AttributedString(run.text)
            let style = run.style
            var foreground = OCTerminalPalette.color(style.foreground) ?? Color.appPrimary
            var background = OCTerminalPalette.color(style.background)
            if style.inverse != style.cursor {
                let swapped = background ?? self.background
                background = foreground
                foreground = swapped
            }
            part.foregroundColor = style.dim ? foreground.opacity(0.6) : foreground
            if let background { part.backgroundColor = background }
            var font = style.bold ? metrics.bold : metrics.regular
            if style.italic { font = font.italic() }
            part.font = font
            if style.underline { part.underlineStyle = Text.LineStyle.single }
            result += part
        }
        if result.characters.isEmpty {
            result = AttributedString(" ")
            result.font = metrics.regular
        }
        return result
    }
}

/// The mono font's cell size, for turning the pane's points into columns and rows.
struct OCTerminalMetrics: Equatable {
    let fontSize: CGFloat
    let cellWidth: CGFloat
    let lineHeight: CGFloat

    /// The theme's mono fonts, resolved once (not per row per screen update).
    let regular: Font
    let bold: Font

    private static var cache: [String: OCTerminalMetrics] = [:]

    /// Measured once per theme font and size, then cached.
    static func current(size: CGFloat) -> OCTerminalMetrics {
        let family = OpenLensDesignSystem.currentTheme.typography.monoFamily
        let key = "\(family ?? "system")/\(size)"
        if let cached = cache[key] { return cached }
        let font = family.flatMap { UIFont(name: $0, size: size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let metrics = OCTerminalMetrics(
            fontSize: size, cellWidth: max(1, width), lineHeight: ceil(font.lineHeight),
            regular: .openLensMono(size: size), bold: .openLensMono(size: size, weight: .bold)
        )
        cache[key] = metrics
        return metrics
    }

    func cells(in size: CGSize) -> (cols: Int, rows: Int) {
        (max(1, Int(floor(size.width / cellWidth))), max(1, Int(floor(size.height / lineHeight))))
    }
}

/// One fixed colour table for both appearances, as the web's emulator (ghostty-web's default theme:
/// the 16 ANSI colours, then the xterm 6×6×6 cube and 24 greys). Only the default background,
/// foreground, cursor and selection follow the theme.
nonisolated enum OCTerminalPalette {
    struct RGB: Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    static let ansi: [RGB] = [
        RGB(0x00, 0x00, 0x00), RGB(0xcd, 0x31, 0x31), RGB(0x0d, 0xbc, 0x79), RGB(0xe5, 0xe5, 0x10),
        RGB(0x24, 0x72, 0xc8), RGB(0xbc, 0x3f, 0xbc), RGB(0x11, 0xa8, 0xcd), RGB(0xe5, 0xe5, 0xe5),
        RGB(0x66, 0x66, 0x66), RGB(0xf1, 0x4c, 0x4c), RGB(0x23, 0xd1, 0x8b), RGB(0xf5, 0xf5, 0x43),
        RGB(0x3b, 0x8e, 0xea), RGB(0xd6, 0x70, 0xd6), RGB(0x29, 0xb8, 0xdb), RGB(0xff, 0xff, 0xff),
    ]

    /// The table entry for a cell colour (0–255 or true colour).
    static func rgb(_ color: OCTerminalColor) -> RGB {
        switch color {
        case .ansi(let n):
            return ansi[min(max(0, n), 15)]
        case .indexed(let n):
            let n = min(max(0, n), 255)
            if n < 16 { return ansi[n] }
            if n >= 232 {
                let level = UInt8(8 + (n - 232) * 10)
                return RGB(level, level, level)
            }
            let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
            let value = n - 16
            return RGB(steps[(value / 36) % 6], steps[(value / 6) % 6], steps[value % 6])
        case .rgb(let r, let g, let b):
            return RGB(r, g, b)
        }
    }

    static func color(_ color: OCTerminalColor?) -> Color? {
        guard let color else { return nil }
        let value = rgb(color)
        return Color(red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255)
    }

    /// The web's selection: the foreground at 20 % (light) / 25 % (dark).
    static func selection(dark: Bool) -> Color {
        Color.appPrimary.opacity(dark ? 0.25 : 0.2)
    }
}

// MARK: - Selection gesture and edit menu

/// Long press, then drag: the terminal's text selection. A UIKit recognizer, so a plain drag still
/// scrolls the history and the press reports the finger while it moves after recognising.
private struct OCTerminalSelectGesture: UIGestureRecognizerRepresentable {
    enum Phase { case began, changed, ended, cancelled }

    let viewport: String
    /// The point in the rows' coordinates and in the viewport (for the menu).
    let onChange: (Phase, CGPoint, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.35
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let phase: Phase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }
        onChange(phase, context.converter.localLocation, context.converter.location(in: .named(viewport)))
    }
}

/// A selection handle: a bar the height of a row with a knob above (start) or below (end).
private struct OCTerminalHandle: View {
    let edge: OCTerminalSelection.Edge
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if edge == .start { knob }
            Rectangle().fill(Color.accentColor).frame(width: 2, height: height)
            if edge == .end { knob }
        }
        // A finger-sized hit area around the thin handle.
        .frame(width: 32, height: height + 28)
        .contentShape(Rectangle())
    }

    private var knob: some View {
        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
    }
}

/// A request to show the edit menu at a point of the viewport; a new value shows it again.
struct OCTerminalMenuRequest: Equatable {
    let id = UUID()
    let point: CGPoint
}

/// The system edit menu over the terminal (Copy, Quote, Select All), presented by a
/// `UIEditMenuInteraction` on a view behind the screen that never takes touches itself.
private struct OCTerminalEditMenu: UIViewRepresentable {
    enum Action { case copy, quote, selectAll }

    @Binding var request: OCTerminalMenuRequest?
    /// Read when the menu opens (the selection's text is built only then, not on every update).
    let quoteAllowed: () -> Bool
    let perform: (Action) -> Void

    func makeUIView(context: Context) -> OCTerminalMenuHostView {
        let view = OCTerminalMenuHostView()
        let interaction = UIEditMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        return view
    }

    func updateUIView(_ view: OCTerminalMenuHostView, context: Context) {
        context.coordinator.parent = self
        guard let request else {
            if context.coordinator.shown != nil {
                context.coordinator.shown = nil
                context.coordinator.interaction?.dismissMenu()
            }
            return
        }
        guard context.coordinator.shown != request.id else { return }
        context.coordinator.shown = request.id
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: request.point)
        DispatchQueue.main.async {
            context.coordinator.interaction?.presentEditMenu(with: configuration)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        var parent: OCTerminalEditMenu
        weak var interaction: UIEditMenuInteraction?
        var shown: UUID?

        init(parent: OCTerminalEditMenu) {
            self.parent = parent
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            let perform = parent.perform
            var actions: [UIMenuElement] = [
                UIAction(title: AppText.ocTerminalCopy) { _ in perform(.copy) },
            ]
            if parent.quoteAllowed() {
                actions.append(UIAction(title: AppText.ocTerminalQuote, image: UIImage(systemName: "quote.opening")) { _ in perform(.quote) })
            } else {
                actions.append(UIAction(title: AppText.ocTerminalQuoteTooLong, attributes: .disabled) { _ in })
            }
            actions.append(UIAction(title: AppText.ocTerminalSelectAll) { _ in perform(.selectAll) })
            return UIMenu(children: actions)
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
            animator: any UIEditMenuInteractionAnimating
        ) {
            animator.addCompletion { [weak self] in
                guard let self, self.shown != nil else { return }
                self.shown = nil
                self.parent.request = nil
            }
        }
    }
}

/// Hosts the edit menu; hit testing passes through to the screen.
final class OCTerminalMenuHostView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

// MARK: - Keys

/// Bytes for the key bar and the keyboard.
nonisolated enum OCTerminalKeys {
    enum Key: Equatable {
        case escape, tab, up, down, left, right
    }

    static let backspace = Data([0x7f])

    /// Typed text; Return sends CR. With Control armed, a letter or one of `@[\]^_ ` becomes its control code.
    static func encode(_ text: String, control: Bool) -> Data {
        let text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        guard control, let first = text.unicodeScalars.first, text.unicodeScalars.count == 1 else {
            return Data(text.utf8)
        }
        switch first.value {
        case 0x61...0x7a: return Data([UInt8(first.value - 0x60)]) // a–z
        case 0x40...0x5f: return Data([UInt8(first.value - 0x40)]) // @ A–Z [ \ ] ^ _
        case 0x20: return Data([0])
        case 0x3f: return Data([0x7f]) // ?
        default: return Data(text.utf8)
        }
    }

    static func sequence(for key: Key, applicationCursorKeys: Bool) -> Data {
        let prefix = applicationCursorKeys ? "\u{1b}O" : "\u{1b}["
        switch key {
        case .escape: return Data([0x1b])
        case .tab: return Data([0x09])
        case .up: return Data((prefix + "A").utf8)
        case .down: return Data((prefix + "B").utf8)
        case .right: return Data((prefix + "C").utf8)
        case .left: return Data((prefix + "D").utf8)
        }
    }
}

/// Esc, Tab, a sticky Ctrl, the arrows and a keyboard toggle, under the screen.
private struct OCTerminalKeyBar: View {
    @Binding var controlArmed: Bool
    @Binding var keyboardFocused: Bool
    let applicationCursorKeys: Bool
    let send: (Data) -> Void

    var body: some View {
        HStack(spacing: 6) {
            key("esc", id: "oc.terminal.key.esc") { send(OCTerminalKeys.sequence(for: .escape, applicationCursorKeys: false)) }
            key("tab", id: "oc.terminal.key.tab") { send(OCTerminalKeys.sequence(for: .tab, applicationCursorKeys: false)) }
            key("ctrl", id: "oc.terminal.key.ctrl", active: controlArmed) { controlArmed.toggle() }
            arrow("arrow.left", .left, id: "oc.terminal.key.left")
            arrow("arrow.up", .up, id: "oc.terminal.key.up")
            arrow("arrow.down", .down, id: "oc.terminal.key.down")
            arrow("arrow.right", .right, id: "oc.terminal.key.right")
            Spacer(minLength: 0)
            Button {
                keyboardFocused.toggle()
            } label: {
                Image(systemName: keyboardFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.terminal.key.keyboard")
            .accessibilityLabel(AppText.ocTerminalKeyboard)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(Color.appSeparator).frame(height: 1) }
    }

    private func key(_ title: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.openLensMono(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.appBackground : Color.appPrimary)
                .padding(.horizontal, 8)
                .frame(minWidth: 36)
                .frame(height: 28)
                .background(active ? Color.appPrimary : Color.appTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func arrow(_ icon: String, _ key: OCTerminalKeys.Key, id: String) -> some View {
        Button {
            send(OCTerminalKeys.sequence(for: key, applicationCursorKeys: applicationCursorKeys))
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 30, height: 28)
                .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Keyboard

/// What the keyboard reports to the surface.
enum OCTerminalKeyEvent {
    case text(String)
    case backspace
    case key(OCTerminalKeys.Key)
}

/// A hidden first responder taking keyboard input for the terminal (no text field: every key goes
/// straight to the PTY, nothing is corrected or capitalised).
private struct OCTerminalKeyboard: UIViewRepresentable {
    @Binding var focused: Bool
    let onEvent: (OCTerminalKeyEvent) -> Void

    func makeUIView(context: Context) -> OCTerminalKeyInputView {
        let view = OCTerminalKeyInputView()
        view.onEvent = onEvent
        view.onFocusChange = { focused in
            if self.focused != focused { self.focused = focused }
        }
        return view
    }

    func updateUIView(_ view: OCTerminalKeyInputView, context: Context) {
        view.onEvent = onEvent
        view.onFocusChange = { focused in
            if self.focused != focused { self.focused = focused }
        }
        if focused, !view.isFirstResponder {
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        } else if !focused, view.isFirstResponder {
            DispatchQueue.main.async { _ = view.resignFirstResponder() }
        }
    }
}

final class OCTerminalKeyInputView: UIView, UIKeyInput {
    var onEvent: (OCTerminalKeyEvent) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    // UITextInputTraits: plain keys, nothing rewritten.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default
    var inlinePredictionType: UITextInlinePredictionType = .no

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange(false) }
        return resigned
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        onEvent(.text(text))
    }

    func deleteBackward() {
        onEvent(.backspace)
    }

    override var keyCommands: [UIKeyCommand]? {
        let arrows: [(String, OCTerminalKeys.Key)] = [
            (UIKeyCommand.inputUpArrow, .up), (UIKeyCommand.inputDownArrow, .down),
            (UIKeyCommand.inputLeftArrow, .left), (UIKeyCommand.inputRightArrow, .right),
            (UIKeyCommand.inputEscape, .escape),
        ]
        var commands = arrows.map { input, _ in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(hardwareKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            commands.append(UIKeyCommand(input: String(letter), modifierFlags: .control, action: #selector(hardwareKey(_:))))
        }
        return commands
    }

    @objc private func hardwareKey(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        if command.modifierFlags.contains(.control) {
            onEvent(.text(String(UnicodeScalar(UInt8(input.unicodeScalars.first!.value - 0x60)))))
            return
        }
        switch input {
        case UIKeyCommand.inputUpArrow: onEvent(.key(.up))
        case UIKeyCommand.inputDownArrow: onEvent(.key(.down))
        case UIKeyCommand.inputLeftArrow: onEvent(.key(.left))
        case UIKeyCommand.inputRightArrow: onEvent(.key(.right))
        case UIKeyCommand.inputEscape: onEvent(.key(.escape))
        default: break
        }
    }
}
