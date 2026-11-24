import Foundation
import Testing
@testable import OpenLens

@MainActor
struct OCTimelineGroupingTests {
    private func tool(_ id: String, _ name: String, in messageID: String, input: [String: Any] = [:]) -> OCPart {
        OCPart(
            id: id, sessionID: "s", messageID: messageID, type: .tool, callID: id, tool: name,
            state: OCToolState(status: .completed, input: AnyCodable(input))
        )
    }

    private func text(_ id: String, _ value: String, in messageID: String) -> OCPart {
        OCPart(id: id, sessionID: "s", messageID: messageID, type: .text, text: value)
    }

    private func items(_ messages: [ChatMessage]) -> [ChatTimelineItem] {
        OCTimelineGrouping.group(ChatTimeline.items(from: messages, showsThinking: true))
    }

    @Test func consecutiveToolsAcrossMessagesBecomeOneGroup() {
        let a = ChatMessage(id: "a1", role: .assistant, content: "", parts: [
            tool("t1", "glob", in: "a1", input: ["pattern": "*"]),
            tool("t2", "read", in: "a1", input: ["filePath": "/x/index.html"]),
        ])
        let b = ChatMessage(id: "a2", role: .assistant, content: "", parts: [
            tool("t3", "read", in: "a2", input: ["filePath": "/x/b.html"]),
            tool("t4", "edit", in: "a2", input: ["filePath": "/x/b.html"]),
            text("x", "Done", in: "a2"),
        ])
        let result = items([a, b])
        let groups = result.filter { !$0.groupedParts.isEmpty }
        #expect(groups.count == 1)
        #expect(groups[0].groupedParts.count == 4)
        let summary = OCTimelineGrouping.summary(groups[0].groupedParts.compactMap(\.segment))
        #expect(summary.count == 4)
        #expect(summary.names == "Glob, Read, Edit")
    }

    @Test func textBreaksGroups() {
        let m = ChatMessage(id: "a", role: .assistant, content: "", parts: [
            tool("t1", "read", in: "a"),
            text("x", "Middle", in: "a"),
            tool("t2", "read", in: "a"),
        ])
        let result = items([m])
        #expect(result.filter { !$0.groupedParts.isEmpty }.count == 2)
        #expect(result.count == 3)
    }

    @Test func footerOnLastTextOfFinishedTurnWithServerDuration() {
        let user = ChatMessage(id: "u", role: .user, content: "hi", createdAt: Date(timeIntervalSince1970: 1_000))
        user.createdAtIsServer = true
        let assistant = ChatMessage(id: "a", role: .assistant, content: "", parts: [text("x", "Done", in: "a")])
        assistant.completedAt = Date(timeIntervalSince1970: 1_155)
        let footer = items([user, assistant]).compactMap(\.assistantFooter).first
        #expect(footer != nil)
        #expect(footer?.duration == 155)
        #expect(OCTimelineGrouping.durationText(155) == "2m 35s")
        #expect(OCTimelineGrouping.durationText(15) == "15s")
    }

    @Test func noDurationWithoutServerTimes() {
        let user = ChatMessage(id: "u", role: .user, content: "hi")
        let assistant = ChatMessage(id: "a", role: .assistant, content: "", parts: [text("x", "Done", in: "a")])
        assistant.completedAt = Date().addingTimeInterval(30)
        let footer = items([user, assistant]).compactMap(\.assistantFooter).first
        #expect(footer != nil)
        #expect(footer?.duration == nil)
    }

    @Test func footerCopiesAllAssistantTextOfTheTurn() {
        let user = ChatMessage(id: "u", role: .user, content: "hi")
        let a1 = ChatMessage(id: "a1", role: .assistant, content: "", parts: [text("x1", "First", in: "a1")])
        let a2 = ChatMessage(id: "a2", role: .assistant, content: "", parts: [text("x2", "Second", in: "a2")])
        let footer = items([user, a1, a2]).compactMap(\.assistantFooter).first
        #expect(footer?.messages.count == 2)
        #expect(OCTimelineGrouping.responseText(footer?.messages ?? []) == "First\n\nSecond")
    }

    @Test func groupStatusFlagsFailedAndRunning() {
        let failed = OCPart(
            id: "t", sessionID: "s", messageID: "a", type: .tool, callID: "t", tool: "bash",
            state: OCToolState(status: .error, input: AnyCodable([:]))
        )
        let running = OCPart(
            id: "r", sessionID: "s", messageID: "a", type: .tool, callID: "r", tool: "read",
            state: OCToolState(status: .running, input: AnyCodable([:]))
        )
        let m = ChatMessage(id: "a", role: .assistant, content: "", parts: [failed, running])
        let status = OCTimelineGrouping.status(m.assistantSegments)
        #expect(status.failed)
        #expect(status.running)
    }

    @Test func streamingTurnHasNoFooter() {
        let user = ChatMessage(id: "u", role: .user, content: "hi")
        let assistant = ChatMessage(id: "a", role: .assistant, content: "", parts: [text("x", "Part", in: "a")], isStreaming: true)
        #expect(items([user, assistant]).compactMap(\.assistantFooter).isEmpty)
    }

    @Test func toolTitles() {
        #expect(OCTimelineGrouping.toolTitle("bash") == "Shell")
        #expect(OCTimelineGrouping.toolTitle("grep") == "Grep")
    }
}
