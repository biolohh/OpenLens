import Foundation
import SwiftUI

// MARK: - Strings (the web's wording; session-ui / review i18n)

extension AppText {
    static let ocLargeDiffTitle = "Diff too large to render"
    static func ocLargeDiffMeta(limit: Int, current: Int) -> String {
        "Limit: \(limit) changed lines. Current: \(current) changed lines."
    }
    static let ocRenderAnyway = "Render anyway"
    static let ocBinaryFile = "Binary file"
    static let ocWrapLines = "Wrap lines"
    static let ocCreateGit = "Create Git repository"
    static let ocCreatingGit = "Creating…"
    static let ocLineCommentPlaceholder = "Add comment"
    static let ocLineCommentSubmit = "Comment"
    static let ocLineCommentCancel = "Cancel"
    static let ocLineCommentRemove = "Remove comment"
    static let ocGitTimeout = "The server took too long to answer"
    /// "line 4" / "lines 4-9", as the web names a selection.
    static func ocLineCommentRange(start: Int, end: Int) -> String {
        start == end ? "line \(start)" : "lines \(start)-\(end)"
    }
    static func ocLineCommentSaved(start: Int, end: Int) -> String { "Comment on " + ocLineCommentRange(start: start, end: end) }
    static func ocLineCommentEditing(start: Int, end: Int) -> String { "Commenting on " + ocLineCommentRange(start: start, end: end) }
    /// The composer chip's second line: "hello.txt:1" / "hello.txt:1-3".
    static func ocLineCommentChipLocation(file: String, start: Int, end: Int) -> String {
        let name = (file as NSString).lastPathComponent
        return start == end ? "\(name):\(start)" : "\(name):\(start)-\(end)"
    }
}

// MARK: - Diff settings

enum OCDiffSettings {
    /// "Wrap lines" (the web's `settings-mobile-diff-wrap`, on by default).
    static let wrapKey = "oc.diff.wrap"
}

// MARK: - Large diffs and binary files

extension OCFileSupport {
    /// The web's `MAX_DIFF_CHANGED_LINES`: a file with more changed lines waits for "Render anyway".
    nonisolated static let maximumDiffChangedLines = 500

    nonisolated static func isTooLarge(_ file: ReviewFileChange) -> Bool {
        file.additions + file.deletions > maximumDiffChangedLines
    }

    /// The web shows "Binary file" when a diff has neither added nor removed lines (and no media preview).
    nonisolated static func isBinary(_ file: ReviewFileChange) -> Bool {
        file.additions == 0 && file.deletions == 0 && file.patchHunks.isEmpty
            && (file.beforeText ?? "").isEmpty && (file.afterText ?? "").isEmpty
    }
}

// MARK: - Line selection

/// A selected run of diff rows of one file: row indexes for the highlight, file line numbers
/// for the comment ("lines 12 through 14 of path").
nonisolated struct OCDiffSelection: Equatable, Sendable {
    let file: String
    let rows: ClosedRange<Int>
    let startLine: Int
    let endLine: Int
    let preview: String

    /// Tap logic of the mobile diff: a first tap selects a line, a second tap on another line
    /// extends it to a range, a tap on the selected line (or a third tap) starts over.
    nonisolated static func toggled(
        _ current: OCDiffSelection?, file: String, row: Int, lines: [OCDiffLineInfo]
    ) -> OCDiffSelection? {
        guard lines.indices.contains(row) else { return nil }
        let rows: ClosedRange<Int>
        if let current, current.file == file {
            if current.rows.count == 1, current.rows.lowerBound == row { return nil }
            if current.rows.count == 1 {
                rows = min(current.rows.lowerBound, row)...max(current.rows.lowerBound, row)
            } else {
                rows = row...row
            }
        } else {
            rows = row...row
        }
        let numbers = rows.compactMap { lines[$0].number }
        guard let first = numbers.min(), let last = numbers.max() else { return nil }
        let preview = rows.prefix(3).map { lines[$0].text }.joined(separator: "\n")
        return OCDiffSelection(file: file, rows: rows, startLine: first, endLine: last, preview: preview)
    }
}

