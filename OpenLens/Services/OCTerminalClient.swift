import Foundation
import os

/// One terminal of a session, as the server lists it (`PersistentPty.Info`, the fields the app reads).
nonisolated struct OCTerminalInfo: Decodable, Equatable, Sendable, Identifiable {
    struct Size: Codable, Equatable, Sendable {
        let cols: Int
        let rows: Int
    }

    struct Output: Decodable, Equatable, Sendable {
        let head: Int
        let tail: Int
    }

    let id: String
    let title: String
    let cwd: String?
    let status: String?
    let sessionID: String?
    let size: Size?
    let output: Output?
}

/// The screen the server last saw for a terminal: its info, the plain text and an escape-sequence
/// checkpoint that redraws the screen (colours, cursor) in an emulator.
nonisolated struct OCTerminalSnapshot: Sendable {
    let info: OCTerminalInfo
    let text: String
    let checkpoint: Data
}

nonisolated enum OCTerminalClientError: Error, LocalizedError, Equatable {
    /// 503: the server's terminal service isn't running.
    case unavailable
    /// 404 / 405 on the session terminal routes: the server predates persistent terminals.
    case outdated
    /// 404 on a terminal route: the terminal no longer exists.
    case notFound
    case status(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: AppText.ocTerminalUnavailable
        case .outdated: AppText.ocTerminalOutdated
        case .notFound: AppText.ocTerminalDisconnected
        case .status(let code, let message): message.isEmpty ? "HTTP \(code)" : message
        case .invalidResponse: AppText.ocTerminalConnectionFailed
        }
    }
}

/// REST side of the web's persistent terminals (`/api/experimental/session/{id}/terminal`,
/// `/api/experimental/persistent-pty/{id}…`), with the app's credentials. The live screen goes
/// through `OCTerminalSocket`.
nonisolated struct OCTerminalClient: Sendable {
    let baseURL: URL
    let authHeader: String?
    var session: URLSession = .shared

    /// The session's terminals, in the server's order.
    func list(sessionID: String) async throws -> [OCTerminalInfo] {
        let data = try await send("GET", "api/experimental/session/\(Self.segment(sessionID))/terminal", sessionRoute: true)
        return try Self.decodeData([OCTerminalInfo].self, from: data)
    }

    /// Creates a terminal the way the web does: the default shell in the session's folder.
    func create(sessionID: String, cwd: String?, title: String) async throws -> OCTerminalInfo {
        var body: [String: Any] = ["args": [String](), "title": title, "env": [String: String]()]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        let data = try await send(
            "POST", "api/experimental/session/\(Self.segment(sessionID))/terminal",
            body: try JSONSerialization.data(withJSONObject: body), sessionRoute: true
        )
        return try Self.decodeData(OCTerminalInfo.self, from: data)
    }

    func snapshot(ptyID: String) async throws -> OCTerminalSnapshot {
        let data = try await send("GET", "api/experimental/persistent-pty/\(Self.segment(ptyID))/snapshot")
        return try Self.decodeSnapshot(data)
    }

    /// A short-lived, single-use ticket for the WebSocket (the server refuses it without the header).
    func connectToken(ptyID: String) async throws -> String {
        let data = try await send(
            "POST", "api/experimental/persistent-pty/\(Self.segment(ptyID))/connect-token",
            headers: ["x-opencode-ticket": "1"]
        )
        struct Token: Decodable { let ticket: String }
        return try Self.decodeData(Token.self, from: data).ticket
    }

    /// Ends the terminal on the server (the web's tab close). A terminal already gone counts as closed.
    func remove(ptyID: String) async throws {
        do {
            _ = try await send("DELETE", "api/experimental/persistent-pty/\(Self.segment(ptyID))")
        } catch OCTerminalClientError.notFound {
            return
        }
    }

    /// The WebSocket request: ticket, output cursor, this attachment's id, taking control, framed input.
    func socketRequest(ptyID: String, ticket: String, cursor: Int, attachmentID: String) -> URLRequest {
        var url = baseURL.appending(path: "api/experimental/persistent-pty/\(Self.segment(ptyID))/connect")
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            components.queryItems = [
                URLQueryItem(name: "ticket", value: ticket),
                URLQueryItem(name: "cursor", value: String(cursor)),
                URLQueryItem(name: "attachment_id", value: attachmentID),
                URLQueryItem(name: "takeover", value: "true"),
                URLQueryItem(name: "input_protocol", value: "1"),
            ]
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        return request
    }

    // MARK: Helpers

    private func send(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        headers: [String: String] = [:],
        sessionRoute: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OCTerminalClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data, sessionRoute: sessionRoute)
        }
        return data
    }

    static func error(status: Int, data: Data, sessionRoute: Bool) -> OCTerminalClientError {
        if status == 503 { return .unavailable }
        if sessionRoute, status == 404 || status == 405 { return .outdated }
        if status == 404 { return .notFound }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        return .status(status, message ?? "")
    }

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? value
    }

    static func decodeData<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(OCTerminalEnvelope<T>.self, from: data).data
    }

    /// The checkpoint is a base64 string in the JSON (Schema.Uint8Array); an array of bytes is accepted too.
    static func decodeSnapshot(_ data: Data) throws -> OCTerminalSnapshot {
        struct Raw: Decodable {
            let info: OCTerminalInfo
            let text: String?
            let checkpoint: Checkpoint
        }
        struct Checkpoint: Decodable {
            let bytes: Data
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    bytes = Data(base64Encoded: text) ?? Data()
                } else {
                    bytes = Data(try container.decode([UInt8].self))
                }
            }
        }
        let raw = try decodeData(Raw.self, from: data)
        return OCTerminalSnapshot(info: raw.info, text: raw.text ?? "", checkpoint: raw.checkpoint.bytes)
    }
}

