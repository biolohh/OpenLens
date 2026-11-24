import SwiftUI

/// One assistant part that belongs to a "Used N ..." group. Resolved through the live message
/// so the row keeps updating while the part streams.
struct OCGroupedPart: Identifiable {
    let message: ChatMessage
    let segmentID: String
    var id: String { "\(message.id)/\(segmentID)" }

    var segment: ChatMessage.AssistantSegment? { message.assistantSegment(withID: segmentID) }
}

/// Footer data for the last text of a finished turn (web: copy icon + duration).
struct OCAssistantFooterInfo {
    let message: ChatMessage
    let duration: TimeInterval?
}

/// Pure grouping/labelling used by the transcript (unit-tested).
enum OCTimelineGrouping {
    /// Consecutive tool and reasoning parts become one group item; text, questions and subagents
    /// break a group. A succeeded "idle" context entry (the "Execution succeeded" card) is dropped.
    static func group(_ items: [ChatTimelineItem]) -> [ChatTimelineItem] {
        var result: [ChatTimelineItem] = []
        var run: [ChatTimelineItem] = []

        func flush() {
            guard let first = run.first else { return }
            result.append(ChatTimelineItem(
                id: first.id,
                content: first.content,
                animatesSubagentStatus: false,
                groupedParts: run.compactMap { item in
                    guard case .assistantSegment(let message, let segment) = item.content else { return nil }
                    return OCGroupedPart(message: message, segmentID: segment.id)
                }
            ))
            run.removeAll()
        }

        for item in items {
            switch item.content {
            case .assistantSegment(_, let segment) where isGroupable(segment):
                run.append(item)
            case .context(let entry) where entry.kind == .idle && entry.idleOutcome == "succeeded":
                continue
            default:
                flush()
                result.append(item)
            }
        }
        flush()
        return attachFooters(result)
    }

    static func isGroupable(_ segment: ChatMessage.AssistantSegment) -> Bool {
        switch segment.kind {
        case .tool, .reasoning: true
        default: false
        }
    }

    /// Puts the copy + duration footer on the last text of every finished turn.
    private static func attachFooters(_ items: [ChatTimelineItem]) -> [ChatTimelineItem] {
        var items = items
        var turnStart: Date?
        var lastText: Int?
        var lastAssistant: ChatMessage?

        func close() {
            if let index = lastText, let message = lastAssistant, !message.isStreaming {
                let end = partEnd(of: message)
                let duration = turnStart.flatMap { start in end.map { $0.timeIntervalSince(start) } }
                items[index].assistantFooter = OCAssistantFooterInfo(
                    message: message, duration: duration.flatMap { $0 > 0 ? $0 : nil }
                )
            }
            lastText = nil
            lastAssistant = nil
        }

        for index in items.indices {
            switch items[index].content {
            case .message(let message) where message.role == .user:
                close()
                turnStart = message.createdAt
            case .assistantSegment(let message, let segment):
                lastAssistant = message
                if case .text = segment.kind { lastText = index }
            case .streamingAssistantText(let message, _):
                lastAssistant = message
            default:
                break
            }
        }
        close()
        return items
    }

    /// Latest part end time (server milliseconds), if the parts carry one.
    static func partEnd(of message: ChatMessage) -> Date? {
        let ends = message.parts.compactMap { part -> Double? in
            guard let time = part.time?.value as? [String: Any] else { return nil }
            if let end = time["end"] as? Double { return end }
            if let end = time["end"] as? Int { return Double(end) }
            return nil
        }
        return ends.max().map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    // MARK: Labels

    /// "2m 35s" / "15s".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }

    /// Web tool titles ("Glob", "Read", "Edit", "Shell").
    static func toolTitle(_ toolName: String) -> String {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "bash", "shell": return "Shell"
        case "webfetch": return "Fetch"
        case "task": return "Agent"
        case "": return "Tool"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// Closed label parts: names of the distinct tools in order of first use, the call count (or the
    /// thought count when the group only holds reasoning).
    static func summary(_ segments: [ChatMessage.AssistantSegment]) -> (count: Int, names: String) {
        var names: [String] = []
        var calls = 0
        var thoughts = 0
        for segment in segments {
            switch segment.kind {
            case .tool(let step):
                calls += 1
                let title = toolTitle(step.toolName)
                if !names.contains(title) { names.append(title) }
            case .reasoning:
                thoughts += 1
            default:
                break
            }
        }
        if calls > 0 { return (calls, names.joined(separator: ", ")) }
        return (thoughts, thoughts == 1 ? "thought" : "thoughts")
    }
}

/// "Used 11 Glob, Read, Edit": collapsed by default, expands to one line per call.
struct OCUsedToolsRow: View {
    let parts: [OCGroupedPart]

    @State private var expanded = false

    private var segments: [ChatMessage.AssistantSegment] { parts.compactMap(\.segment) }

    var body: some View {
        let segments = segments
        let summary = OCTimelineGrouping.summary(segments)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(AppText.ocUsedPrefix).foregroundStyle(Color.appSecondary)
                    Text("\(summary.count)").foregroundStyle(Color.appPrimary)
                    Text(summary.names).fontWeight(.semibold).foregroundStyle(Color.appPrimary).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .frame(minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.used")
            .accessibilityLabel("\(AppText.ocUsedPrefix) \(summary.count) \(summary.names)")
            .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { segment in line(segment) }
                }
                .padding(.leading, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ segment: ChatMessage.AssistantSegment) -> some View {
        switch segment.kind {
        case .tool(let step):
            let title = OCTimelineGrouping.toolTitle(step.toolName)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).fontWeight(.semibold).foregroundStyle(step.isError ? Color.appWarning : Color.appPrimary)
                Text(detail(step, title: title))
                    .foregroundStyle(Color.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
        case .reasoning(let text):
            Text(segment.streamingText?.copyText() ?? text)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    /// The formatter's label starts with the tool name; the web shows the arguments after the name.
    private func detail(_ step: ChatMessage.PersistedToolStep, title: String) -> String {
        let label = step.label
        for name in [step.toolName, title] where label.lowercased().hasPrefix(name.lowercased() + " ") {
            return String(label.dropFirst(name.count + 1))
        }
        return label == step.toolName ? "" : label
    }
}
