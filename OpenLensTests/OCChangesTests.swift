import Foundation
import Testing
@testable import OpenLens

@MainActor
struct OCChangesTests {
    @Test func pathSplitKeepsTheDirectoryAndTheName() {
        #expect(OCFileSupport.split(path: "_scratch/PROGRESS.md") == ("_scratch/", "PROGRESS.md"))
        #expect(OCFileSupport.split(path: "hello.txt") == ("", "hello.txt"))
        #expect(OCFileSupport.split(path: "a/b/c.html") == ("a/b/", "c.html"))
    }

    @Test func absolutePathsBecomeRelativeToTheSessionFolder() {
        #expect(OCFileSupport.relative("/home/docker/x/index.html", to: "/home/docker") == "x/index.html")
        #expect(OCFileSupport.relative("/home/docker/x/index.html", to: "/home/docker/") == "x/index.html")
        #expect(OCFileSupport.relative("x/index.html", to: "/home/docker") == "x/index.html")
        #expect(OCFileSupport.relative("/other/a.txt", to: "/home/docker") == "/other/a.txt")
        #expect(OCFileSupport.relative("a.txt", to: nil) == "a.txt")
    }

    @Test func statusWordsFollowTheWeb() {
        #expect(OCFileSupport.statusLabel("A") == "Added")
        #expect(OCFileSupport.statusLabel("D") == "Removed")
        #expect(OCFileSupport.statusLabel("M") == "Modified")
    }

