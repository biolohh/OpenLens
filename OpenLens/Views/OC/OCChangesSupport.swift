import SwiftUI

// MARK: - Strings of the Changes / Files tabs (the web's wording)

extension AppText {
    static let ocChangesGit = "Git changes"
    static let ocChangesTurn = "Last turn changes"
    static let ocChangesBranch = "Branch changes"
    static let ocChangesEmptyBranch = "No branch changes yet"
    static let ocRequestFailed = "Request failed"
    static let ocChangesEmptyGit = "No uncommitted changes yet"
    static let ocChangesEmptyTurn = "No changes"
    static let ocChangesLoading = "Loading changes…"
    static let ocChangesFailed = "Couldn't load changes"
    static let ocChangesExpandAll = "Expand all"
    static let ocChangesCollapseAll = "Collapse all"
    static let ocChangeAdded = "Added"
    static let ocChangeRemoved = "Removed"
    static let ocChangeModified = "Modified"
    static let ocOpenFile = "Open file"
    static let ocFilesAll = "All files"
    static let ocFilesFilter = "Filter files"
    static let ocFilesNoResults = "No results"
    static let ocFileNotText = "This file can't be shown as text."
    static let ocFileCloseTab = "Close file"
    static let ocShowFullDiff = "Show full diff"
    static let ocNoDiff = "No line-level diff available."
    static let ocToolDetails = "Details"
    static let ocFolderMissing = "No folder for this session"
    static let ocFolderLoadFailed = "Couldn't load"
    static func ocShowMoreLines(_ count: Int) -> String { "Show \(count) more lines" }
}

// MARK: - Changes model

/// The web's review modes: the git working tree, the branch against the default branch, and
/// the newest turn.
enum OCChangesMode: String, CaseIterable, Hashable, Sendable {
    case git
    case branch
    case turn

    var title: String {
        switch self {
        case .git: AppText.ocChangesGit
        case .branch: AppText.ocChangesBranch
        case .turn: AppText.ocChangesTurn
        }
    }

    var emptyText: String {
        switch self {
        case .git: AppText.ocChangesEmptyGit
        case .branch: AppText.ocChangesEmptyBranch
        case .turn: AppText.ocChangesEmptyTurn
        }
    }
}

struct OCChangesAvailability: Equatable, Sendable {
    /// The session's project is a git repository; without it the web shows "No tracked changes".
    let isGit: Bool
    let modes: [OCChangesMode]
    /// The folder the repository is read at (the project's root); `nil` = the client's folder.
    var directory: String?
}

/// A file a tool call changed, with whether its diff lines carry the file's real line numbers
/// (an Edit without a server patch only has the replaced snippet).
nonisolated struct OCToolFileChange: Identifiable, Hashable, Sendable {
    let file: ReviewFileChange
    let hasRealLineNumbers: Bool
    var id: String { file.id }
}

/// Pure helpers shared by the Changes tab, the Used-N file card and the Files tab (unit-tested).
enum OCFileSupport {
    /// Longest diff / file line that is laid out; longer ones end in an ellipsis.
    nonisolated static let maximumLineCharacters = 500

    /// "_scratch/PROGRESS.md" -> ("_scratch/", "PROGRESS.md"); the directory keeps its trailing slash.
    nonisolated static func split(path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let next = path.index(after: slash)
        return (String(path[..<next]), String(path[next...]))
    }

    /// Path relative to the session folder when the server reports an absolute one.
    nonisolated static func relative(_ path: String, to directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }
        let root = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// Whether a session path (from `sessionPath`) lies inside the session folder; an absolute one
    /// is outside, and the Files tab cannot open it.
    nonisolated static func isInsideSession(_ sessionPath: String) -> Bool {
        !sessionPath.hasPrefix("/")
    }

    /// A diff path (relative to `root`, or absolute) as the session folder sees it: relative to the
    /// session folder when inside it, else absolute. Without a root the session folder is the base.
    nonisolated static func sessionPath(_ path: String, root: String?, sessionDirectory: String?) -> String {
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else if let root = root?.nilIfBlank, !sameFolder(root, sessionDirectory) {
            absolute = (root.hasSuffix("/") ? root : root + "/") + path
        } else {
            return relative(path, to: sessionDirectory)
        }
        let result = relative(absolute, to: sessionDirectory)
        return result
    }

