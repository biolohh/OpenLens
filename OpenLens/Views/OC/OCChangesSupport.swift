import SwiftUI

// MARK: - Strings of the Changes / Files tabs (the web's wording)

extension AppText {
    static let ocChangesGit = "Git changes"
    static let ocChangesTurn = "Last turn changes"
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
}

// MARK: - Changes model

/// The web's review modes that the app can serve: the git working tree and the newest turn.
enum OCChangesMode: String, CaseIterable, Hashable, Sendable {
    case git
    case turn

    var title: String {
        switch self {
        case .git: AppText.ocChangesGit
        case .turn: AppText.ocChangesTurn
        }
    }

    var emptyText: String {
        switch self {
        case .git: AppText.ocChangesEmptyGit
        case .turn: AppText.ocChangesEmptyTurn
        }
    }
}

struct OCChangesAvailability: Equatable, Sendable {
    /// The session's project is a git repository; without it the web shows "No tracked changes".
    let isGit: Bool
    let modes: [OCChangesMode]
}

/// Pure helpers shared by the Changes tab, the Used-N file card and the Files tab (unit-tested).
enum OCFileSupport {
    /// "_scratch/PROGRESS.md" -> ("_scratch/", "PROGRESS.md"); the directory keeps its trailing slash.
    static func split(path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let next = path.index(after: slash)
        return (String(path[..<next]), String(path[next...]))
    }

    /// Path relative to the session folder when the server reports an absolute one.
    static func relative(_ path: String, to directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }
        let root = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
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
        case "js", "ts", "jsx", "tsx", "swift", "py", "sh", "rs", "go", "kt": ("curlybraces", .yellow)
        case "json", "yml", "yaml", "toml": ("curlybraces.square", .purple)
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": ("photo", .green)
        default: ("doc.text", nil)
        }
    }

    static func isFileTool(_ toolName: String) -> Bool {
        ["edit", "write", "apply_patch", "patch"].contains(toolName.lowercased())
    }

    /// The file a finished Edit / Write / apply_patch call changed, from the tool part:
    /// the server's own per-call patch (`metadata.files`) for edit and apply_patch, the written
    /// content for write. Nil when the part carries neither.
    static func fileChanges(of part: OCPart) -> [ReviewFileChange] {
        guard part.type == .tool, let state = part.state, state.status == .completed else { return [] }
        let tool = (part.tool ?? "").lowercased()
        guard ["edit", "write", "apply_patch", "patch"].contains(tool) else { return [] }

        if let raw = state.metadata?["files"]?.value as? [Any] {
            let changes = raw.compactMap { item -> ReviewFileChange? in
                guard let dict = item as? [String: Any],
                      let file = (dict["file"] as? String) ?? (dict["relativePath"] as? String) ?? (dict["filePath"] as? String)
                else { return nil }
                let patch = (dict["patch"] as? String) ?? (dict["diff"] as? String)
                let status = (dict["status"] as? String) ?? (dict["type"] as? String)
                return ReviewFileChange(diff: OCFileDiff(
                    file: file,
                    status: status,
                    additions: dict["additions"] as? Int,
                    deletions: dict["deletions"] as? Int,
                    before: dict["before"] as? String,
                    after: dict["after"] as? String,
                    patchText: patch
                ))
            }
            if !changes.isEmpty { return changes }
        }

        guard let input = state.input?.value as? [String: Any] else { return [] }
        let path = (input["path"] as? String) ?? (input["filePath"] as? String)
        guard let path else { return [] }
        if tool == "write", let content = input["content"] as? String {
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last == "" { lines.removeLast() }
            return [ReviewFileChange(diff: OCFileDiff(file: path, status: "A", additions: lines.count, deletions: 0, after: content))]
        }
        if tool == "edit", let old = input["oldString"] as? String, let new = input["newString"] as? String {
            return [ReviewFileChange(diff: OCFileDiff(file: path, before: old, after: new))]
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

/// The web's unified diff: line number column, wrapped monospace lines, added lines tinted green
/// with a 2 pt bar on the left, removed ones red. Plain `VStack` (no nested lazy or horizontal
/// scrolling), so it is safe inside a transcript row; long diffs are cut at `maximumLines`.
struct OCDiffBlock: View {
    let file: ReviewFileChange
    var maximumLines = 400
    /// Reports how many diff lines exist (the card shows "Show all" when it clips).
    var onLineCount: (Int) -> Void = { _ in }

    @State private var hunks: [UnifiedDiffHunk]?

    var body: some View {
        Group {
            if let hunks {
                content(hunks)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .task(id: file) {
            let file = file
            let built = await Task.detached(priority: .userInitiated) {
                UnifiedDiffBuilder.makeHunks(file: file)
            }.value
            hunks = built
            onLineCount(built.reduce(0) { $0 + $1.lines.count })
        }
    }

    @ViewBuilder
    private func content(_ hunks: [UnifiedDiffHunk]) -> some View {
        let lines = Array(hunks.flatMap(\.lines).prefix(maximumLines))
        if lines.isEmpty {
            Text(AppText.ocNoDiff)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in row(line) }
            }
            .overlay(alignment: .topLeading) {
                Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.diff")
            }
        }
    }

    private func row(_ line: UnifiedDiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(bar(line.kind)).frame(width: 2)
            Text((line.newLineNumber ?? line.oldLineNumber).map(String.init) ?? "")
                .font(.openLensMono(size: 12))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 38, alignment: .trailing)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.openLensMono(size: 12))
                .foregroundStyle(Color.appPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 2)
        }
        .background(tint(line.kind))
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

// MARK: - Used-N file card

/// An Edit / Write / apply_patch row inside an expanded "Used N" group: the web's file card.
/// Until the part's file change is known (or when it has none) the ordinary tool line shows.
struct OCFileToolLine<Fallback: View>: View {
    let part: OCGroupedPart
    @ViewBuilder let fallback: () -> Fallback

    @State private var files: [ReviewFileChange]?

    var body: some View {
        Group {
            if let files, !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        OCFileCard(file: file, stateID: "\(part.id)/\(index)")
                    }
                }
            } else {
                fallback()
            }
        }
        .task(id: part.id) {
            guard let raw = part.message.parts.first(where: { $0.id == part.segmentID }) else { return }
            files = await Task.detached(priority: .userInitiated) {
                OCFileSupport.fileChanges(of: raw)
            }.value
        }
    }
}

/// Bordered card: file icon, directory muted + bold name, +N -N, chevron; opens the diff inline
/// in a bounded scroll box.
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

struct OCFileCard: View {
    let file: ReviewFileChange
    let stateID: String

    @Environment(\.ocSessionDirectory) private var directory
    private var open: Bool { OCFileCardStore.shared.open.contains(stateID) }
    @State private var showsAll = false
    @State private var lineCount = 0

    /// Rows shown inline; the rest opens in a sheet. A nested scroll view inside the lazy
    /// transcript froze the main thread, so the inline diff is clipped, not scrolled.
    private static let inlineLines = 30

    var body: some View {
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
                OCDiffBlock(file: file, maximumLines: Self.inlineLines) { lineCount = $0 }
                    .frame(maxHeight: 250, alignment: .top)
                    .clipped()
                if lineCount > Self.inlineLines || lineCount == 0 {
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
        .sheet(isPresented: $showsAll) {
            ScrollView { OCDiffBlock(file: file) }
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
