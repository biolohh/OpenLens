import Foundation

final class ReviewService {

    private let connection: ConnectionManager
    /// Carries the Changes tab's own VCS requests (`OCVCSRemote`); tests replace it.
    var vcsTransport: any OpenCodeTransport = DirectOpenCodeTransport()

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    func loadReview(sessionID: String) async throws -> SessionReviewSnapshot {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.reviewSnapshot(sessionID: sessionID)
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let messages = try await client.listMessages(sessionID: sessionID)
        let userMessages = messages.filter { $0.info.role == .user }

        // Without a user message nothing can have been changed.
        guard let firstMessage = userMessages.first, let lastMessage = userMessages.last else {
            return SessionReviewSnapshot(sessionID: sessionID, changeSets: [], workingTree: [])
        }

        async let sessionDiffTask = loadSessionDiff(
            client: client,
            sessionID: sessionID,
            firstMessageID: firstMessage.id,
            lastMessageID: lastMessage.id
        )
        let changeSets = try await loadChangeSets(sessionID: sessionID, messages: messages)
        let sessionDiff = try await sessionDiffTask

        return SessionReviewSnapshot(
            sessionID: sessionID,
            changeSets: changeSets,
            workingTree: sessionDiff ?? newestFiles(of: changeSets)
        )
    }

    /// Everything the session changed, or `nil` when the server refuses the
    /// range (it rejects ranges that span a location change).
    private func loadSessionDiff(
        client: OpenCodeClient,
        sessionID: String,
        firstMessageID: String,
        lastMessageID: String
    ) async throws -> [ReviewFileChange]? {
        do {
            let diffs = try await client.getWholeSessionDiff(
                sessionID: sessionID,
                firstMessageID: firstMessageID,
                lastMessageID: lastMessageID
            )
            return diffs.map(ReviewFileChange.init(diff:))
        } catch OpenCodeError.apiError(let statusCode, _) where (400..<500).contains(statusCode) {
            return nil
        } catch OpenCodeError.httpError(let statusCode) where (400..<500).contains(statusCode) {
            return nil
        }
    }

