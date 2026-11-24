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
    /// Every assistant message of the turn (the copied response is all of their text).
    let messages: [ChatMessage]
    let duration: TimeInterval?
}

/// Expanded state of "Used N" groups, keyed by every part id of the group so it survives a group
/// that grows backwards (earlier history joins the first group and changes its id).
@MainActor @Observable
final class OCExpansionStore {
    static let shared = OCExpansionStore()
    private(set) var expandedPartIDs: Set<String> = []

    func isExpanded(_ parts: [OCGroupedPart]) -> Bool {
        parts.contains { expandedPartIDs.contains($0.id) }
    }

    func toggle(_ parts: [OCGroupedPart]) {
        if isExpanded(parts) {
            expandedPartIDs.subtract(parts.map(\.id))
        } else {
            expandedPartIDs.formUnion(parts.map(\.id))
        }
    }
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
        var turnMessages: [ChatMessage] = []

        func close() {
            if let index = lastText, let message = lastAssistant, !message.isStreaming {
                items[index].assistantFooter = OCAssistantFooterInfo(
                    messages: turnMessages, duration: duration(from: turnStart, to: message)
                )
            }
            lastText = nil
            lastAssistant = nil
            turnMessages = []
        }

        func note(_ message: ChatMessage) {
            lastAssistant = message
            if !turnMessages.contains(where: { $0 === message }) { turnMessages.append(message) }
        }

        for index in items.indices {
            switch items[index].content {
            case .message(let message) where message.role == .user:
                close()
                turnStart = message.createdAtIsServer ? message.createdAt : nil
            case .assistantSegment(let message, let segment):
                note(message)
                if case .text = segment.kind { lastText = index }
            case .streamingAssistantText(let message, _):
                note(message)
            default:
                break
            }
        }
        close()
        return items
    }

    /// Turn duration from server times only (user created, assistant completed); never mixes the
    /// device clock with the server's, so a live turn shows none until it is reloaded.
    static func duration(from start: Date?, to message: ChatMessage) -> TimeInterval? {
        guard let start, let end = message.completedAt else { return nil }
        let seconds = end.timeIntervalSince(start)
        return seconds > 0 ? seconds : nil
    }

    /// All assistant text of a turn, in order.
    static func responseText(_ messages: [ChatMessage]) -> String {
        let texts = messages.flatMap { message -> [String] in
            let segments = message.assistantSegments.compactMap { segment -> String? in
                if case .text(let text) = segment.kind { return text }
                return nil
            }
            return segments.isEmpty ? [message.content] : segments
        }
        return texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: Labels

    /// "2m 35s" / "15s".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }

    /// Whether any call of the group failed or is still running.
    static func status(_ segments: [ChatMessage.AssistantSegment]) -> (failed: Bool, running: Bool) {
        var failed = false
        var running = false
        for segment in segments {
            if case .tool(let step) = segment.kind {
                failed = failed || step.isError
                running = running || step.isRunning
            }
        }
        return (failed, running)
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
/// A failed call shows a warning mark and a running one a spinner even while collapsed;
/// each tool line opens to the detailed rendering (output, partial output, files, copy).
struct OCUsedToolsRow: View {
    let parts: [OCGroupedPart]

    private var store: OCExpansionStore { .shared }
    @State private var openLines: Set<String> = []

    private var segments: [ChatMessage.AssistantSegment] { parts.compactMap(\.segment) }

    var body: some View {
        let segments = segments
        let summary = OCTimelineGrouping.summary(segments)
        let status = OCTimelineGrouping.status(segments)
        let expanded = store.isExpanded(parts)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { store.toggle(parts) }
            } label: {
                HStack(spacing: 5) {
                    Text(AppText.ocUsedPrefix).foregroundStyle(Color.appSecondary)
                    Text("\(summary.count)").foregroundStyle(Color.appPrimary)
                    Text(summary.names).fontWeight(.semibold).foregroundStyle(Color.appPrimary).lineLimit(1)
                    if status.failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appDanger)
                            .accessibilityLabel(AppText.ocToolFailed)
                    }
                    if status.running {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(AppText.ocToolRunning)
                    }
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
                    ForEach(parts) { part in line(part) }
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
    private func line(_ part: OCGroupedPart) -> some View {
        if let segment = part.segment {
            switch segment.kind {
            case .tool(let step):
                let title = OCTimelineGrouping.toolTitle(step.toolName)
                let open = openLines.contains(part.id)
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if open { openLines.remove(part.id) } else { openLines.insert(part.id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(title).fontWeight(.semibold)
                                .foregroundStyle(step.isError ? Color.appDanger : Color.appPrimary)
                            Text(detail(step, title: title))
                                .foregroundStyle(Color.appSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if step.isRunning { ProgressView().controlSize(.mini) }
                        }
                        .font(.system(size: 13))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("oc.toolLine")
                    .accessibilityValue(open ? "expanded" : "collapsed")

                    if open {
                        MessageBubbleView(message: part.message, assistantSegments: [segment])
                            .padding(.leading, 4)
                    }
                }
            case .reasoning(let text):
                Text(segment.streamingText?.copyText() ?? text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                EmptyView()
            }
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