    /// Same folder, whatever the trailing slashes.
    nonisolated static func sameFolder(_ lhs: String?, _ rhs: String?) -> Bool {
        func normalized(_ value: String?) -> String? {
            guard var value, !value.isEmpty else { return nil }
            while value.count > 1, value.hasSuffix("/") { value.removeLast() }
            return value
        }
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return false }
        return lhs == rhs
    }

    /// `directory` is the same as, or lies inside, `root`.
    nonisolated static func isInside(_ directory: String?, root: String?) -> Bool {
        guard let directory, let root, !root.isEmpty else { return false }
        if sameFolder(directory, root) { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return directory.hasPrefix(prefix)
    }

    nonisolated static func truncated(_ line: String) -> String {
        line.count > maximumLineCharacters ? String(line.prefix(maximumLineCharacters)) + "…" : line
    }

    /// The first `maximumLines` lines of a file, each cut at `maximumLineCharacters`; the rest of a
    /// huge file is never split or mapped.
    /// Runs blocking work off the main actor and hands the caller's cancellation on to it: a plain
    /// `Task.detached` does not inherit it, so a closed file would keep its highlighter running.
    nonisolated static func runCancellable<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    nonisolated static func cappedLines(_ text: String, maximumLines: Int) -> [String] {
        text.split(separator: "\n", maxSplits: maximumLines, omittingEmptySubsequences: false)
            .prefix(maximumLines)
            .map { truncated(String($0)) }
    }

    static func statusLabel(_ status: String) -> String {
        switch status.uppercased() {
        case "A": AppText.ocChangeAdded
        case "D": AppText.ocChangeRemoved
        default: AppText.ocChangeModified
        }
    }

    /// SF Symbol and tint for the web's file-type icons (html, markdown, code, image, generic).
    static func icon(forFileName name: String) -> (symbol: String, tint: Color?) {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": ("chevron.left.forwardslash.chevron.right", .orange)
        case "md", "markdown": ("text.alignleft", .blue)
        case "css", "scss": ("number", .blue)
        case "js", "ts", "jsx", "tsx", "swift", "py", "sh", "rs", "go", "kt": ("curlybraces", Color.appWarning)
        case "json", "yml", "yaml", "toml": ("curlybraces.square", .purple)
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": ("photo", .green)
        default: ("doc.text", nil)
        }
    }

    nonisolated static func isFileTool(_ toolName: String) -> Bool {
        ["edit", "write", "apply_patch", "patch"].contains(toolName.lowercased())
    }

    /// The file(s) a finished Edit / Write / apply_patch call changed, from the tool part:
    /// the server's own per-call patch (`metadata.files`), else the written content (write) or the
    /// replaced snippet (edit). Empty while the call is not completed.
    nonisolated static func fileChanges(of part: OCPart) -> [OCToolFileChange] {
        guard part.type == .tool, let state = part.state, state.status == .completed else { return [] }
        let tool = (part.tool ?? "").lowercased()
        guard isFileTool(tool) else { return [] }

        if let raw = state.metadata?["files"]?.value as? [Any] {
            let changes = raw.compactMap { item -> OCToolFileChange? in
                guard let dict = item as? [String: Any],
                      let file = (dict["file"] as? String) ?? (dict["relativePath"] as? String) ?? (dict["filePath"] as? String)
                else { return nil }
                let patch = (dict["patch"] as? String) ?? (dict["diff"] as? String)
                let status = (dict["status"] as? String) ?? (dict["type"] as? String)
                return OCToolFileChange(
                    file: ReviewFileChange(diff: OCFileDiff(
                        file: file,
                        status: status,
                        additions: dict["additions"] as? Int,
                        deletions: dict["deletions"] as? Int,
                        before: dict["before"] as? String,
                        after: dict["after"] as? String,
                        patchText: patch
                    )),
                    hasRealLineNumbers: patch != nil
                )
            }
            if !changes.isEmpty { return changes }
        }

        guard let input = state.input?.value as? [String: Any] else { return [] }
        guard let path = (input["path"] as? String) ?? (input["filePath"] as? String) else { return [] }
        if tool == "write", let content = input["content"] as? String {
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last == "" { lines.removeLast() }
            return [OCToolFileChange(
                file: ReviewFileChange(diff: OCFileDiff(file: path, status: "A", additions: lines.count, deletions: 0, after: content)),
                hasRealLineNumbers: true
            )]
        }
        if tool == "edit", let old = input["oldString"] as? String, let new = input["newString"] as? String {
            return [OCToolFileChange(
                file: ReviewFileChange(diff: OCFileDiff(file: path, before: old, after: new)),
                hasRealLineNumbers: false
            )]
        }
        return []
    }
}