    /// Stand-in for the session diff when the server refuses it: the latest
    /// version of every file the per-update diffs touched. Line totals only
    /// reflect the last update that touched a file.
    private func newestFiles(of changeSets: [ReviewChangeSet]) -> [ReviewFileChange] {
        var seenPaths = Set<String>()
        return changeSets
            .flatMap(\.files)
            .filter { seenPaths.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    func revertChangeSet(sessionID: String, messageID: String) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        _ = try await client.revertMessage(sessionID: sessionID, messageID: messageID)
    }

    private func loadChangeSets(sessionID: String, messages: [OCMessageWithParts]) async throws -> [ReviewChangeSet] {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let candidateMessages = messages
            .filter { $0.info.role == .user }
            .sorted { lhs, rhs in
                (lhs.info.createdTimestamp ?? 0) > (rhs.info.createdTimestamp ?? 0)
            }

        var seenFingerprints = Set<String>()
        var changeSets: [ReviewChangeSet] = []

        for message in candidateMessages.prefix(20) {
            let diffs = try await client.getSessionDiff(sessionID: sessionID, messageID: message.id)
            let files = diffs.map(ReviewFileChange.init(diff:))

            guard !files.isEmpty else { continue }

            let fingerprint = makeFingerprint(files)
            guard seenFingerprints.insert(fingerprint).inserted else { continue }

            changeSets.append(
                ReviewChangeSet(
                    id: message.id,
                    title: changeSetTitle(for: message),
                    createdAt: message.info.createdTimestamp.map { Date(timeIntervalSince1970: $0) },
                    messagePreview: messagePreview(for: message),
                    files: files
                )
            )
        }

        return changeSets.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (left?, right?): left > right
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): lhs.title < rhs.title
            }
        }
    }

    private func changeSetTitle(for message: OCMessageWithParts) -> String {
        if let summaryTitle = message.info.summary?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return summaryTitle
        }

        if let firstText = message.parts
            .compactMap(\ .text)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstText
        }

        return "Change set"
    }

    private func messagePreview(for message: OCMessageWithParts) -> String? {
        message.parts
            .compactMap(\ .text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func makeFingerprint(_ files: [ReviewFileChange]) -> String {
        files
            .sorted { $0.path < $1.path }
            .map { "\($0.path)|\($0.status)|\($0.additions)|\($0.deletions)" }
            .joined(separator: "#")
    }

    // MARK: - Web-style Changes tab

    /// What the Changes tab of one session can show, like the web's review modes.
    func changesAvailability(sessionID: String, directory: String?, projectID: String?) async throws -> OCChangesAvailability {
        if ScreenshotFixtures.isEnabled {
            return OCChangesAvailability(isGit: true, modes: [.turn])
        }
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        // v1 servers have no working-tree diff route: only the newest turn can be shown.
        guard connection.serverCapabilities?.protocolVersion == .v2 else {
            return OCChangesAvailability(isGit: true, modes: [.turn])
        }
        let projects = try await client.listProjects()
        // The session's project by id, else the project whose folder holds the session's folder
        // (the deepest one when they nest).
        let project = projects.first { projectID != nil && $0.id == projectID }
            ?? projects
            .filter { OCFileSupport.isInside(directory, root: $0.worktree) }
            .max { ($0.worktree?.count ?? 0) < ($1.worktree?.count ?? 0) }
        guard project?.vcs?.lowercased() == "git" else {
            return OCChangesAvailability(isGit: false, modes: [], directory: directory)
        }
        // Like the web, the repository is read at the project's root.
        let root = project?.worktree?.nilIfBlank ?? directory
        var modes: [OCChangesMode] = [.git]
        if let root, let info = try? await vcsInfo(directory: root), info.offersBranchChanges {
            modes.append(.branch)
        }
        modes.append(.turn)
        return OCChangesAvailability(isGit: true, modes: modes, directory: root)
    }

    /// The files of one mode: `git` is the working tree, `branch` the branch against the default
    /// branch, `turn` the newest turn of the session.
    func loadChanges(sessionID: String, mode: OCChangesMode, directory: String? = nil) async throws -> [ReviewFileChange] {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.reviewSnapshot(sessionID: sessionID).workingTree
        }
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let diffs: [OCFileDiff]
        switch mode {
        case .git:
            if let directory {
                diffs = try await vcsDiff(directory: directory, mode: .working)
            } else {
                diffs = try await client.getWorkingTreeDiff()
            }
        case .branch:
            guard let directory else { throw OCVCSError.unavailable }
            diffs = try await vcsDiff(directory: directory, mode: .branch)
        case .turn:
            diffs = try await client.getSessionDiff(sessionID: sessionID)
        }
        // Patch parsing and line counting of big diffs stay off the main actor.
        return await Task.detached(priority: .userInitiated) {
            diffs.map { ReviewFileChange(diff: $0) }
        }.value
    }

    /// The web's "Create a Git repository": `POST /api/vcs/init?provider=git` for exactly the
    /// given folder (never the client's active one). Without a folder nothing is sent.
    func initGitRepository(directory: String?) async throws {
        guard let directory = directory?.nilIfBlank else { throw OCVCSError.unavailable }
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let endpoint = await client.connectionEndpoint()
        let request = OCVCSRemote.initRequest(baseURL: endpoint.baseURL, authHeader: endpoint.authHeader, directory: directory)
        let (data, response) = try await vcsTransport.data(for: request)
        try OCVCSRemote.validate(response, data: data)
    }

    func vcsInfo(directory: String) async throws -> OCVCSInfo {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let endpoint = await client.connectionEndpoint()
        let request = OCVCSRemote.infoRequest(baseURL: endpoint.baseURL, authHeader: endpoint.authHeader, directory: directory)
        let (data, response) = try await vcsTransport.data(for: request)
        try OCVCSRemote.validate(response, data: data)
        return try JSONDecoder().decode(OCV2Located<OCVCSInfo>.self, from: data).data
    }

    private func vcsDiff(directory: String, mode: OCVCSRemote.Diff) async throws -> [OCFileDiff] {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let endpoint = await client.connectionEndpoint()
        let request = OCVCSRemote.diffRequest(
            baseURL: endpoint.baseURL, authHeader: endpoint.authHeader, directory: directory, mode: mode
        )
        let (data, response) = try await vcsTransport.data(for: request)
        try OCVCSRemote.validate(response, data: data)
        return try JSONDecoder().decode(OCV2Located<[OCFileDiff]>.self, from: data).data
    }
}
