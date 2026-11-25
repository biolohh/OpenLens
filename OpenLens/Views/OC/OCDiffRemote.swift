import Foundation

/// Requests of the Changes tab that `OpenCodeClient` has no method for: the working tree /
/// branch diff of an explicit folder, the VCS info of a folder, and `vcs.init`. They open their
/// own request from the connected server's endpoint and always name the folder in
/// `location[directory]`, so none of them can fall back to the client's active folder.
nonisolated enum OCVCSRemote {
    /// The web's `vcs.init` and `vcs.diff` give up after this long.
    static let timeout: TimeInterval = 30

    enum Diff: String, Sendable {
        case working
        case branch
    }

    static func request(
        baseURL: URL,
        authHeader: String?,
        method: String,
        endpoint: String,
        directory: String,
        queryItems: [URLQueryItem] = []
    ) -> URLRequest {
        let rawPath = endpoint.hasPrefix("/") ? String(endpoint.dropFirst()) : endpoint
        var url = baseURL.appending(path: rawPath)
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems + [URLQueryItem(name: "location[directory]", value: directory)]
            url = components.url ?? url
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func diffRequest(baseURL: URL, authHeader: String?, directory: String, mode: Diff) -> URLRequest {
        request(
            baseURL: baseURL, authHeader: authHeader, method: "GET", endpoint: "/api/vcs/diff", directory: directory,
            queryItems: [URLQueryItem(name: "mode", value: mode.rawValue), URLQueryItem(name: "untracked", value: "folders")]
        )
    }

    static func infoRequest(baseURL: URL, authHeader: String?, directory: String) -> URLRequest {
        request(baseURL: baseURL, authHeader: authHeader, method: "GET", endpoint: "/api/vcs", directory: directory)
    }

    static func initRequest(baseURL: URL, authHeader: String?, directory: String) -> URLRequest {
        request(
            baseURL: baseURL, authHeader: authHeader, method: "POST", endpoint: "/api/vcs/init", directory: directory,
            queryItems: [URLQueryItem(name: "provider", value: "git")]
        )
    }

    /// Same mapping as the client's own response check.
    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenCodeError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if let payload = try? JSONDecoder().decode(OpenCodeAPIErrorPayload.self, from: data) {
                throw OpenCodeError.apiError(statusCode: http.statusCode, payload: payload)
            }
            throw OpenCodeError.httpError(statusCode: http.statusCode)
        }
    }
}

nonisolated enum OCVCSError: LocalizedError {
    /// No folder to act on, or not connected: the web's "Request failed".
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: AppText.ocRequestFailed
        }
    }
}

extension OCVCSInfo {
    /// The web lists "Branch changes" only while the current branch differs from the default one.
    nonisolated var offersBranchChanges: Bool {
        guard let branch = branch?.nilIfBlank, let defaultBranch = defaultBranch?.nilIfBlank else { return false }
        return branch != defaultBranch
    }
}

/// What the no-git state shows when "Create Git repository" fails (the web's failure toast text).
nonisolated enum OCGitInitMessage {
    static func text(for error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .timedOut { return AppText.ocGitTimeout }
        if case OpenCodeError.apiError(_, let payload) = error, let message = payload.message?.nilIfBlank { return message }
        return error.localizedDescription
    }
}