/// The `{ "data": … }` wrapper of the v2 API's answers.
nonisolated private struct OCTerminalEnvelope<T: Decodable>: Decodable {
    let data: T
}

// MARK: - Socket protocol

/// The persistent PTY WebSocket protocol (input_protocol=1), as `@opencode/client`'s
/// `persistentPtyFrame` / `decodePersistentPtyMessage` define it.
nonisolated enum OCTerminalProtocol {
    /// A text message from the socket; output arrives as binary frames instead.
    enum Message: Equatable, Sendable {
        case attached(inputProtocol: Int, cols: Int, rows: Int, role: String?)
        case replayComplete
        case resized(cols: Int, rows: Int, checkpoint: Data)
        case controllerChanged(attachmentID: String?)
        case exited(code: Int?)
        case titleChanged(String)
        case other
    }

    /// `[type u8][cols u16 BE][rows u16 BE][data]`: type 0 takes control at the size, type 1 types `data`.
    static func frame(cols: Int, rows: Int, data: Data? = nil) -> Data {
        var frame = Data(capacity: 5 + (data?.count ?? 0))
        let c = UInt16(clamping: cols)
        let r = UInt16(clamping: rows)
        frame.append(data == nil ? 0 : 1)
        frame.append(UInt8(c >> 8)); frame.append(UInt8(c & 0xff))
        frame.append(UInt8(r >> 8)); frame.append(UInt8(r & 0xff))
        if let data { frame.append(data) }
        return frame
    }

    static func decode(_ text: String) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "attached":
            let size = (object["info"] as? [String: Any])?["size"] as? [String: Any]
            guard let cols = size?["cols"] as? Int, let rows = size?["rows"] as? Int else { return nil }
            return .attached(
                inputProtocol: object["inputProtocol"] as? Int ?? 0,
                cols: cols, rows: rows,
                role: object["role"] as? String
            )
        case "replay_complete":
            return .replayComplete
        case "resized":
            guard let cols = object["cols"] as? Int, let rows = object["rows"] as? Int else { return nil }
            let checkpoint = (object["checkpoint"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            return .resized(cols: cols, rows: rows, checkpoint: checkpoint)
        case "controller_changed":
            return .controllerChanged(attachmentID: object["attachmentID"] as? String)
        case "exited":
            return .exited(code: object["exitCode"] as? Int)
        case "title_changed":
            return (object["title"] as? String).map { .titleChanged($0) }
        default:
            return .other
        }
    }
}

/// One WebSocket attachment to a PTY. Messages are handed to `onMessage` one at a time, in order,
/// on the main actor; `onClose` runs once when the socket ends (nil = closed normally).
final class OCTerminalSocket {
    enum Incoming {
        case output(Data)
        case message(String)
    }

    private let task: URLSessionWebSocketTask
    private var receiving: Task<Void, Never>?
    private var closed = false

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    /// Safety net: a socket nobody closed still ends its connection.
    deinit {
        task.cancel(with: .goingAway, reason: nil)
    }

    func start(onMessage: @escaping (Incoming) -> Void, onClose: @escaping (Error?) -> Void) {
        task.resume()
        let task = self.task
        receiving = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .data(let data): onMessage(.output(data))
                    case .string(let text): onMessage(.message(text))
                    @unknown default: break
                    }
                } catch {
                    guard let self, !self.closed else { return }
                    self.closed = true
                    onClose(task.closeCode == .normalClosure ? nil : error)
                    return
                }
            }
        }
    }

    func send(_ frame: Data) {
        guard !closed else { return }
        task.send(.data(frame)) { error in
            if let error { Logger.api.debug("Terminal send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        receiving?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }
}
