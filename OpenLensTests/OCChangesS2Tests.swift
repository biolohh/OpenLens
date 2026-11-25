import Foundation
import Testing
@testable import OpenLens

/// Answers by "METHOD /path"; anything unlisted is a 404. Records every request it saw.
nonisolated final class S2RecordingTransport: OpenCodeTransport, @unchecked Sendable {
    struct Route: Sendable {
        let statusCode: Int
        let body: Data
        static func ok(_ json: String) -> Route { Route(statusCode: 200, body: Data(json.utf8)) }
        static func status(_ code: Int, _ json: String = "{}") -> Route { Route(statusCode: code, body: Data(json.utf8)) }
    }

    private let lock = NSLock()
    private let routes: [String: Route]
    private var seen: [URLRequest] = []

    init(routes: [String: Route]) { self.routes = routes }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        lock.lock(); seen.append(request); lock.unlock()
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        let route = routes[key] ?? .status(404, #"{"error":"RouteNotFound"}"#)
        return (route.body, HTTPURLResponse(url: url, statusCode: route.statusCode, httpVersion: nil, headerFields: nil)!)
    }

    func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        S2UnusedEventStream()
    }

    func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    func requests(matching key: String) -> [URLRequest] {
        requests().filter { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" == key }
    }
}

nonisolated private final class S2UnusedEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}

func s2Query(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

@MainActor
struct OCChangesS2Tests {
    private static let base = "https://opencode.example.com"

    private func makeService(routes: [String: S2RecordingTransport.Route]) async throws -> (ReviewService, S2RecordingTransport) {
        var all = routes
        all["GET /api/info"] = .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)
        let transport = S2RecordingTransport(routes: all)
        let client = OpenCodeClient(baseURL: try #require(URL(string: Self.base)), authHeader: "Basic abc", transport: transport)
        let capabilities = try await client.probeCapabilities()
        let service = ReviewService(connection: ConnectionManager(testClient: client, capabilities: capabilities))
        service.vcsTransport = transport
        return (service, transport)
    }

    // MARK: Branch mode

    @Test func vcsInfoDecodesTheDefaultBranch() throws {
        let located = try JSONDecoder().decode(
            OCV2Located<OCVCSInfo>.self,
            from: Data(#"{"location":{"directory":"/r"},"data":{"provider":"git","branch":{"current":"feature","default":"main"}}}"#.utf8)
        )
        #expect(located.data.branch == "feature")
        #expect(located.data.defaultBranch == "main")
        #expect(located.data.offersBranchChanges)
        #expect(!OCVCSInfo(branch: "main", defaultBranch: "main").offersBranchChanges)
        #expect(!OCVCSInfo(branch: "main", defaultBranch: nil).offersBranchChanges)
    }

    @Test func branchModeIsOfferedOnlyOffTheDefaultBranch() async throws {
        let project = #"[{"id":"p1","worktree":"/repo","vcs":"git"}]"#
        let (offered, _) = try await makeService(routes: [
            "GET /api/project": .ok(project),
            "GET /api/vcs": .ok(#"{"location":{"directory":"/repo"},"data":{"branch":{"current":"feature","default":"main"}}}"#),
        ])
        let withBranch = try await offered.changesAvailability(sessionID: "s", directory: "/repo", projectID: "p1")
        #expect(withBranch.modes == [.git, .branch, .turn])
        #expect(withBranch.directory == "/repo")

        let (onDefault, _) = try await makeService(routes: [
            "GET /api/project": .ok(project),
            "GET /api/vcs": .ok(#"{"location":{"directory":"/repo"},"data":{"branch":{"current":"main","default":"main"}}}"#),
        ])
        #expect(try await onDefault.changesAvailability(sessionID: "s", directory: "/repo", projectID: "p1").modes == [.git, .turn])
    }

    @Test func branchChangesAskForModeBranchAtTheProjectFolder() async throws {
        let (service, transport) = try await makeService(routes: [
            "GET /api/vcs/diff": .ok(#"{"location":{"directory":"/repo"},"data":[{"file":"a.swift","patch":"@@ -1 +1 @@\n-x\n+y\n","additions":1,"deletions":1,"status":"modified"}]}"#),
        ])
        let files = try await service.loadChanges(sessionID: "s", mode: .branch, directory: "/repo")
        #expect(files.map(\.path) == ["a.swift"])
        let request = try #require(transport.requests(matching: "GET /api/vcs/diff").first)
        #expect(s2Query(request, "mode") == "branch")
        #expect(s2Query(request, "location[directory]") == "/repo")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic abc")
    }

    // MARK: Create Git repository

    @Test func createGitRepositoryPostsProviderGitForExactlyTheGivenFolder() async throws {
        let (service, transport) = try await makeService(routes: ["POST /api/vcs/init": .status(204, "")])
        try await service.initGitRepository(directory: "/work/site")
        let sent = transport.requests(matching: "POST /api/vcs/init")
        #expect(sent.count == 1)
        #expect(s2Query(sent[0], "provider") == "git")
        #expect(s2Query(sent[0], "location[directory]") == "/work/site")
        #expect(sent[0].value(forHTTPHeaderField: "Authorization") == "Basic abc")
        #expect(sent[0].timeoutInterval == 30)
    }

    @Test func createGitRepositorySendsNothingWithoutAFolder() async throws {
        let (service, transport) = try await makeService(routes: ["POST /api/vcs/init": .status(204, "")])
        await #expect(throws: OCVCSError.self) { try await service.initGitRepository(directory: nil) }
        await #expect(throws: OCVCSError.self) { try await service.initGitRepository(directory: "  ") }
        #expect(transport.requests(matching: "POST /api/vcs/init").isEmpty)
    }

    @Test func createGitRepositoryErrorsSurface() async throws {
        let (service, _) = try await makeService(routes: [
            "POST /api/vcs/init": .status(409, #"{"_tag":"ConflictError","message":"Already a repository"}"#),
        ])
        await #expect(throws: OpenCodeError.self) { try await service.initGitRepository(directory: "/work/site") }
    }
}
