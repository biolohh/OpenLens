import Foundation
import Observation
import os

/// Default terminal titles ("Terminal 2"), numbered like the web's `defaultTitle`.
nonisolated enum OCTerminalTitles {
    /// The number of a default title such as "Terminal 2".
    static func number(_ title: String) -> Int? {
        guard title.hasPrefix("Terminal ") else { return nil }
        let digits = title.dropFirst("Terminal ".count)
        guard let first = digits.first, first != "0", digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// The lowest default number the given terminals don't use yet.
    static func next(after titles: [String]) -> Int {
        let used = Set(titles.compactMap(number))
        return (1...(used.count + 1)).first { !used.contains($0) } ?? 1
    }
}

/// A change to a session's terminal list from any client (`persistent-pty.*` on the event stream;
/// the web's model refreshes the session on `added` / `removed` and patches it on `updated`).
nonisolated struct OCTerminalEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case added, removed, updated }

    let kind: Kind
    let sessionID: String
    let ptyID: String?
    /// `updated` carries the terminal's new info.
    let terminal: OCTerminalInfo?

    static let notification = Notification.Name("OpenLens.terminalListChanged")
    /// The event stream (re)connected: events may have been missed, so every list is read again
    /// (the web's model does the same on `server.connected`).
    static let resyncNotification = Notification.Name("OpenLens.terminalListResync")

    static func postResync() {
        NotificationCenter.default.post(name: resyncNotification, object: nil)
    }

    init(kind: Kind, sessionID: String, ptyID: String?, terminal: OCTerminalInfo?) {
        self.kind = kind
        self.sessionID = sessionID
        self.ptyID = ptyID
        self.terminal = terminal
    }

    init?(type: String, data: [String: Any]) {
        guard let sessionID = data["sessionID"] as? String, !sessionID.isEmpty else { return nil }
        switch type {
        case "persistent-pty.added": kind = .added
        case "persistent-pty.removed": kind = .removed
        case "persistent-pty.updated": kind = .updated
        default: return nil
        }
        self.sessionID = sessionID
        var info: OCTerminalInfo?
        if let raw = data["terminal"] as? [String: Any],
           let json = try? JSONSerialization.data(withJSONObject: raw) {
            info = try? JSONDecoder().decode(OCTerminalInfo.self, from: json)
        }
        terminal = info
        ptyID = data["ptyID"] as? String ?? info?.id
    }

    /// Hands the event to the open Terminal tabs (any thread; they read it on the main queue).
    static func post(_ event: OCTerminalEvent) {
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["event": event])
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
    /// Asked when the terminal could not be reached (404, socket closed): true while it still
    /// exists on the server. A terminal closed elsewhere then leaves quietly instead of showing
    /// "Terminal disconnected".
    @ObservationIgnored var stillExists: (@MainActor (String) async -> Bool)?

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
            ended((error as? OCTerminalClientError) == .notFound ? AppText.ocTerminalDisconnected : AppText.ocTerminalConnectionFailed)
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
                fail(AppText.ocTerminalServerOutdated)
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
        ended(AppText.ocTerminalDisconnected)
    }

    /// The attachment ended without being asked to: checks the terminal still exists before
    /// showing `message`; when it is gone the store drops it.
    private func ended(_ message: String) {
        socket?.close()
        socket = nil
        guard let stillExists else {
            fail(message)
            return
        }
        let current = attempt
        Task { [weak self, ptyID] in
            let exists = await stillExists(ptyID)
            guard let self, exists, self.attempt == current, self.socket == nil else { return }
            self.fail(message)
        }
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
/// own: only the tab's close button does, as on the web. The list follows other clients through
/// the event stream, and is read again on every visit and on returning to the foreground.
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
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Mobile placement: the first visit to a session without terminals creates one.
    @ObservationIgnored private var seedsEmpty = true
    /// Bumped by every create and close, so a list read that raced one is read again.
    @ObservationIgnored private var mutations = 0
    @ObservationIgnored private var backgrounded = false
    @ObservationIgnored private nonisolated(unsafe) var eventObservers: [NSObjectProtocol] = []
    /// One list read at a time; a change announced meanwhile reads it once more afterwards.
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshDirty = false

    /// `client` is for tests; the app builds it from the connection's endpoint on `appear`.
    init(sessionID: String, directory: String?, client: OCTerminalClient? = nil) {
        self.sessionID = sessionID
        self.directory = directory
        self.client = client
        let center = NotificationCenter.default
        eventObservers = [
            center.addObserver(forName: OCTerminalEvent.notification, object: nil, queue: .main) { [weak self] note in
                guard let event = note.userInfo?["event"] as? OCTerminalEvent else { return }
                MainActor.assumeIsolated { self?.receive(event) }
            },
            center.addObserver(forName: OCTerminalEvent.resyncNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.listChangedElsewhere() }
            },
        ]
    }

    deinit {
        eventObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Lists the session's terminals; the first time, an empty list gets a new terminal (the
    /// narrow-screen web does the same). Later visits re-read the list quietly and reattach the
    /// shown terminal if its socket ended.
    func appear(apiClient: OpenCodeClient?, isV2: Bool, seedsEmpty: Bool = true) async {
        self.seedsEmpty = seedsEmpty
        guard isV2, let apiClient else {
            phase = .unavailable(AppText.ocTerminalUnavailable)
            return
        }
        await updateEndpoint(apiClient)
        if phase == .ready {
            attachShown()
            await refresh()
            attachShown()
            return
        }
        await reload()
    }

    /// The visit attaches: the shown terminal (reattaching after a failure), else the first one.
    /// Only here and on a chip tap does the app take control of a terminal.
    private func attachShown() {
        guard phase == .ready else { return }
        if let connection {
            if case .failed = connection.status { connection.reconnect() } else { connection.start() }
        } else if let id = activeID ?? terminals.first?.id {
            select(id)
        }
    }

    /// The server URL or credentials changed (Settings): later calls and a new attachment use them.
    /// True when it started a new attachment.
    @discardableResult
    private func updateEndpoint(_ apiClient: OpenCodeClient) async -> Bool {
        let endpoint = await apiClient.connectionEndpoint()
        guard Self.endpointChanged(client, baseURL: endpoint.baseURL, authHeader: endpoint.authHeader) else { return false }
        let hadClient = client != nil
        client = OCTerminalClient(baseURL: endpoint.baseURL, authHeader: endpoint.authHeader)
        guard hadClient, let activeID, connection != nil else { return false }
        connection?.disconnect()
        connection = nil
        self.activeID = nil
        select(activeID)
        return true
    }

    nonisolated static func endpointChanged(_ client: OCTerminalClient?, baseURL: URL, authHeader: String?) -> Bool {
        guard let client else { return true }
        return client.baseURL != baseURL || client.authHeader != authHeader
    }

    /// The app went to the background: detach now, so the suspended socket can't die unseen.
    func background() {
        guard phase == .ready else { return }
        backgrounded = true
        connection?.disconnect()
    }

    /// Back in the foreground: a new attachment (snapshot + replay from its tail, so nothing is
    /// shown twice) and a fresh list.
    func foreground(apiClient: OpenCodeClient?) async {
        guard backgrounded else { return }
        backgrounded = false
        // A changed endpoint already started a new attachment.
        var reattached = false
        if let apiClient { reattached = await updateEndpoint(apiClient) }
        if !reattached { connection?.reconnect() }
        await refresh()
    }

    /// Lists (and on the first visit seeds) in a task the store owns: leaving the tab cancels the
    /// view's task, but a create already sent must still land in `terminals`, never as a hidden
    /// terminal on the server.
    func reload() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.load() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func load() async {
        guard let client else { return }
        phase = .loading
        do {
            let items = try await client.list(sessionID: sessionID)
            terminals = items
            let firstLoad = !loadedOnce
            loadedOnce = true
            phase = .ready
            if items.isEmpty {
                if firstLoad, seedsEmpty { await create() }
            } else {
                select(activeID.flatMap { id in items.first { $0.id == id }?.id } ?? items[0].id)
            }
            // A change announced while the first list was on its way.
            if refreshDirty { listChangedElsewhere() }
        } catch let error as OCTerminalClientError {
            switch error {
            case .unavailable, .outdated: phase = .unavailable(error.localizedDescription)
            default: phase = .failed(error.localizedDescription)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads the list again without a loading state: terminals opened elsewhere appear, closed
    /// ones disappear. One read at a time, applied in order; a change announced during a read
    /// reads once more.
    func refresh() async {
        guard client != nil, phase == .ready else { return }
        if refreshing {
            refreshDirty = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        var attempts = 0
        repeat {
            refreshDirty = false
            attempts += 1
            guard let client else { return }
            let before = mutations
            guard let items = try? await client.list(sessionID: sessionID) else { return }
            // A create or close of this screen finished meanwhile: this answer may predate it.
            guard before == mutations else {
                refreshDirty = true
                continue
            }
            apply(items)
        } while refreshDirty && attempts < 5
    }

    /// The list as the server has it, from a change made elsewhere. It never attaches (no takeover
    /// of a terminal someone else is using): a shown terminal that is gone hands the selection to
    /// its neighbour, which attaches on the next visit or chip tap.
    func apply(_ items: [OCTerminalInfo]) {
        let previous = terminals
        terminals = items
        guard let activeID, !items.contains(where: { $0.id == activeID }) else { return }
        connection?.disconnect()
        connection = nil
        let index = previous.firstIndex { $0.id == activeID } ?? 0
        self.activeID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
    }

    /// An event said this session's list changed (or the stream reconnected).
    private func listChangedElsewhere() {
        guard phase == .ready else {
            refreshDirty = true
            return
        }
        Task { await refresh() }
    }

    private func receive(_ event: OCTerminalEvent) {
        guard event.sessionID == sessionID else { return }
        switch event.kind {
        case .added, .removed:
            listChangedElsewhere()
        case .updated:
            guard let info = event.terminal, let index = terminals.firstIndex(where: { $0.id == info.id }) else { return }
            terminals[index] = info
        }
    }

    /// Whether the terminal is still on the server; a gone one is dropped from the list.
    private func exists(_ ptyID: String) async -> Bool {
        guard let client, let items = try? await client.list(sessionID: sessionID) else { return true }
        if items.contains(where: { $0.id == ptyID }) { return true }
        apply(items)
        return false
    }

    func create() async {
        guard let client, !creating else { return }
        creating = true
        defer { creating = false }
        do {
            let title = AppText.ocTerminalNumbered(OCTerminalTitles.next(after: terminals.map(\.title)))
            let info = try await client.create(sessionID: sessionID, cwd: directory, title: title)
            mutations += 1
            if !terminals.contains(where: { $0.id == info.id }) { terminals.append(info) }
            createdIDs.insert(info.id)
            phase = .ready
            select(info.id)
        } catch {
            actionError = (error as? OCTerminalClientError) == .outdated ? AppText.ocTerminalOutdated : AppText.ocTerminalCreateFailed
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
        next.stillExists = { [weak self] ptyID in
            await self?.exists(ptyID) ?? true
        }
        connection = next
        next.start()
    }

    /// Ends the terminal on the server (the tab's close button), then shows its neighbour.
    func close(_ id: String) async {
        guard let client else { return }
        // Detach first: the server ends the socket before it answers the DELETE, which would
        // otherwise flash "Terminal disconnected".
        let closingActive = activeID == id
        if closingActive { connection?.disconnect() }
        do {
            try await client.remove(ptyID: id)
        } catch {
            actionError = AppText.ocTerminalCloseFailed
            if closingActive { connection?.start() }
            return
        }
        mutations += 1
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
        return info.title.isEmpty ? AppText.ocTerminalTabTitle : info.title
    }

    /// Detaches (leaving the session screen); the terminals keep running on the server.
    func disconnect() {
        connection?.disconnect()
    }
}