    @Test func editCardReadsTheServerPatchFromTheDecodedToolMetadata() throws {
        let json = #"""
        {"id":"p1","sessionID":"s","messageID":"m","type":"tool","tool":"edit","state":{"status":"completed",
         "input":{"path":"a/index.html","oldString":"x","newString":"y"},
         "metadata":{"files":[{"file":"a/index.html","patch":"Index: a/index.html\n===\n--- a/index.html\n+++ a/index.html\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n"}],"truncated":false}}}
        """#
        let part = try JSONDecoder().decode(OCPart.self, from: Data(json.utf8))
        let files = OCFileSupport.fileChanges(of: part)
        #expect(files.count == 1)
        #expect(files[0].file.path == "a/index.html")
        #expect(files[0].file.additions == 1)
        #expect(files[0].file.deletions == 1)
        let hunks = UnifiedDiffBuilder.makeHunks(file: files[0].file)
        #expect(hunks.flatMap(\.lines).map(\.text) == ["keep", "old", "new"])
    }

    @Test func writeCardCountsEveryWrittenLineAsAdded() throws {
        let json = #"""
        {"id":"p2","sessionID":"s","messageID":"m","type":"tool","tool":"write","state":{"status":"completed",
         "input":{"path":"/home/docker/hello.txt","content":"szia\nvilag"},"metadata":{"truncated":false}}}
        """#
        let part = try JSONDecoder().decode(OCPart.self, from: Data(json.utf8))
        let files = OCFileSupport.fileChanges(of: part)
        #expect(files.count == 1)
        #expect(files[0].file.status == "A")
        #expect(files[0].file.additions == 2)
        #expect(files[0].file.deletions == 0)
    }

    @Test func unfinishedOrOtherToolsHaveNoCard() throws {
        let running = #"{"id":"p3","sessionID":"s","messageID":"m","type":"tool","tool":"edit","state":{"status":"running","input":{"path":"a"}}}"#
        let read = #"{"id":"p4","sessionID":"s","messageID":"m","type":"tool","tool":"read","state":{"status":"completed","input":{"path":"a"}}}"#
        #expect(OCFileSupport.fileChanges(of: try JSONDecoder().decode(OCPart.self, from: Data(running.utf8))).isEmpty)
        #expect(OCFileSupport.fileChanges(of: try JSONDecoder().decode(OCPart.self, from: Data(read.utf8))).isEmpty)
        #expect(OCFileSupport.isFileTool("Edit"))
        #expect(!OCFileSupport.isFileTool("read"))
    }

    @Test func fileTreeKeepsDotFoldersOnlyWhenAsked() {
        let entries = [
            OCWorkspaceFileEntry(name: ".git", path: ".git", absolute: nil, type: "directory", ignored: false),
            OCWorkspaceFileEntry(name: "hello.txt", path: "hello.txt", absolute: nil, type: "file", ignored: false),
            OCWorkspaceFileEntry(name: "_scratch", path: "_scratch", absolute: nil, type: "directory", ignored: false),
        ]
        let hidden = WorkspaceService.repositoryEntries(from: entries, directory: "/r")
        #expect(hidden.map(\.name) == ["_scratch", "hello.txt"])
        let all = WorkspaceService.repositoryEntries(from: entries, directory: "/r", includesHidden: true)
        #expect(Set(all.map(\.name)) == [".git", "_scratch", "hello.txt"])
        #expect(all.last?.name == "hello.txt")
    }

    @Test func modesNameTheWebsOptions() {
        #expect(OCChangesMode.git.title == "Git changes")
        #expect(OCChangesMode.turn.title == "Last turn changes")
        #expect(OCChangesMode.git.emptyText == "No uncommitted changes yet")
    }

    @Test func editWithoutAServerPatchHasNoRealLineNumbers() throws {
        let json = #"""
        {"id":"p5","sessionID":"s","messageID":"m","type":"tool","tool":"edit","state":{"status":"completed",
         "input":{"path":"a.txt","oldString":"x","newString":"y"}}}
        """#
        let part = try JSONDecoder().decode(OCPart.self, from: Data(json.utf8))
        let files = OCFileSupport.fileChanges(of: part)
        #expect(files.count == 1)
        #expect(!files[0].hasRealLineNumbers)
    }

    @Test func aRunningEditBecomesACardWhenItCompletes() throws {
        let running = #"{"id":"p6","sessionID":"s","messageID":"m","type":"tool","tool":"edit","state":{"status":"running","input":{"path":"a.txt","oldString":"x","newString":"y"}}}"#
        let done = #"{"id":"p6","sessionID":"s","messageID":"m","type":"tool","tool":"edit","state":{"status":"completed","input":{"path":"a.txt","oldString":"x","newString":"y"}}}"#
        #expect(OCFileSupport.fileChanges(of: try JSONDecoder().decode(OCPart.self, from: Data(running.utf8))).isEmpty)
        #expect(OCFileSupport.fileChanges(of: try JSONDecoder().decode(OCPart.self, from: Data(done.utf8))).count == 1)
    }

    @Test func foldersCompareWithoutTrailingSlashesAndSubfoldersBelongToTheirRepo() {
        #expect(OCFileSupport.sameFolder("/a/b/", "/a/b"))
        #expect(!OCFileSupport.sameFolder("/a/b", "/a/c"))
        #expect(!OCFileSupport.sameFolder(nil, "/a"))
        #expect(OCFileSupport.isInside("/repo/sub/dir", root: "/repo"))
        #expect(OCFileSupport.isInside("/repo", root: "/repo/"))
        #expect(!OCFileSupport.isInside("/repository", root: "/repo"))
    }

    @Test func longLinesAreCutAndHugeFilesAreOnlyPartlySplit() {
        let long = String(repeating: "x", count: 5000)
        #expect(OCFileSupport.truncated(long).count == OCFileSupport.maximumLineCharacters + 1)
        #expect(OCFileSupport.truncated("short") == "short")
        let text = (1...10_000).map { "line \($0)" }.joined(separator: "\n")
        let lines = OCFileSupport.cappedLines(text, maximumLines: 5000)
        #expect(lines.count == 5000)
        #expect(lines.last == "line 5000")
    }

    @Test func geometryRepinsStopAfterAFewForOneContentVersion() {
        let limit = ChatScrollPolicy.maximumRepinsPerContentVersion
        #expect(ChatScrollPolicy.shouldRepinToBottom(
            isLoading: false, followLatest: true, interaction: .idle, isAtBottom: false,
            hasPendingRestoration: false, repinsForContentVersion: limit - 1
        ))
        #expect(!ChatScrollPolicy.shouldRepinToBottom(
            isLoading: false, followLatest: true, interaction: .idle, isAtBottom: false,
            hasPendingRestoration: false, repinsForContentVersion: limit
        ))
    }
}