// MARK: - Session folder in the environment

private struct OCSessionDirectoryKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Folder of the open session, so file cards can show paths relative to it.
    var ocSessionDirectory: String? {
        get { self[OCSessionDirectoryKey.self] }
        set { self[OCSessionDirectoryKey.self] = newValue }
    }
}

// MARK: - Shared pieces

/// File-type icon at the web's 16 pt size.
struct OCFileTypeIcon: View {
    let name: String

    var body: some View {
        let icon = OCFileSupport.icon(forFileName: name)
        Image(systemName: icon.symbol)
            .font(.system(size: 13))
            .foregroundStyle(icon.tint ?? Color.appSecondary)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

/// "dir/" muted + "name" primary (bold in the card variant).
struct OCPathLabel: View {
    let path: String
    var boldName = false

    var body: some View {
        let parts = OCFileSupport.split(path: path)
        (Text(parts.directory).foregroundColor(Color.appSecondary)
            + Text(parts.name).foregroundColor(Color.appPrimary).fontWeight(boldName ? .semibold : .regular))
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.head)
    }
}

/// "+12" green and "-12" red.
struct OCDiffCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)").foregroundStyle(Color.appSuccess)
            Text("-\(deletions)").foregroundStyle(Color.appDanger)
        }
        .font(.system(size: 13, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("+\(additions) -\(deletions)")
    }
}

/// The web's unified diff: line number column, monospace lines (wrapped, or scrolling sideways
/// when `wraps` is off), syntax coloured, added lines tinted green with a 2 pt bar on the left,
/// removed ones red. Plain `VStack` (no nested lazy scrolling), so it is safe inside a transcript
/// row. Every line is cut at `OCFileSupport.maximumLineCharacters`; only `maximumLines` rows are
/// laid out. Highlighting is built off the main actor and cached per file content.
struct OCDiffBlock: View {
    let file: ReviewFileChange
    var maximumLines = Int.max
    var showsLineNumbers = true
    /// A "Show N more lines" footer grows the block in place (Changes rows); the card's own
    /// "Show full diff" button handles it otherwise.
    var expandsInPlace = false
    /// Rows are built lazily (the sheet with a whole diff); inside the transcript they are not.
    var isLazy = false
    /// Long lines wrap (the web's default); off scrolls the block sideways.
    var wraps = true
    /// The Changes tab lets rows be selected for a comment; nil = rows are not tappable.
    var selection: Binding<OCDiffSelection?>?
    /// File line numbers that carry a comment (marked in the gutter).
    var commentedLines: [OCCommentedRange] = []
    /// Reports how many diff lines exist (nil until the hunks are built).
    var onLineCount: (Int) -> Void = { _ in }

