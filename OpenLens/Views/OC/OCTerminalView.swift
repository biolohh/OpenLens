import SwiftUI
import UIKit

/// The web's mobile Terminal view (More... > Terminal): a strip with the session's terminals
/// (title, close) and a new-terminal button, then the live screen with a key bar. Opening it
/// attaches to the session's first terminal, creating one only when the session has none.
struct OCTerminalView: View {
    let store: OCTerminalStore

    @Environment(\.connection) private var connection

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
                isV2: connection.serverCapabilities?.protocolVersion == .v2
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
                .accessibilityLabel(OCTerminalText.newTerminal)
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
            .accessibilityLabel(OCTerminalText.close)
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
            message(OCTerminalText.loading)
        case .unavailable(let text):
            message(text)
        case .failed(let text):
            VStack(spacing: 12) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                Button(OCTerminalText.retry) { Task { await store.reload() } }
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityIdentifier("oc.terminal.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let terminal = store.connection {
                OCTerminalSurface(connection: terminal)
                    .id(terminal.ptyID)
            } else if store.creating {
                message(OCTerminalText.loading)
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

    @Environment(\.colorScheme) private var colorScheme
    @State private var keyboardFocused = false
    @State private var controlArmed = false

    private static let fontSize: CGFloat = 13
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 8

    private var metrics: OCTerminalMetrics { OCTerminalMetrics.current(size: Self.fontSize) }

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
                            Button(OCTerminalText.reconnect) { connection.reconnect() }
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
                send: { connection.input($0) }
            )
        }
        .background(
            OCTerminalKeyboard(focused: $keyboardFocused) { event in
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
        case .exited: OCTerminalText.exited
        default: nil
        }
    }

    private var screen: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(connection.lines) { line in
                            OCTerminalRow(line: line, metrics: metrics, dark: colorScheme == .dark)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.vertical, Self.verticalPadding)
                    // At least the pane's height, so the part of a row left over goes below the
                    // screen, not above its first line (the scroll view is anchored to the bottom).
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
                .onChange(of: connection.revision) { _, _ in
                    // New output brings the screen back into view, like a terminal.
                    if let last = connection.lines.last?.id { reader.scrollTo(last, anchor: .bottom) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { keyboardFocused = true }
            .onAppear { report(proxy.size) }
            .onChange(of: proxy.size) { _, size in report(size) }
        }
        .accessibilityIdentifier("oc.terminal.screen")
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
    let dark: Bool

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: metrics.lineHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .accessibilityLabel(line.text.trimmingCharacters(in: .whitespaces))
            .accessibilityIdentifier("oc.terminal.line")
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for run in line.runs {
            var part = AttributedString(run.text)
            let style = run.style
            var foreground = OCTerminalPalette.color(style.foreground, dark: dark) ?? Color.appPrimary
            var background = OCTerminalPalette.color(style.background, dark: dark)
            if style.inverse != style.cursor {
                let swapped = background ?? Color.appBackground
                background = foreground
                foreground = swapped
            }
            part.foregroundColor = style.dim ? foreground.opacity(0.6) : foreground
            if let background { part.backgroundColor = background }
            var font = Font.openLensMono(size: metrics.fontSize, weight: style.bold ? .bold : .regular)
            if style.italic { font = font.italic() }
            part.font = font
            if style.underline { part.underlineStyle = Text.LineStyle.single }
            result += part
        }
        if result.characters.isEmpty {
            result = AttributedString(" ")
            result.font = Font.openLensMono(size: metrics.fontSize)
        }
        return result
    }
}

/// The mono font's cell size, for turning the pane's points into columns and rows.
struct OCTerminalMetrics: Equatable {
    let fontSize: CGFloat
    let cellWidth: CGFloat
    let lineHeight: CGFloat

    static func current(size: CGFloat) -> OCTerminalMetrics {
        let family = OpenLensDesignSystem.currentTheme.typography.monoFamily
        let font = family.flatMap { UIFont(name: $0, size: size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        return OCTerminalMetrics(fontSize: size, cellWidth: max(1, width), lineHeight: ceil(font.lineHeight))
    }

    func cells(in size: CGSize) -> (cols: Int, rows: Int) {
        (max(1, Int(floor(size.width / cellWidth))), max(1, Int(floor(size.height / lineHeight))))
    }
}

/// The 16 ANSI colours and the xterm 256-colour table. Red, green and yellow are the theme's
/// danger / success / warning colours; the rest are fixed terminal colours with a darker light-mode
/// variant so they stay readable on both backgrounds.
enum OCTerminalPalette {
    private static let named: [(light: UIColor, dark: UIColor)] = [
        (rgb(23, 23, 23), rgb(60, 60, 60)), // black
        (rgb(220, 60, 40), rgb(252, 83, 58)), // red
        (rgb(10, 140, 0), rgb(18, 201, 5)), // green
        (rgb(160, 118, 0), rgb(252, 213, 58)), // yellow
        (rgb(30, 90, 200), rgb(80, 150, 255)), // blue
        (rgb(170, 40, 170), rgb(220, 110, 220)), // magenta
        (rgb(0, 130, 150), rgb(60, 200, 215)), // cyan
        (rgb(110, 110, 110), rgb(200, 200, 200)), // white
        (rgb(90, 90, 90), rgb(110, 110, 110)), // bright black
        (rgb(235, 80, 60), rgb(255, 120, 100)), // bright red
        (rgb(20, 160, 20), rgb(90, 230, 80)), // bright green
        (rgb(180, 140, 0), rgb(255, 230, 110)), // bright yellow
        (rgb(50, 110, 230), rgb(120, 180, 255)), // bright blue
        (rgb(190, 60, 190), rgb(240, 140, 240)), // bright magenta
        (rgb(0, 150, 170), rgb(110, 225, 235)), // bright cyan
        (rgb(60, 60, 60), rgb(240, 240, 240)), // bright white
    ]

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    static func color(_ color: OCTerminalColor?, dark: Bool) -> Color? {
        guard let color else { return nil }
        switch color {
        case .ansi(let n):
            switch n {
            case 1: return .appDanger
            case 2: return .appSuccess
            case 3: return .appWarning
            default:
                let pair = named[min(max(0, n), 15)]
                return Color(uiColor: dark ? pair.dark : pair.light)
            }
        case .indexed(let n):
            return Color(uiColor: indexed(n))
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }

    private static func indexed(_ n: Int) -> UIColor {
        if n >= 232 {
            let level = CGFloat(8 + (n - 232) * 10)
            return rgb(level, level, level)
        }
        let value = n - 16
        let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
        let red: CGFloat = steps[(value / 36) % 6]
        let green: CGFloat = steps[(value / 6) % 6]
        let blue: CGFloat = steps[value % 6]
        return rgb(red, green, blue)
    }
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
            .accessibilityLabel(OCTerminalText.keyboard)
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
