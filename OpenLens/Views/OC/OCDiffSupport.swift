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
    static let ocFileTooLarge = "File too large to preview"
    static let ocWrapLines = "Wrap lines"
    static let ocCreateGit = "Create Git repository"
    static let ocCreatingGit = "Creating…"
    static let ocGitInitStale = "The repository was created, but the server still reports none. Reopen the project to refresh."
    static let ocLineCommentPlaceholder = "Add comment"
    static let ocLineCommentSubmit = "Comment"
    static let ocLineCommentCancel = "Cancel"
    static let ocLineCommentRemove = "Remove comment"
    static let ocLineCommentEdit = "Edit"
    static let ocLineCommentDelete = "Delete"
    static let ocLineCommentSave = "Save"
    static let ocLineCommentMore = "More options"
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

// MARK: - File kinds (Files viewer)

nonisolated enum OCFilePreviewKind: Sendable { case text, markdown, image, audio }

extension OCFileSupport {
    nonisolated static func previewKind(path: String) -> OCFilePreviewKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdx": .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico": .image
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "oga", "aif", "aiff": .audio
        default: .text
        }
    }
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

/// Which file a diff line belongs to: removed rows are the old file, the rest the new one. Line
/// numbers of the two sides are separate, so selections and comments carry the side (as the web's).
nonisolated enum OCDiffSide: Sendable { case additions, deletions }

/// A commented run of lines on one side (marks the gutter).
nonisolated struct OCCommentedRange: Sendable {
    let range: ClosedRange<Int>
    let side: OCDiffSide
}

/// A selected run of diff rows of one file: row indexes for the highlight, file line numbers
/// for the comment ("lines 12 through 14 of path").
nonisolated struct OCDiffSelection: Equatable, Sendable {
    let file: String
    let rows: ClosedRange<Int>
    let startLine: Int
    let endLine: Int
    let preview: String
    /// The side of the last tapped row; the line numbers count that side only.
    var side: OCDiffSide = .additions

    /// A row is highlighted only on the selected side, so the highlight matches the comment's lines.
    nonisolated func covers(row: Int, lines: [OCDiffLineInfo]) -> Bool {
        rows.contains(row) && lines.indices.contains(row) && lines[row].side == side
    }

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
        let side = lines[row].side
        let numbers = rows.compactMap { lines[$0].side == side ? lines[$0].number : nil }
        guard let first = numbers.min(), let last = numbers.max() else { return nil }
        let preview = rows.filter { lines[$0].side == side }.prefix(3).map { lines[$0].text }.joined(separator: "\n")
        return OCDiffSelection(file: file, rows: rows, startLine: first, endLine: last, preview: preview, side: side)
    }
}

/// What the selection needs of a diff row.
nonisolated struct OCDiffLineInfo: Sendable {
    let number: Int?
    let text: String
    var side: OCDiffSide = .additions
}

// MARK: - Line comments (the composer context)