    @State private var render: OCDiffRender?
    @State private var limit = 0
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        Group {
            if let render {
                content(render)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .task(id: file) {
            let file = file
            let built = await OCFileSupport.runCancellable { OCDiffRender.build(file: file) }
            guard !Task.isCancelled else { return }
            render = built
            onLineCount(built.lines.count)
        }
    }

    @ViewBuilder
    private func content(_ render: OCDiffRender) -> some View {
        let all = render.lines
        let shown = min(all.count, max(limit, maximumLines))
        if all.isEmpty {
            Text(AppText.ocNoDiff)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            Group {
                if wraps {
                    stack(render, all: all, shown: shown)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        stack(render, all: all, shown: shown)
                            .frame(minWidth: availableWidth, alignment: .leading)
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
                }
            }
            .overlay(alignment: .topLeading) {
                Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.diff")
            }
        }
    }

    @ViewBuilder
    private func stack(_ render: OCDiffRender, all: [UnifiedDiffLine], shown: Int) -> some View {
        if isLazy {
            LazyVStack(alignment: .leading, spacing: 0) { rows(render, all: all, shown: shown) }
        } else {
            VStack(alignment: .leading, spacing: 0) { rows(render, all: all, shown: shown) }
        }
    }

    @ViewBuilder
    private func rows(_ render: OCDiffRender, all: [UnifiedDiffLine], shown: Int) -> some View {
        ForEach(0..<shown, id: \.self) { index in row(all[index], index: index, render: render) }
        if expandsInPlace, all.count > shown {
            Button {
                limit = shown + 400
            } label: {
                Text(AppText.ocShowMoreLines(all.count - shown))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appPrimary)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.diff.more")
        }
    }

    private func isSelected(_ index: Int, render: OCDiffRender) -> Bool {
        guard let current = selection?.wrappedValue, current.file == file.path else { return false }
        return current.covers(row: index, lines: render.info)
    }

    private func isCommented(_ line: UnifiedDiffLine) -> Bool {
        let side: OCDiffSide = line.kind == .removed ? .deletions : .additions
        guard let number = side == .deletions ? line.oldLineNumber : line.newLineNumber else { return false }
        return commentedLines.contains { $0.side == side && $0.range.contains(number) }
    }

    @ViewBuilder
    private func row(_ line: UnifiedDiffLine, index: Int, render: OCDiffRender) -> some View {
        let content = HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(bar(line.kind)).frame(width: 2)
            Text(showsLineNumbers ? (line.newLineNumber ?? line.oldLineNumber).map(String.init) ?? "" : "")
                .font(.openLensMono(size: 12))
                .fontWeight(isCommented(line) ? .bold : .regular)
                .foregroundStyle(isCommented(line) ? Color.appAccent : Color.appSecondary)
                .frame(width: showsLineNumbers ? 38 : 4, alignment: .trailing)
            Text(index < render.attributed.count ? render.attributed[index] : AttributedString(line.text))
                .font(.openLensMono(size: 12))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
                .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 2)
            if !wraps { Spacer(minLength: 0) }
        }
        .frame(maxWidth: wraps ? nil : .infinity, alignment: .leading)
        .background { Rectangle().fill(tint(line.kind)) }
        .overlay { Rectangle().fill(Color.appAccent.opacity(isSelected(index, render: render) ? 0.18 : 0)) }
        if let selection {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    selection.wrappedValue = OCDiffSelection.toggled(
                        selection.wrappedValue, file: file.path, row: index, lines: render.info
                    )
                }
                .accessibilityIdentifier("oc.diff.line")
                .accessibilityLabel("\(index + 1)")
                .accessibilityAddTraits(isSelected(index, render: render) ? [.isSelected, .isButton] : [.isButton])
        } else {
            content
        }
    }

    private func bar(_ kind: UnifiedDiffLine.Kind) -> Color {
        switch kind {
        case .added: Color.appSuccess
        case .removed: Color.appDanger
        case .context: .clear
        }
    }

    private func tint(_ kind: UnifiedDiffLine.Kind) -> Color {
        switch kind {
        case .added: Color.appSuccess.opacity(0.14)
        case .removed: Color.appDanger.opacity(0.14)
        case .context: .clear
        }
    }
}

/// A diff that waits for "Render anyway" above `OCFileSupport.maximumDiffChangedLines` changed
/// lines (the web's large-diff card), and shows "Binary file" when there is nothing to diff.
struct OCGuardedDiff: View {
    let file: ReviewFileChange
    var showsLineNumbers = true
    var selection: Binding<OCDiffSelection?>?
    var commentedLines: [OCCommentedRange] = []
    @AppStorage(OCDiffSettings.wrapKey) private var wraps = true
    @State private var loads = false