/// What the selection needs of a diff row.
nonisolated struct OCDiffLineInfo: Sendable {
    let number: Int?
    let text: String
}

// MARK: - Line comments (the composer context)

nonisolated struct OCDiffComment: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: String
    let file: String
    let startLine: Int
    let endLine: Int
    let text: String
    let preview: String

    /// The sentence the model receives, word for word the web's `formatCommentNote`.
    var note: String {
        let range = startLine == endLine ? "line \(startLine)" : "lines \(startLine) through \(endLine)"
        return "The user made the following comment regarding \(range) of \(file): \(text)"
    }
}

/// Line comments waiting in the composer, per session. The Changes tab adds them, the chat
/// composer shows them as chips and folds them into the next prompt.
@MainActor @Observable
final class OCDiffCommentStore {
    static let shared = OCDiffCommentStore()
    private(set) var all: [OCDiffComment] = []

    func comments(sessionID: String?) -> [OCDiffComment] {
        guard let sessionID else { return [] }
        return all.filter { $0.sessionID == sessionID }
    }

    func comments(sessionID: String?, file: String) -> [OCDiffComment] {
        comments(sessionID: sessionID).filter { $0.file == file }
    }

    @discardableResult
    func add(sessionID: String, file: String, selection: OCDiffSelection, text: String) -> OCDiffComment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let comment = OCDiffComment(
            id: UUID(), sessionID: sessionID, file: file,
            startLine: selection.startLine, endLine: selection.endLine, text: trimmed, preview: selection.preview
        )
        all.append(comment)
        return comment
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
    }

    func clear(sessionID: String) {
        all.removeAll { $0.sessionID == sessionID }
    }

    /// The prompt as sent: the comment sentences first (one paragraph each), then what was typed.
    nonisolated static func composedPrompt(comments: [OCDiffComment], typed: String) -> String {
        let notes = comments.map(\.note)
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return (notes + (text.isEmpty ? [] : [text])).joined(separator: "\n\n")
    }
}

// MARK: - Highlighted diff lines, cached

/// One diff's rows with their syntax segments; built off the main actor, cached per file content.
nonisolated final class OCDiffRender: @unchecked Sendable {
    let lines: [UnifiedDiffLine]
    let segments: [[OCSyntaxSegment]]
    let info: [OCDiffLineInfo]

    init(lines: [UnifiedDiffLine], segments: [[OCSyntaxSegment]]) {
        self.lines = lines
        self.segments = segments
        self.info = lines.map { OCDiffLineInfo(number: $0.newLineNumber ?? $0.oldLineNumber, text: $0.text) }
    }

    nonisolated static let cache: NSCache<NSString, OCDiffRender> = {
        let cache = NSCache<NSString, OCDiffRender>()
        cache.countLimit = 48
        return cache
    }()

    nonisolated static func key(for file: ReviewFileChange) -> NSString {
        "\(file.path)|\(file.hashValue)" as NSString
    }

    /// Hunks -> truncated lines -> highlighted segments. Pure; call it detached.
    nonisolated static func build(file: ReviewFileChange) -> OCDiffRender {
        let key = key(for: file)
        if let hit = cache.object(forKey: key) { return hit }
        let lines = UnifiedDiffBuilder.makeHunks(file: file).flatMap(\.lines)
        let language = OCSyntaxLanguage.detect(path: file.path)
        let texts = lines.map { OCFileSupport.truncated($0.text) }
        let segments = OCSyntaxHighlighter.highlight(
            diffLines: zip(lines, texts).map { (text: $1, isRemoved: $0.kind == .removed, isAdded: $0.kind == .added) },
            language: language
        )
        let render = OCDiffRender(lines: lines, segments: segments)
        cache.setObject(render, forKey: key)
        return render
    }
}