nonisolated struct OCDiffComment: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: String
    let file: String
    let startLine: Int
    let endLine: Int
    var text: String
    let preview: String
    var side: OCDiffSide = .additions
    /// Set for text quoted from the terminal (the web's `quote` context item); `text` is then the
    /// optional comment, `file` and the lines are unused.
    var quote: String? = nil

    /// A terminal selection waiting in the composer (the web's Quote button on a terminal).
    static func terminalQuote(sessionID: String, text: String) -> OCDiffComment {
        OCDiffComment(
            id: UUID(), sessionID: sessionID, file: "", startLine: 0, endLine: 0, text: "", preview: text, quote: text
        )
    }

    /// The quote as the model receives it, word for word the web's `formatQuoteComment`: every
    /// quoted line prefixed, so quoted text can't read as the user's own words.
    var quoteBlock: String? {
        guard let quote else { return nil }
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (["From the terminal:"]
            + quote.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
            + (comment.isEmpty ? [] : ["", comment])).joined(separator: "\n")
    }

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
    /// The quote whose optional comment editor is open (the web opens it right after Quote).
    var editingQuoteID: UUID?

    func comments(sessionID: String?) -> [OCDiffComment] {
        guard let sessionID else { return [] }
        return all.filter { $0.sessionID == sessionID }
    }

    func comments(sessionID: String?, file: String) -> [OCDiffComment] {
        comments(sessionID: sessionID).filter { $0.quote == nil && $0.file == file }
    }

    /// Quotes terminal text into the session's composer; empty text adds nothing.
    @discardableResult
    func addQuote(sessionID: String, text: String) -> OCDiffComment? {
        guard !text.isEmpty else { return nil }
        let quote = OCDiffComment.terminalQuote(sessionID: sessionID, text: text)
        all.append(quote)
        editingQuoteID = quote.id
        return quote
    }

    /// The comment on a quote (blank removes it); line comments keep their non-empty rule.
    func setQuoteComment(_ id: UUID, text: String) {
        guard let index = all.firstIndex(where: { $0.id == id }), all[index].quote != nil else { return }
        all[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func add(sessionID: String, file: String, selection: OCDiffSelection, text: String) -> OCDiffComment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let comment = OCDiffComment(
            id: UUID(), sessionID: sessionID, file: file,
            startLine: selection.startLine, endLine: selection.endLine, text: trimmed, preview: selection.preview,
            side: selection.side
        )
        all.append(comment)
        return comment
    }

    /// The web's "Edit": new text for a saved comment (blank text keeps the old one).
    func update(_ id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].text = trimmed
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        if editingQuoteID == id { editingQuoteID = nil }
    }

    func clear(sessionID: String) {
        if let editingQuoteID, all.contains(where: { $0.id == editingQuoteID && $0.sessionID == sessionID }) {
            self.editingQuoteID = nil
        }
        all.removeAll { $0.sessionID == sessionID }
    }

    /// Comments join a prompt unless it is a recognised slash command (a chip, "/undo" or a known
    /// command or agent token), which must keep starting with "/". A path such as "/etc/hosts" is text.
    nonisolated static func commentsApply(typed: String, hasSlashChip: Bool, knownTokens: [String] = []) -> Bool {
        if hasSlashChip { return false }
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return true }
        let word = String(text.dropFirst().prefix { !$0.isWhitespace }).lowercased()
        if word == "undo" { return false }
        let known = knownTokens.map { String($0.drop { $0 == "/" }).lowercased() }
        return !known.contains(word)
    }

    /// The prompt as sent, like the web's request builder: quotes lead (like an email reply), then
    /// a blank line and the typed text with the comment sentences, one per line.
    nonisolated static func composedPrompt(comments: [OCDiffComment], typed: String) -> String {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = comments.compactMap(\.quoteBlock)
        let body = ([text] + comments.filter { $0.quote == nil }.map(\.note)).filter { !$0.isEmpty }.joined(separator: "\n")
        return (quotes + [body]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

// MARK: - Highlighted diff lines, cached

/// One diff's rows with their syntax segments; built off the main actor, cached per file content.
nonisolated final class OCDiffRender: @unchecked Sendable {
    let lines: [UnifiedDiffLine]
    let segments: [[OCSyntaxSegment]]
    /// The coloured text of every row, built off the main actor together with the segments.
    let attributed: [AttributedString]
    let info: [OCDiffLineInfo]

    init(lines: [UnifiedDiffLine], segments: [[OCSyntaxSegment]]) {
        self.lines = lines
        self.segments = segments
        self.attributed = segments.map(OCSyntaxTheme.attributed)
        self.info = lines.map { OCDiffLineInfo(
            number: $0.kind == .removed ? $0.oldLineNumber : $0.newLineNumber, text: $0.text,
            side: $0.kind == .removed ? .deletions : .additions
        ) }
    }

    /// Cost = characters held (text + segments + coloured text), so a few huge diffs cannot pile up.
    nonisolated static let cache: NSCache<NSString, OCDiffRender> = {
        let cache = NSCache<NSString, OCDiffRender>()
        cache.countLimit = 48
        cache.totalCostLimit = 24_000_000
        return cache
    }()

    nonisolated static func key(for file: ReviewFileChange) -> NSString {
        "\(file.path)|\(file.hashValue)" as NSString
    }

    /// Hunks -> truncated lines -> highlighted, coloured rows. Pure; call it detached. The
    /// highlighter starts fresh at every hunk (a hunk can open in the middle of a comment or string
    /// that the previous hunk never closed). A cancelled build is returned but not cached.
    nonisolated static func build(file: ReviewFileChange) -> OCDiffRender {
        let key = key(for: file)
        if let hit = cache.object(forKey: key) { return hit }
        let hunks = UnifiedDiffBuilder.makeHunks(file: file)
        let language = OCSyntaxLanguage.detect(path: file.path)
        var lines: [UnifiedDiffLine] = []
        var segments: [[OCSyntaxSegment]] = []
        for hunk in hunks {
            lines += hunk.lines
            segments += OCSyntaxHighlighter.highlight(
                diffLines: hunk.lines.map {
                    (text: OCFileSupport.truncated($0.text), isRemoved: $0.kind == .removed, isAdded: $0.kind == .added)
                },
                language: language
            )
        }
        let render = OCDiffRender(lines: lines, segments: segments)
        if !Task.isCancelled {
            let cost = lines.reduce(0) { $0 + $1.text.utf16.count * 3 }
            cache.setObject(render, forKey: key, cost: cost)
        }
        return render
    }
}


// MARK: - What the tabs remember per session (in memory, per app run)

nonisolated struct OCChangesMemory: Sendable {
    var mode: OCChangesMode?
    var expanded: Set<String> = []
}

nonisolated struct OCFilesMemory: Sendable {
    var openPaths: [String] = []
    var activePath: String?
}

/// Like the web's per-session review model: the chosen Changes mode and expanded files, and the open
/// Files tabs, outlive the tab views for the rest of the app run. The Files tabs are keyed by the
/// session's folder (the Files view only knows the folder).
@MainActor
final class OCSessionMemory {
    static let shared = OCSessionMemory()
    private var changes: [String: OCChangesMemory] = [:]
    private var files: [String: OCFilesMemory] = [:]

    func changes(sessionID: String) -> OCChangesMemory { changes[sessionID] ?? OCChangesMemory() }
    func setChanges(_ value: OCChangesMemory, sessionID: String) { changes[sessionID] = value }
    func files(directory: String?) -> OCFilesMemory? { directory.flatMap { files[$0] } }
    func setFiles(_ value: OCFilesMemory, directory: String?) {
        if let directory { files[directory] = value }
    }

    /// The remembered mode while it is still offered, else the first one (the web's rule).
    nonisolated static func resolvedMode(remembered: OCChangesMode?, offered: [OCChangesMode]) -> OCChangesMode? {
        if let remembered, offered.contains(remembered) { return remembered }
        return offered.first
    }
}