    var body: some View {
        if OCFileSupport.isBinary(file) {
            Text(AppText.ocBinaryFile)
                .font(.system(size: 12))
                .foregroundStyle(Color.appSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("oc.diff.binary")
        } else if OCFileSupport.isTooLarge(file), !loads {
            VStack(spacing: 6) {
                Text(AppText.ocLargeDiffTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                Text(AppText.ocLargeDiffMeta(
                    limit: OCFileSupport.maximumDiffChangedLines, current: file.additions + file.deletions
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
                Button { loads = true } label: {
                    Text(AppText.ocRenderAnyway)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.appPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("oc.diff.large")
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        } else {
            OCDiffBlock(
                file: file, maximumLines: 400, showsLineNumbers: showsLineNumbers, expandsInPlace: true,
                wraps: wraps, selection: selection, commentedLines: commentedLines
            )
        }
    }
}

// MARK: - Used-N file card

/// An Edit / Write / apply_patch row inside an expanded "Used N" group: the web's file card.
/// Until the part's file change is known (or when it has none) the ordinary tool line shows.
struct OCFileToolLine<Fallback: View>: View {
    let part: OCGroupedPart
    let onDetails: () -> Void
    @ViewBuilder let fallback: () -> Fallback

    @State private var files: [OCToolFileChange]?

    /// A running edit becomes a card when it completes: the task re-keys on the call's state.
    private var taskKey: String {
        guard let segment = part.segment, case .tool(let step) = segment.kind else { return part.id }
        return "\(part.id)|\(step.isRunning)|\(step.isError)"
    }

    var body: some View {
        Group {
            if let files, !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, change in
                        OCFileCard(change: change, stateID: "\(part.id)/\(index)", onDetails: onDetails)
                    }
                }
            } else {
                fallback()
            }
        }
        .task(id: taskKey) {
            guard let raw = part.message.parts.first(where: { $0.id == part.segmentID }) else { return }
            files = await Task.detached(priority: .userInitiated) {
                OCFileSupport.fileChanges(of: raw)
            }.value
        }
    }
}

/// Which file cards are open, kept outside the views: the lazy transcript recycles rows, which
/// would otherwise reset a card's own state.
@MainActor @Observable
final class OCFileCardStore {
    static let shared = OCFileCardStore()
    private(set) var open: Set<String> = []

    func toggle(_ id: String) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }
}

/// Bordered card: file icon, directory muted + bold name, +N -N, chevron; opens a clipped diff.
/// Long press / context menu: "Details" (the tool's output sheet).
struct OCFileCard: View {
    let change: OCToolFileChange
    let stateID: String
    let onDetails: () -> Void

    @Environment(\.ocSessionDirectory) private var directory
    private var open: Bool { OCFileCardStore.shared.open.contains(stateID) }
    @State private var showsAll = false
    @State private var lineCount: Int?
    @AppStorage(OCDiffSettings.wrapKey) private var wraps = true

    /// Rows shown inline; the rest opens in a sheet. The inline diff is clipped, not scrolled:
    /// a scroll view that grows inside the lazy transcript is what the repin loop fed on.
    private static let inlineLines = 30

    var body: some View {
        let file = change.file
        let path = OCFileSupport.relative(file.path, to: directory)
        VStack(spacing: 0) {
            Button {
                OCFileCardStore.shared.toggle(stateID)
            } label: {
                HStack(spacing: 8) {
                    OCFileTypeIcon(name: OCFileSupport.split(path: path).name)
                    OCPathLabel(path: path, boldName: true)
                    Spacer(minLength: 6)
                    OCDiffCounts(additions: file.additions, deletions: file.deletions)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.fileCard")
            .accessibilityLabel(path)
            .accessibilityValue("+\(file.additions) -\(file.deletions), \(open ? "expanded" : "collapsed")")

            if open {
                Rectangle().fill(Color.appSeparator).frame(height: 1)
                OCDiffBlock(file: file, maximumLines: Self.inlineLines, showsLineNumbers: change.hasRealLineNumbers) {
                    lineCount = $0
                }
                .frame(maxHeight: 250, alignment: .top)
                .clipped()
                if (lineCount ?? 0) > Self.inlineLines {
                    Button { showsAll = true } label: {
                        Text(AppText.ocShowFullDiff)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.appPrimary)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("oc.fileCard.showAll")
                }
            }
        }
        .contextMenu {
            Button(AppText.ocToolDetails, systemImage: "info.circle", action: onDetails)
        }
        .sheet(isPresented: $showsAll) {
            ScrollView {
                OCDiffBlock(file: change.file, showsLineNumbers: change.hasRealLineNumbers, isLazy: true, wraps: wraps)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.appSeparator, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
