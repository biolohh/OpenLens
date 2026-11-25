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
        if let delay { try await Task.sleep(for: delay) }
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        lock.lock(); let override = overrides[key]; lock.unlock()
        let route = override ?? routes[key] ?? .status(404, #"{"error":"RouteNotFound"}"#)
        return (route.body, HTTPURLResponse(url: url, statusCode: route.statusCode, httpVersion: nil, headerFields: nil)!)
    }

    func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        S2UnusedEventStream()
    }

    /// Answers after this long (a hung request stays until cancelled when it is large).
    nonisolated(unsafe) var delay: Duration?
    private var overrides: [String: Route] = [:]
    func set(_ key: String, _ route: Route) { lock.lock(); overrides[key] = route; lock.unlock() }

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

    @Test func afterCreatingTheRepositoryTheNextAvailabilityReadsGitModes() async throws {
        let (service, transport) = try await makeService(routes: [
            "GET /api/project": .ok(#"[{"id":"p1","worktree":"/work/site"}]"#),
            "POST /api/vcs/init": .status(204, ""),
            "GET /api/vcs": .ok(#"{"location":{"directory":"/work/site"},"data":{"branch":{"current":"main","default":"main"}}}"#),
        ])
        let before = try await service.changesAvailability(sessionID: "s", directory: "/work/site", projectID: "p1")
        #expect(!before.isGit)
        #expect(before.directory == "/work/site")

        try await service.initGitRepository(directory: before.directory)
        transport.set("GET /api/project", .ok(#"[{"id":"p1","worktree":"/work/site","vcs":"git"}]"#))

        let after = try await service.changesAvailability(sessionID: "s", directory: "/work/site", projectID: "p1")
        #expect(after.isGit)
        #expect(after.modes == [.git, .turn])
    }

    @Test func gitInitFailureTextPrefersTheServerMessage() {
        let payload = OpenCodeAPIErrorPayload(tag: "ConflictError", message: "Already a repository", kind: nil, field: nil, resource: nil, service: nil, reference: nil)
        #expect(OCGitInitMessage.text(for: OpenCodeError.apiError(statusCode: 409, payload: payload)) == "Already a repository")
        #expect(OCGitInitMessage.text(for: URLError(.timedOut)) == "The server took too long to answer")
        #expect(OCGitInitMessage.text(for: OCVCSError.unavailable) == "Request failed")
    }

    // MARK: Large and binary diffs

    private func change(additions: Int, deletions: Int, patch: String? = nil) -> ReviewFileChange {
        ReviewFileChange(diff: OCFileDiff(file: "a.txt", status: "modified", additions: additions, deletions: deletions, patchText: patch))
    }

    @Test func diffsAboveFiveHundredChangedLinesWaitForRenderAnyway() {
        #expect(OCFileSupport.maximumDiffChangedLines == 500)
        #expect(!OCFileSupport.isTooLarge(change(additions: 300, deletions: 200)))
        #expect(OCFileSupport.isTooLarge(change(additions: 300, deletions: 201)))
        #expect(AppText.ocLargeDiffTitle == "Diff too large to render")
        #expect(AppText.ocLargeDiffMeta(limit: 500, current: 501) == "Limit: 500 changed lines. Current: 501 changed lines.")
    }

    @Test func aDiffWithoutLinesIsBinary() {
        #expect(OCFileSupport.isBinary(change(additions: 0, deletions: 0)))
        #expect(!OCFileSupport.isBinary(change(additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+x\n")))
        #expect(AppText.ocBinaryFile == "Binary file")
    }

    // MARK: Syntax highlighting

    private func kinds(_ line: String, _ language: OCSyntaxLanguage) -> [(String, OCSyntaxKind)] {
        OCSyntaxHighlighter.highlight(lines: [line], language: language)[0].map { ($0.text, $0.kind) }
    }

    private func has(_ segments: [(String, OCSyntaxKind)], _ text: String, _ kind: OCSyntaxKind) -> Bool {
        segments.contains { $0.0.trimmingCharacters(in: .whitespaces) == text && $0.1 == kind }
    }

    @Test func languagesAreDetectedFromTheFileName() {
        #expect(OCSyntaxLanguage.detect(path: "a/b/File.swift") == .swift)
        #expect(OCSyntaxLanguage.detect(path: "x.tsx") == .script)
        #expect(OCSyntaxLanguage.detect(path: "x.js") == .script)
        #expect(OCSyntaxLanguage.detect(path: "x.py") == .python)
        #expect(OCSyntaxLanguage.detect(path: "package.json") == .json)
        #expect(OCSyntaxLanguage.detect(path: "ci.yml") == .yaml)
        #expect(OCSyntaxLanguage.detect(path: "README.md") == .markdown)
        #expect(OCSyntaxLanguage.detect(path: "run.sh") == .shell)
        #expect(OCSyntaxLanguage.detect(path: "Dockerfile") == .shell)
        #expect(OCSyntaxLanguage.detect(path: "index.html") == .html)
        #expect(OCSyntaxLanguage.detect(path: "a.css") == .css)
        #expect(OCSyntaxLanguage.detect(path: "m.cpp") == .c)
        #expect(OCSyntaxLanguage.detect(path: "notes.txt") == .plain)
    }

    @Test func segmentsAlwaysRebuildTheLine() {
        let samples: [(String, OCSyntaxLanguage)] = [
            ("let x = \"a b\" // note", .swift), ("const f = (a) => `t${a}`; /* c */", .script),
            ("def f(x): return 'a' # c", .python), ("{\"k\": [1, 2.5, true]}", .json), ("- name: x # c", .yaml),
            ("## Title `code` [l](u)", .markdown), ("echo \"$HOME\" # c", .shell),
            ("<a href=\"x\">y</a>", .html), ("a { color: #fff; margin: 4px }", .css), ("#include <stdio.h>", .c),
        ]
        for (line, language) in samples {
            #expect(kinds(line, language).map(\.0).joined() == line, "\(language)")
        }
    }

    @Test func swiftColoursKeywordsStringsCommentsNumbersTypesAndCalls() {
        let line = kinds("let value: Int = 42 // answer", .swift)
        #expect(has(line, "let", .keyword))
        #expect(has(line, "Int", .type))
        #expect(has(line, "42", .number))
        #expect(has(line, "// answer", .comment))
        let call = kinds("print(\"hi\")", .swift)
        #expect(has(call, "print", .function))
        #expect(has(call, "\"hi\"", .string))
    }

    @Test func scriptAndPythonAndCFamily() {
        #expect(has(kinds("const a = await fetch('x')", .script), "const", .keyword))
        #expect(has(kinds("const a = await fetch('x')", .script), "'x'", .string))
        #expect(has(kinds("def run(self): # go", .python), "def", .keyword))
        #expect(has(kinds("def run(self): # go", .python), "# go", .comment))
        #expect(has(kinds("#include <stdio.h>", .c), "#include", .keyword))
        #expect(has(kinds("int main(void) { return 0; }", .c), "int", .keyword))
    }

    @Test func blockCommentsAndTripleStringsCarryAcrossLines() {
        let block = OCSyntaxHighlighter.highlight(lines: ["/* start", "middle", "end */ let a = 1"], language: .swift)
        #expect(block[1].map(\.kind) == [.comment])
        #expect(block[2].first?.kind == .comment)
        #expect(block[2].contains { $0.text.trimmingCharacters(in: .whitespaces) == "let" && $0.kind == .keyword })
        let triple = OCSyntaxHighlighter.highlight(lines: ["x = \"\"\"doc", "still doc", "end\"\"\"; y = 1"], language: .python)
        #expect(triple[1].map(\.kind) == [.string])
        #expect(triple[2].contains { $0.text.trimmingCharacters(in: .whitespaces) == "1" && $0.kind == .number })
    }

    @Test func jsonKeysValuesAndLiterals() {
        let line = kinds(#"  "name": "x", "n": 3, "ok": true"#, .json)
        #expect(has(line, "\"name\"", .property))
        #expect(has(line, "\"x\"", .string))
        #expect(has(line, "3", .number))
        #expect(has(line, "true", .keyword))
    }

    @Test func yamlKeysCommentsAndValues() {
        let line = kinds("  - image: \"nginx\" # web", .yaml)
        #expect(has(line, "image", .property))
        #expect(has(line, "\"nginx\"", .string))
        #expect(has(line, "# web", .comment))
        #expect(has(kinds("replicas: 3", .yaml), "3", .number))
    }

    @Test func markdownHeadingsFencesListsAndInlineCode() {
        let lines = OCSyntaxHighlighter.highlight(lines: ["# Title", "- item `code` [t](u)", "```swift", "let a = 1", "```", "plain"], language: .markdown)
        #expect(lines[0].map(\.kind) == [.keyword])
        #expect(lines[1].contains { $0.text == "`code`" && $0.kind == .string })
        #expect(lines[3].map(\.kind) == [.string])
        #expect(lines[5].map(\.kind) == [.plain])
    }

    @Test func htmlTagsAttributesAndComments() {
        let line = kinds("<div class=\"a\">hi</div>", .html)
        #expect(has(line, "<div", .tag))
        #expect(has(line, "class", .property))
        #expect(has(line, "\"a\"", .string))
        #expect(has(line, "</div>", .tag))
        #expect(OCSyntaxHighlighter.highlight(lines: ["<!-- a", "b -->"], language: .html)[1].first?.kind == .comment)
    }

    @Test func shellAndCSS() {
        let sh = kinds("if [ -n $HOME ]; then # go", .shell)
        #expect(has(sh, "if", .keyword))
        #expect(has(sh, "$HOME", .property))
        #expect(has(sh, "# go", .comment))
        let css = kinds("  color: #fff; margin: 4px;", .css)
        #expect(has(css, "color", .property))
        #expect(has(css, "#fff", .number))
        #expect(has(css, "4px", .number))
    }

    @Test func diffHighlightKeepsRemovedAndAddedStreamsApart() {
        // The removed line opens a block comment in the old file; the added one does not in the new file.
        let result = OCSyntaxHighlighter.highlight(
            diffLines: [
                (text: "/* old", isRemoved: true, isAdded: false),
                (text: "let a = 1", isRemoved: false, isAdded: true),
            ],
            language: .swift
        )
        #expect(result[0].map(\.kind) == [.comment])
        #expect(result[1].contains { $0.kind == .keyword })
    }

    @Test func plainTextIsOneSegment() {
        #expect(OCSyntaxHighlighter.highlight(lines: ["hello world"], language: .plain) == [[OCSyntaxSegment(text: "hello world", kind: .plain)]])
    }

    @Test func diffRenderBuildsSegmentsPerRowAndCachesThem() {
        let file = change(additions: 1, deletions: 1, patch: "--- a/x.swift\n+++ b/x.swift\n@@ -1,2 +1,2 @@\n keep\n-let a = 1\n+let a = 2\n")
        let renamed = ReviewFileChange(path: "x.swift", status: "modified", additions: 1, deletions: 1, beforeText: "keep\nlet a = 1\n", afterText: "keep\nlet a = 2\n")
        let render = OCDiffRender.build(file: renamed)
        #expect(render.lines.count == render.segments.count)
        #expect(render.segments.contains { $0.contains { $0.kind == .keyword } })
        #expect(OCDiffRender.build(file: renamed) === render)
        _ = file
    }

    // MARK: Line selection and comments

    private func lines(_ numbers: [Int?]) -> [OCDiffLineInfo] {
        numbers.enumerated().map { OCDiffLineInfo(number: $1, text: "row\($0)") }
    }

    @Test func tappingLinesSelectsExtendsAndClears() throws {
        let rows = lines([10, 11, 12, 13])
        let first = try #require(OCDiffSelection.toggled(nil, file: "a", row: 1, lines: rows))
        #expect(first.startLine == 11 && first.endLine == 11 && first.rows == 1...1)
        let range = try #require(OCDiffSelection.toggled(first, file: "a", row: 3, lines: rows))
        #expect(range.startLine == 11 && range.endLine == 13 && range.rows == 1...3)
        #expect(range.preview == "row1\nrow2\nrow3")
        let restarted = try #require(OCDiffSelection.toggled(range, file: "a", row: 0, lines: rows))
        #expect(restarted.rows == 0...0)
        #expect(OCDiffSelection.toggled(first, file: "a", row: 1, lines: rows) == nil)
        let otherFile = try #require(OCDiffSelection.toggled(first, file: "b", row: 2, lines: rows))
        #expect(otherFile.file == "b" && otherFile.rows == 2...2)
    }

    @Test func commentSentencesFollowTheWebWording() {
        let one = OCDiffComment(id: UUID(), sessionID: "s", file: "src/a.swift", startLine: 7, endLine: 7, text: "Why?", preview: "")
        let many = OCDiffComment(id: UUID(), sessionID: "s", file: "src/a.swift", startLine: 7, endLine: 9, text: "Rename", preview: "")
        #expect(one.note == "The user made the following comment regarding line 7 of src/a.swift: Why?")
        #expect(many.note == "The user made the following comment regarding lines 7 through 9 of src/a.swift: Rename")
        // Typed text first (so a slash command keeps leading), notes after, joined by one newline.
        #expect(OCDiffCommentStore.composedPrompt(comments: [one, many], typed: "  fix it ") ==
            "fix it\n" + one.note + "\n" + many.note)
        #expect(OCDiffCommentStore.composedPrompt(comments: [one], typed: "") == one.note)
        #expect(OCDiffCommentStore.composedPrompt(comments: [], typed: "hi") == "hi")
    }

    @Test func commentsStayOutOfSlashCommands() {
        #expect(OCDiffCommentStore.commentsApply(typed: "fix it", hasSlashChip: false))
        #expect(OCDiffCommentStore.commentsApply(typed: "", hasSlashChip: false))
        #expect(!OCDiffCommentStore.commentsApply(typed: "/undo", hasSlashChip: false))
        #expect(!OCDiffCommentStore.commentsApply(typed: "  /review x", hasSlashChip: false))
        #expect(!OCDiffCommentStore.commentsApply(typed: "", hasSlashChip: true))
        // Only a recognised command leaves the comments out; a path stays text.
        let known = ["review", "/build"]
        #expect(!OCDiffCommentStore.commentsApply(typed: "/review x", hasSlashChip: false, knownTokens: known))
        #expect(!OCDiffCommentStore.commentsApply(typed: "/Build", hasSlashChip: false, knownTokens: known))
        #expect(OCDiffCommentStore.commentsApply(typed: "/etc/hosts explain", hasSlashChip: false, knownTokens: known))
        #expect(OCDiffCommentStore.commentsApply(typed: "/review x", hasSlashChip: false))
    }

    @Test func commentStoreKeepsCommentsPerSessionAndDropsBlankOnes() throws {
        let store = OCDiffCommentStore()
        let selection = OCDiffSelection(file: "a", rows: 0...1, startLine: 3, endLine: 4, preview: "p")
        let added = try #require(store.add(sessionID: "s1", file: "a", selection: selection, text: "  note  "))
        #expect(added.text == "note")
        #expect(store.add(sessionID: "s1", file: "a", selection: selection, text: "   ") == nil)
        _ = store.add(sessionID: "s2", file: "b", selection: selection, text: "other")
        #expect(store.comments(sessionID: "s1").map(\.text) == ["note"])
        #expect(store.comments(sessionID: "s1", file: "b").isEmpty)
        store.remove(added.id)
        #expect(store.comments(sessionID: "s1").isEmpty)
        store.clear(sessionID: "s2")
        #expect(store.all.isEmpty)
    }

    @Test func commentLabelsFollowTheWebWording() {
        #expect(AppText.ocLineCommentSaved(start: 1, end: 1) == "Comment on line 1")
        #expect(AppText.ocLineCommentEditing(start: 2, end: 5) == "Commenting on lines 2-5")
        #expect(AppText.ocLineCommentChipLocation(file: "src/hello.txt", start: 1, end: 1) == "hello.txt:1")
        #expect(AppText.ocLineCommentChipLocation(file: "src/hello.txt", start: 1, end: 3) == "hello.txt:1-3")
    }

    @Test func aFailedChangesRequestSurfacesAsAnErrorForTheRetryState() async throws {
        let (service, transport) = try await makeService(routes: [
            "GET /api/vcs/diff": .status(503, #"{"_tag":"ServiceUnavailableError","message":"busy"}"#),
        ])
        await #expect(throws: OpenCodeError.self) {
            try await service.loadChanges(sessionID: "s", mode: .git, directory: "/repo")
        }
        // A retry is a plain second request: nothing is cached after a failure.
        transport.set("GET /api/vcs/diff", .ok(#"{"location":{"directory":"/repo"},"data":[]}"#))
        let files = try await service.loadChanges(sessionID: "s", mode: .git, directory: "/repo")
        #expect(files.isEmpty)
        let sent = transport.requests(matching: "GET /api/vcs/diff")
        #expect(sent.count == 2)
        #expect(s2Query(sent[0], "mode") == "working")
    }

    @Test func aSecondInitForTheSameFolderJoinsTheRunningOne() async throws {
        let (service, transport) = try await makeService(routes: ["POST /api/vcs/init": .status(204, ""), "GET /api/project": .ok("[]")])
        transport.delay = .milliseconds(300)
        async let first: Void = service.initGitRepository(directory: "/work/site")
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.isInitializingGit(directory: "/work/site"))
        async let second: Void = service.initGitRepository(directory: "/work/site")
        try await first
        try await second
        #expect(transport.requests(matching: "POST /api/vcs/init").count == 1)
        #expect(!service.isInitializingGit(directory: "/work/site"))
    }

    @Test func aHungInitIsCutOffAtTheTimeout() async throws {
        let (service, transport) = try await makeService(routes: ["POST /api/vcs/init": .status(204, "")])
        transport.delay = .seconds(60)
        service.initTimeout = 0.2
        await #expect(throws: URLError.self) { try await service.initGitRepository(directory: "/work/site") }
        #expect(!service.isInitializingGit(directory: "/work/site"))
    }

    @Test func aStaleProjectByIdYieldsToAGitProjectByPath() async throws {
        let (service, _) = try await makeService(routes: [
            "GET /api/project": .ok(#"[{"id":"global","worktree":"/"},{"id":"p2","worktree":"/work/site","vcs":"git"}]"#),
            "GET /api/vcs": .ok(#"{"location":{"directory":"/work/site"},"data":{"branch":{"current":"main","default":"main"}}}"#),
        ])
        let found = try await service.changesAvailability(sessionID: "s", directory: "/work/site", projectID: "global")
        #expect(found.isGit)
        #expect(found.directory == "/work/site")
    }

    @Test func plusInAFolderNameIsEncoded() throws {
        let request = OCVCSRemote.initRequest(baseURL: try #require(URL(string: "https://x.example")), authHeader: nil, directory: "/x/a+b c")
        let text = try #require(request.url?.absoluteString)
        #expect(text.contains("a%2Bb"))
        #expect(!text.contains("a+b"))
        #expect(s2Query(request, "location[directory]") == "/x/a+b c")
    }

    @Test func highlighterStartsFreshAtEveryHunk() {
        let patch = "--- a/x.swift\n+++ b/x.swift\n@@ -1,1 +1,1 @@\n-x\n+/* never closed\n@@ -20,1 +20,1 @@\n-y\n+let a = 1\n"
        let file = ReviewFileChange(diff: OCFileDiff(file: "reset.swift", status: "modified", additions: 2, deletions: 2, patchText: patch))
        let render = OCDiffRender.build(file: file)
        let last = render.segments.last ?? []
        #expect(last.contains { $0.text.trimmingCharacters(in: .whitespaces) == "let" && $0.kind == .keyword })
        #expect(render.attributed.count == render.lines.count)
    }

    @Test func unmatchedMarkdownMarkersStayLinear() {
        let line = String(repeating: "[`", count: 250)
        let result = OCSyntaxHighlighter.highlight(lines: [line, line, line], language: .markdown)
        #expect(result.count == 3)
        #expect(result[0].map(\.text).joined() == line)
    }

    @Test func aCancelledHighlightKeepsItsShape() async {
        let lines = (0..<1000).map { "let a\($0) = 1" }
        let task = Task.detached { OCSyntaxHighlighter.highlight(lines: lines, language: .swift) }
        task.cancel()
        let result = await task.value
        #expect(result.count == lines.count)
    }

    @Test func diffPathsAreRebasedOntoTheSessionFolder() {
        #expect(OCFileSupport.sessionPath("app/a.swift", root: "/repo", sessionDirectory: "/repo/app") == "a.swift")
        #expect(OCFileSupport.sessionPath("lib/b.swift", root: "/repo", sessionDirectory: "/repo/app") == "/repo/lib/b.swift")
        #expect(OCFileSupport.sessionPath("/repo/app/c.swift", root: "/repo", sessionDirectory: "/repo/app") == "c.swift")
        #expect(OCFileSupport.sessionPath("x/y.txt", root: "/repo", sessionDirectory: "/repo") == "x/y.txt")
        #expect(OCFileSupport.sessionPath("x/y.txt", root: nil, sessionDirectory: "/repo") == "x/y.txt")
    }

    @Test func selectionsAndCommentsCarryTheirSide() throws {
        // Removed rows number the old file, the others the new one; the same number is not the same line.
        let rows = [
            OCDiffLineInfo(number: 12, text: "old", side: .deletions),
            OCDiffLineInfo(number: 12, text: "new", side: .additions),
            OCDiffLineInfo(number: 13, text: "new2", side: .additions),
        ]
        let removed = try #require(OCDiffSelection.toggled(nil, file: "a", row: 0, lines: rows))
        #expect(removed.side == .deletions && removed.startLine == 12 && removed.endLine == 12)
        // A range ending on an added row counts that side's rows only (12 and 13, not the removed 12).
        let range = try #require(OCDiffSelection.toggled(removed, file: "a", row: 2, lines: rows))
        #expect(range.side == .additions && range.startLine == 12 && range.endLine == 13)
        let store = OCDiffCommentStore()
        let saved = try #require(store.add(sessionID: "s", file: "a", selection: removed, text: "x"))
        #expect(saved.side == .deletions)
    }

    @Test func editingACommentChangesItsText() throws {
        let store = OCDiffCommentStore()
        let selection = OCDiffSelection(file: "a", rows: 0...0, startLine: 1, endLine: 1, preview: "p")
        let saved = try #require(store.add(sessionID: "s", file: "a", selection: selection, text: "first"))
        store.update(saved.id, text: "  second ")
        #expect(store.comments(sessionID: "s").first?.text == "second")
        #expect(store.comments(sessionID: "s").first?.note.hasSuffix(": second") == true)
        store.update(saved.id, text: "   ")
        #expect(store.comments(sessionID: "s").first?.text == "second")
    }

    @Test func filesAreClassifiedForPreview() {
        #expect(OCFileSupport.previewKind(path: "docs/README.md") == .markdown)
        #expect(OCFileSupport.previewKind(path: "a/Photo.JPG") == .image)
        #expect(OCFileSupport.previewKind(path: "a.png") == .image)
        #expect(OCFileSupport.previewKind(path: "song.m4a") == .audio)
        #expect(OCFileSupport.previewKind(path: "main.swift") == .text)
        #expect(OCFileSupport.previewKind(path: "logo.svg") == .text)
    }

    @Test func rememberedModeCountsOnlyWhileOffered() {
        #expect(OCSessionMemory.resolvedMode(remembered: .branch, offered: [.git, .branch, .turn]) == .branch)
        #expect(OCSessionMemory.resolvedMode(remembered: .branch, offered: [.git, .turn]) == .git)
        #expect(OCSessionMemory.resolvedMode(remembered: nil, offered: [.git, .turn]) == .git)
        #expect(OCSessionMemory.resolvedMode(remembered: .turn, offered: []) == nil)
    }

    @Test func sessionMemoryKeepsTabsAndChangesPerSession() {
        let memory = OCSessionMemory()
        memory.setChanges(OCChangesMemory(mode: .turn, expanded: ["a"]), sessionID: "s1")
        #expect(memory.changes(sessionID: "s1").mode == .turn)
        #expect(memory.changes(sessionID: "s2").mode == nil)
        memory.setFiles(OCFilesMemory(openPaths: ["x.md"], activePath: "x.md"), directory: "/repo")
        #expect(memory.files(directory: "/repo")?.activePath == "x.md")
        #expect(memory.files(directory: "/other") == nil)
    }

    @Test func fileBytesAreReadFromTheFsRoute() async throws {
        let (service, transport) = try await makeService(routes: ["GET /api/fs/read/dir/a b.png": .ok("PNGDATA")])
        let (data, _) = try await service.readFileData(path: "dir/a b.png", directory: "/repo")
        #expect(String(data: data, encoding: .utf8) == "PNGDATA")
        let request = try #require(transport.requests().last(where: { $0.url?.path.contains("fs/read") == true }))
        #expect(s2Query(request, "location[directory]") == "/repo")
    }
}
