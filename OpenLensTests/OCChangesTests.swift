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
        #expect(files[0].path == "a/index.html")
        #expect(files[0].additions == 1)
        #expect(files[0].deletions == 1)
        let hunks = UnifiedDiffBuilder.makeHunks(file: files[0])
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
        #expect(files[0].status == "A")
        #expect(files[0].additions == 2)
        #expect(files[0].deletions == 0)
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
        #expect(all.map(\.name) == [".git", "_scratch", "hello.txt"])
    }

    @Test func modesNameTheWebsOptions() {
        #expect(OCChangesMode.git.title == "Git changes")
        #expect(OCChangesMode.turn.title == "Last turn changes")
        #expect(OCChangesMode.git.emptyText == "No uncommitted changes yet")
    }
}
