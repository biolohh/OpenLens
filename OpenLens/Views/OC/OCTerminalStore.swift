import Foundation
import Observation
import os

/// The Terminal tab's strings (the web's `terminal` plugin, en).
nonisolated enum OCTerminalText {
    static let loading = "Loading terminal…"
    static let listFailed = "Couldn't load terminals"
    static let unavailable = "Terminals aren't available on this server"
    static let outdated = "This server is too old for terminals. Update OpenCode on this server."
    static let createFailed = "Couldn't create a terminal"
    static let closeFailed = "Couldn't close the terminal"
    static let disconnected = "Terminal disconnected"
    static let connectionFailed = "Terminal connection failed"
    static let serverOutdated = "This server is too old for terminals; update OpenCode on it"
    static let exited = "Process exited"
    static let tabTitle = "Terminal"
    static let newTerminal = "New terminal"
    static let close = "Close terminal"
    static let retry = "Try again"
    static let reconnect = "Reconnect"
    static let keyboard = "Keyboard"

    static func numbered(_ number: Int) -> String { "Terminal \(number)" }

    /// The number of a default title such as "Terminal 2".
    static func titleNumber(_ title: String) -> Int? {
        guard title.hasPrefix("Terminal ") else { return nil }
        let digits = title.dropFirst("Terminal ".count)
        guard let first = digits.first, first != "0", digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// The lowest default number the given terminals don't use yet (the web's `defaultTitle`).
    static func nextNumber(after titles: [String]) -> Int {
        let used = Set(titles.compactMap(titleNumber))
        return (1...(used.count + 1)).first { !used.contains($0) } ?? 1
    }
}

/// One live attachment to a terminal: the snapshot restores the screen, then the socket's replay
/// and output stream into the emulator in order. Input and size frames go out once the replay is
/// on screen, at the pane's size, as in the web's connection machine.
@Observable
final class OCTerminalConnection {
    enum Status: Equatable {
        case connecting
        case live
        case exited
        case failed(String)
    }

    let ptyID: String
    private(set) var status: Status = .connecting
    private(set) var lines: [OCTerminalLine] = []
    /// Bumps with every screen update.
    private(set) var revision = 0
    private(set) var screenRows = 24
    private(set) var title: String?
    private(set) var applicationCursorKeys = false
    /// This attachment drives the terminal's size and input.
    private(set) var isController = false

    @ObservationIgnored private let client: OCTerminalClient
    @ObservationIgnored private let attachmentID = UUID().uuidString.lowercased()
    @ObservationIgnored private var socket: OCTerminalSocket?
    @ObservationIgnored private var engine: OCTerminalEngine!
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var replayDone = false
    @ObservationIgnored private var paneSize: OCTerminalInfo.Size?
    @ObservationIgnored private var pendingInput: [Data] = []
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0

    init(ptyID: String, client: OCTerminalClient) {
        self.ptyID = ptyID
        self.client = client
        engine = OCTerminalEngine { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    func start() {
        guard connecting == nil, socket == nil else { return }
        status = .connecting
        replayDone = false
        isController = false
        attempt += 1
        let current = attempt
        connecting = Task { [weak self] in
            await self?.connect()
            if self?.attempt == current { self?.connecting = nil }
        }
    }

    private func connect() async {
        do {
            let snapshot = try await client.snapshot(ptyID: ptyID)
            if let size = snapshot.info.size {
                engine.resize(cols: size.cols, rows: size.rows, reset: true, checkpoint: snapshot.checkpoint)
            }
            let ticket = try await client.connectToken(ptyID: ptyID)
            guard !Task.isCancelled else { return }
            let request = client.socketRequest(
                ptyID: ptyID, ticket: ticket,
                cursor: snapshot.info.output?.tail ?? 0,
                attachmentID: attachmentID
            )
            let socket = OCTerminalSocket(request: request, session: client.session)
            self.socket = socket
            socket.start(
                onMessage: { [weak self] incoming in self?.receive(incoming) },
                onClose: { [weak self] error in self?.socketClosed(error) }
            )
        } catch {
            guard !Task.isCancelled else { return }
            Logger.api.debug("Terminal connect failed: \(error.localizedDescription, privacy: .public)")
            fail((error as? OCTerminalClientError) == .notFound ? OCTerminalText.disconnected : OCTerminalText.connectionFailed)
        }
    }

    private func receive(_ incoming: OCTerminalSocket.Incoming) {
        switch incoming {
        case .output(let data):
            if case .failed = status { return }
            engine.write(data)
        case .message(let text):
            guard let message = OCTerminalProtocol.decode(text) else { return }
            handle(message)
        }
    }

    private func handle(_ message: OCTerminalProtocol.Message) {
        switch message {
        case .attached(let inputProtocol, let cols, let rows, let role):
            guard inputProtocol == 1 else {
                fail(OCTerminalText.serverOutdated)
                return
            }
            isController = role == "controller"
            engine.resize(cols: cols, rows: rows)
        case .replayComplete:
            replayDone = true
            status = .live
            flush()
        case .resized(let cols, let rows, let checkpoint):
            engine.resize(cols: cols, rows: rows, reset: true, checkpoint: checkpoint)
        case .controllerChanged(let id):
            let controller = id == attachmentID
            guard controller != isController else { return }
            isController = controller
            if controller, replayDone, let paneSize { send(OCTerminalProtocol.frame(cols: paneSize.cols, rows: paneSize.rows)) }
        case .exited:
            status = .exited
            engine.setCursorShown(false)
        case .titleChanged(let title):
            self.title = title
        case .other:
            break
        }
    }

    /// The pane's size in cells; a controlling attachment resizes the terminal to it.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let size = OCTerminalInfo.Size(cols: cols, rows: rows)
        guard size != paneSize else { return }
        let first = paneSize == nil
        paneSize = size
        guard replayDone else { return }
        if first { flush() } else if isController { send(OCTerminalProtocol.frame(cols: cols, rows: rows)) }
    }

    /// Typed bytes. Before the replay is on screen or the pane is measured they wait.
    func input(_ data: Data) {
        guard !data.isEmpty else { return }
        switch status {
        case .exited, .failed: return
        default: break
        }
        guard replayDone, let paneSize else {
            pendingInput.append(data)
            return
        }
        send(OCTerminalProtocol.frame(cols: paneSize.cols, rows: paneSize.rows, data: data))
    }

    func input(_ text: String) { input(Data(text.utf8)) }

    /// Sends held input, else takes control at the pane's size (`takeover`).
    private func flush() {
        guard replayDone, let paneSize else { return }
        if pendingInput.isEmpty {
            send(OCTerminalProtocol.frame(cols: paneSize.cols, rows: paneSize.rows))
        } else {
            pendingInput.forEach { send(OCTerminalProtocol.frame(cols: paneSize.cols, rows: paneSize.rows, data: $0)) }
            pendingInput = []
        }
    }

    private func send(_ frame: Data) {
        socket?.send(frame)
    }

    private func socketClosed(_ error: Error?) {
        socket = nil
        if status == .exited { return }
        if case .failed = status { return }
        fail(OCTerminalText.disconnected)
    }

    private func fail(_ message: String) {
        status = .failed(message)
        engine.setCursorShown(false)
        socket?.close()
        socket = nil
    }

    /// Detaches without ending the terminal on the server.
    func disconnect() {
        connecting?.cancel()
        connecting = nil
        socket?.close()
        socket = nil
    }

    /// A new attachment after a failure (the web mounts a new terminal for it).
    func reconnect() {
        disconnect()
        pendingInput = []
        engine.setCursorShown(true)
        start()
    }

    private func apply(_ snapshot: OCTerminalEngine.Snapshot) {
        guard snapshot.generation > generation else { return }
        generation = snapshot.generation
        lines = snapshot.lines
        revision &+= 1
        screenRows = snapshot.rows
        applicationCursorKeys = snapshot.applicationCursorKeys
        if let title = snapshot.title, self.title == nil || self.title != title { self.title = title }
    }
}

/// The session's terminals as the server lists them, the shown one and its live attachment. Kept
/// by `OCSessionView`, so the terminal survives switching tabs; it never ends a terminal on its
/// own: only the tab's close button does, as on the web.
@Observable
final class OCTerminalStore {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
        case unavailable(String)
    }

    let sessionID: String
    let directory: String?
    private(set) var phase: Phase = .idle
    private(set) var terminals: [OCTerminalInfo] = []
    private(set) var activeID: String?
    private(set) var creating = false
    private(set) var connection: OCTerminalConnection?
    /// Terminals this screen created (the smoke test closes only these).
    private(set) var createdIDs: Set<String> = []
    var actionError: String?

    @ObservationIgnored private var client: OCTerminalClient?
    @ObservationIgnored private var loadedOnce = false

    init(sessionID: String, directory: String?) {
        self.sessionID = sessionID
        self.directory = directory
    }

    /// Lists the session's terminals; the first time, an empty list gets a new terminal (the
    /// narrow-screen web does the same). Reattaches the shown terminal if its socket ended.
    func appear(apiClient: OpenCodeClient?, isV2: Bool) async {
        guard isV2, let apiClient else {
            phase = .unavailable(OCTerminalText.unavailable)
            return
        }
        if client == nil {
            let endpoint = await apiClient.connectionEndpoint()
            client = OCTerminalClient(baseURL: endpoint.baseURL, authHeader: endpoint.authHeader)
        }
        if phase == .ready {
            if let connection, case .failed = connection.status { connection.reconnect() } else { connection?.start() }
            return
        }
        await load()
    }

    func load() async {
        guard let client else { return }
        phase = .loading
        do {
            let items = try await client.list(sessionID: sessionID)
            terminals = items
            let firstLoad = !loadedOnce
            loadedOnce = true
            phase = .ready
            if items.isEmpty {
                if firstLoad { await create() }
            } else {
                select(activeID.flatMap { id in items.first { $0.id == id }?.id } ?? items[0].id)
            }
        } catch let error as OCTerminalClientError {
            switch error {
            case .unavailable, .outdated: phase = .unavailable(error.localizedDescription)
            default: phase = .failed(error.localizedDescription)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func create() async {
        guard let client, !creating else { return }
        creating = true
        defer { creating = false }
        do {
            let title = OCTerminalText.numbered(OCTerminalText.nextNumber(after: terminals.map(\.title)))
            let info = try await client.create(sessionID: sessionID, cwd: directory, title: title)
            if !terminals.contains(where: { $0.id == info.id }) { terminals.append(info) }
            createdIDs.insert(info.id)
            phase = .ready
            select(info.id)
        } catch {
            actionError = (error as? OCTerminalClientError) == .outdated ? OCTerminalText.outdated : OCTerminalText.createFailed
        }
    }

    func select(_ id: String) {
        guard let client else { return }
        if activeID == id, connection?.ptyID == id {
            connection?.start()
            return
        }
        connection?.disconnect()
        activeID = id
        let next = OCTerminalConnection(ptyID: id, client: client)
        connection = next
        next.start()
    }

    /// Ends the terminal on the server (the tab's close button), then shows its neighbour.
    func close(_ id: String) async {
        guard let client else { return }
        do {
            try await client.remove(ptyID: id)
        } catch {
            actionError = OCTerminalText.closeFailed
            return
        }
        let index = terminals.firstIndex { $0.id == id }
        terminals.removeAll { $0.id == id }
        guard activeID == id else { return }
        connection?.disconnect()
        connection = nil
        activeID = nil
        if let index, !terminals.isEmpty {
            select(terminals[min(index, terminals.count - 1)].id)
        }
    }

    /// The tab label: the shell's live title, else the server's.
    func title(for info: OCTerminalInfo) -> String {
        if info.id == connection?.ptyID, let live = connection?.title, !live.isEmpty { return live }
        return info.title.isEmpty ? OCTerminalText.tabTitle : info.title
    }

    /// Detaches (leaving the session screen); the terminals keep running on the server.
    func disconnect() {
        connection?.disconnect()
    }
}
