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

    @Test func footerOnLastTextOfFinishedTurnWithDuration() {
        let created = Date(timeIntervalSince1970: 1_000)
        let user = ChatMessage(id: "u", role: .user, content: "hi", createdAt: created)
        let part = OCPart(
            id: "x", sessionID: "s", messageID: "a", type: .text, text: "Done",
            time: AnyCodable(["start": 1_000_000.0, "end": 1_155_000.0])
        )
        let assistant = ChatMessage(id: "a", role: .assistant, content: "", parts: [part])
        let footer = items([user, assistant]).compactMap(\.assistantFooter).first
        #expect(footer != nil)
        #expect(footer?.duration == 155)
        #expect(OCTimelineGrouping.durationText(155) == "2m 35s")
        #expect(OCTimelineGrouping.durationText(15) == "15s")
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
