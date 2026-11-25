import Foundation

/// A small line-based syntax highlighter for the Changes diffs and the Files viewer. It only
/// splits text into coloured segments; it knows nothing about colours (`OCSyntaxTheme` maps
/// the kinds to the theme), so it is pure, nonisolated and safe to run off the main actor.
nonisolated enum OCSyntaxKind: UInt8, Sendable, CaseIterable {
    case plain
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case tag
    case property
}

nonisolated struct OCSyntaxSegment: Equatable, Sendable {
    let text: String
    let kind: OCSyntaxKind
}

nonisolated enum OCSyntaxLanguage: String, Sendable, CaseIterable {
    case swift, script, python, json, yaml, markdown, shell, html, css, c, plain

    /// By file name (or extension); unknown files stay plain.
    static func detect(path: String) -> OCSyntaxLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "makefile", "dockerfile", ".bashrc", ".zshrc", ".profile", ".env": return .shell
        default: break
        }
        switch (name as NSString).pathExtension {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return .script
        case "py", "pyw": return .python
        case "json", "jsonc", "json5": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown", "mdx": return .markdown
        case "sh", "bash", "zsh", "fish", "env": return .shell
        case "html", "htm", "xml", "svg", "vue", "svelte": return .html
        case "css", "scss", "less": return .css
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm", "java", "kt", "kts", "go", "rs", "cs":
            return .c
        default: return .plain
        }
    }
}

nonisolated enum OCSyntaxHighlighter {
    /// What a line leaves open for the next one.
    enum State: Equatable, Sendable {
        case none
        case blockComment
        case tripleString(Character)
        case fence
        case htmlComment
    }

    /// Longest line that is scanned; longer ones are cut by the caller already, this only guards
    /// against a pathological single line.
    static let maximumLineLength = 2000

    /// All lines of one text in order, carrying block comments and multi-line strings across.
    static func highlight(lines: [String], language: OCSyntaxLanguage) -> [[OCSyntaxSegment]] {
        guard language != .plain else { return lines.map { [OCSyntaxSegment(text: $0, kind: .plain)] } }
        var state = State.none
        var result: [[OCSyntaxSegment]] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            // A cancelled caller discards the result: stop burning CPU, keep the shape.
            if index % 200 == 0, Task.isCancelled {
                result.append(contentsOf: lines[index...].map { [OCSyntaxSegment(text: $0, kind: .plain)] })
                break
            }
            let (segments, next) = highlight(line: line, language: language, state: state)
            result.append(segments)
            state = next
        }
        return result
    }

    /// One line, given the state the previous line left; returns the state for the next one.
    static func highlight(line: String, language: OCSyntaxLanguage, state: State) -> ([OCSyntaxSegment], State) {
        if line.isEmpty { return ([], state) }
        if language == .plain || line.utf16.count > maximumLineLength {
            return ([OCSyntaxSegment(text: line, kind: .plain)], state)
        }
        var scanner = Scanner(chars: Array(line), language: language, state: state)
        scanner.run()
        return (scanner.output.segments, scanner.state)
    }

    // MARK: Language tables

    private static let swiftKeywords: Set<String> = [
        "import", "func", "var", "let", "class", "struct", "enum", "protocol", "extension", "actor", "init", "deinit",
        "return", "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "in", "break",
        "continue", "fallthrough", "where", "do", "try", "catch", "throw", "throws", "rethrows", "async", "await",
        "self", "Self", "super", "nil", "true", "false", "public", "private", "fileprivate", "internal", "open",
        "static", "final", "override", "mutating", "nonisolated", "lazy", "weak", "unowned", "inout", "some", "any",
        "as", "is", "typealias", "associatedtype", "subscript", "defer", "operator", "get", "set", "willSet", "didSet",
    ]

    private static let scriptKeywords: Set<String> = [
        "import", "export", "from", "as", "default", "function", "const", "let", "var", "class", "extends", "new",
        "return", "if", "else", "switch", "case", "for", "while", "do", "break", "continue", "try", "catch",
        "finally", "throw", "async", "await", "yield", "typeof", "instanceof", "in", "of", "delete", "void", "this",
        "super", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "namespace",
        "declare", "readonly", "public", "private", "protected", "static", "abstract", "keyof", "satisfies", "get", "set",
    ]

    private static let pythonKeywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue", "pass", "import", "from",
        "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "global", "nonlocal", "assert", "del",
        "in", "is", "not", "and", "or", "None", "True", "False", "async", "await", "self", "cls", "match", "case",
    ]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function",
        "return", "exit", "export", "local", "readonly", "set", "unset", "source", "alias", "echo", "cd", "true",
        "false", "select", "shift", "trap", "eval", "exec",
    ]

    private static let cKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto",
        "struct", "union", "enum", "typedef", "class", "namespace", "template", "typename", "using", "public",
        "private", "protected", "virtual", "override", "final", "static", "const", "constexpr", "volatile", "extern",
        "inline", "register", "sizeof", "new", "delete", "this", "nullptr", "NULL", "true", "false", "try", "catch",
        "throw", "void", "int", "long", "short", "char", "float", "double", "unsigned", "signed", "bool", "auto",
        "fn", "let", "mut", "pub", "impl", "trait", "match", "use", "mod", "func", "package", "import", "var", "go",
        "defer", "chan", "range", "interface", "map", "fun", "val", "object", "when", "is", "in", "null", "super",
    ]

    private static let literalWords: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~"]

    // MARK: Scanner

    private struct Output {
        var segments: [OCSyntaxSegment] = []
        private var pending = ""
        private var pendingKind = OCSyntaxKind.plain

        mutating func add(_ text: String, _ kind: OCSyntaxKind) {
            guard !text.isEmpty else { return }
            if kind == pendingKind || pending.isEmpty {
                pending += text
                pendingKind = kind
            } else {
                segments.append(OCSyntaxSegment(text: pending, kind: pendingKind))
                pending = text
                pendingKind = kind
            }
        }

        /// `segments` including whatever is still pending.
        var finished: [OCSyntaxSegment] { segments }

        mutating func flush() {
            if !pending.isEmpty { segments.append(OCSyntaxSegment(text: pending, kind: pendingKind)) }
            pending = ""
        }
    }

    private struct Scanner {
        let chars: [Character]
        let language: OCSyntaxLanguage
        var state: State
        var output = FinishedOutput()
        var i = 0

        /// Wraps `Output` so `run` can flush before the segments are read.
        struct FinishedOutput {
            fileprivate var inner = Output()
            var segments: [OCSyntaxSegment] { inner.segments }
            mutating func add(_ text: String, _ kind: OCSyntaxKind) { inner.add(text, kind) }
            mutating func flush() { inner.flush() }
        }

        init(chars: [Character], language: OCSyntaxLanguage, state: State) {
            self.chars = chars
            self.language = language
            self.state = state
        }

        var n: Int { chars.count }

        func text(_ from: Int, _ to: Int) -> String { String(chars[from..<min(to, n)]) }

        /// Compares in place (no per-call allocation: this runs for every character).
        func starts(_ token: String, at index: Int) -> Bool {
            var k = index
            for scalar in token.unicodeScalars {
                guard k < n, chars[k] == Character(scalar) else { return false }
                k += 1
            }
            return true
        }

        /// A token that was not found once cannot be found from a later start either: remembered,
        /// so a line of unmatched "`" or "[" is not rescanned for every one of them.
        var missing: Set<String> = []

        mutating func find(_ token: String, from index: Int) -> Int? {
            if missing.contains(token) { return nil }
            var k = index
            while k < n {
                if starts(token, at: k) { return k }
                k += 1
            }
            missing.insert(token)
            return nil
        }

        mutating func add(_ from: Int, _ to: Int, _ kind: OCSyntaxKind) {
            output.add(text(from, to), kind)
        }

        static func isIdentStart(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter }
        static func isIdentPart(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter || c.isNumber }

        mutating func run() {
            switch language {
            case .markdown: markdown()
            case .html: html()
            default: code()
            }
            output.flush()
        }

        // MARK: Generic code (Swift, JS/TS, Python, C family, shell, JSON, YAML, CSS)

        var keywords: Set<String> {
            switch language {
            case .swift: OCSyntaxHighlighter.swiftKeywords
            case .script: OCSyntaxHighlighter.scriptKeywords
            case .python: OCSyntaxHighlighter.pythonKeywords
            case .shell: OCSyntaxHighlighter.shellKeywords
            case .c: OCSyntaxHighlighter.cKeywords
            case .json, .yaml: OCSyntaxHighlighter.literalWords
            default: []
            }
        }

        var lineComment: String? {
            switch language {
            case .swift, .script, .c: "//"
            case .python, .shell, .yaml: "#"
            default: nil
            }
        }

        var hasBlockComment: Bool {
            switch language {
            case .swift, .script, .c, .css: true
            default: false
            }
        }

        var triple: Bool { language == .python || language == .swift }
        var capitalizedAreTypes: Bool { language == .swift || language == .script || language == .c || language == .python }

        mutating func code() {
            // Carried-over multi-line constructs.
            if state == .blockComment {
                if let end = find("*/", from: 0) {
                    add(0, end + 2, .comment)
                    i = end + 2
                    state = .none
                } else {
                    add(0, n, .comment)
                    return
                }
            } else if case .tripleString(let quote) = state {
                let token = String(repeating: quote, count: 3)
                if let end = find(token, from: 0) {
                    add(0, end + 3, .string)
                    i = end + 3
                    state = .none
                } else {
                    add(0, n, .string)
                    return
                }
            }

            if language == .yaml { yamlKey() }
            if language == .c || language == .shell, i == 0 { preprocessor() }

            while i < n {
                let c = chars[i]
                if let lineComment, starts(lineComment, at: i), lineCommentAllowed(at: i) {
                    add(i, n, .comment)
                    i = n
                    break
                }
                if hasBlockComment, starts("/*", at: i) {
                    if let end = find("*/", from: i + 2) {
                        add(i, end + 2, .comment)
                        i = end + 2
                    } else {
                        add(i, n, .comment)
                        state = .blockComment
                        i = n
                    }
                    continue
                }
                if c == "\"" || c == "'" || c == "`" {
                    string(quote: c)
                    continue
                }
                if language == .css, c == "#", i + 1 < n, chars[i + 1].isHexDigit {
                    var j = i + 1
                    while j < n, chars[j].isHexDigit { j += 1 }
                    add(i, j, .number)
                    i = j
                    continue
                }
                if language == .shell, c == "$" {
                    var j = i + 1
                    if j < n, chars[j] == "{" {
                        while j < n, chars[j] != "}" { j += 1 }
                        j = min(n, j + 1)
                    } else {
                        while j < n, Self.isIdentPart(chars[j]) || chars[j] == "?" || chars[j] == "@" { j += 1 }
                    }
                    add(i, max(j, i + 1), .property)
                    i = max(j, i + 1)
                    continue
                }
                if c.isNumber, previousIsBoundary(i) || language == .css {
                    var j = i
                    while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j] == "%" {
                        if chars[j] == ".", j + 1 < n, !chars[j + 1].isNumber { break }
                        j += 1
                    }
                    add(i, j, .number)
                    i = j
                    continue
                }
                if Self.isIdentStart(c) || (c == "@" && language != .json && i + 1 < n && chars[i + 1].isLetter)
                    || (c == "-" && language == .css && i + 1 < n && chars[i + 1].isLetter) {
                    identifier()
                    continue
                }
                add(i, i + 1, .plain)
                i += 1
            }
        }

        func previousIsBoundary(_ index: Int) -> Bool {
            guard index > 0 else { return true }
            let p = chars[index - 1]
            return !(Self.isIdentPart(p))
        }

        /// A `#` comment begins a word (shell, YAML), never `$#` or a colour; `//` is always one.
        func lineCommentAllowed(at index: Int) -> Bool {
            guard lineComment == "#" else { return true }
            return index == 0 || chars[index - 1].isWhitespace
        }

        mutating func string(quote: Character) {
            let start = i
            if triple, quote != "`", starts(String(repeating: quote, count: 3), at: i) {
                let token = String(repeating: quote, count: 3)
                if let end = find(token, from: i + 3) {
                    add(start, end + 3, .string)
                    i = end + 3
                } else {
                    add(start, n, .string)
                    state = .tripleString(quote)
                    i = n
                }
                return
            }
            var j = i + 1
            while j < n {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == quote { j += 1; break }
                j += 1
            }
            j = min(j, n)
            // JSON / YAML: a string followed by ":" is a key.
            var kind = OCSyntaxKind.string
            if language == .json || language == .yaml {
                var k = j
                while k < n, chars[k] == " " { k += 1 }
                if k < n, chars[k] == ":" { kind = .property }
            }
            // A lone apostrophe in prose-like text (shell, CSS) must not swallow the line.
            if quote == "'" && language == .c && j - start > 3 && chars[j - 1] != "'" {
                add(start, start + 1, .plain)
                i = start + 1
                return
            }
            add(start, j, kind)
            i = j
        }

        mutating func identifier() {
            let start = i
            var j = i + 1
            while j < n, Self.isIdentPart(chars[j]) || (language == .css && chars[j] == "-") { j += 1 }
            let word = text(start, j)
            let plainWord = word.hasPrefix("@") ? String(word.dropFirst()) : word
            var kind = OCSyntaxKind.plain
            var k = j
            while k < n, chars[k] == " " { k += 1 }
            let next: Character? = k < n ? chars[k] : nil

            if word.hasPrefix("@"), language == .swift || language == .script || language == .c || language == .python {
                kind = language == .swift ? .keyword : .function
            } else if language == .css {
                if word.hasPrefix("@") { kind = .keyword }
                else if next == ":", k + 1 < n, chars[k + 1] == " " || chars[k + 1] == "\n" { kind = .property }
            } else if keywords.contains(plainWord) {
                kind = .keyword
            } else if next == "(", language != .json {
                kind = .function
            } else if capitalizedAreTypes, let first = plainWord.first, first.isUppercase,
                      plainWord.contains(where: { $0.isLowercase }) {
                kind = .type
            }
            add(start, j, kind)
            i = j
        }

        /// `#include` / `#!/bin/sh` style lines.
        mutating func preprocessor() {
            var k = 0
            while k < n, chars[k] == " " || chars[k] == "\t" { k += 1 }
            guard k < n, chars[k] == "#" else { return }
            if language == .shell {
                if starts("#!", at: k) {
                    add(0, n, .comment)
                    i = n
                }
                return
            }
            var j = k + 1
            while j < n, chars[j].isLetter { j += 1 }
            add(0, j, .keyword)
            i = j
        }

        /// `key:` at the start of a YAML line (optionally after `- `).
        mutating func yamlKey() {
            var k = 0
            while k < n, chars[k] == " " { k += 1 }
            if k + 1 < n, chars[k] == "-", chars[k + 1] == " " {
                k += 2
                while k < n, chars[k] == " " { k += 1 }
            }
            let start = k
            guard k < n, chars[k] != "\"", chars[k] != "'", chars[k] != "#" else { return }
            while k < n, chars[k] != ":", chars[k] != "#" { k += 1 }
            guard k < n, chars[k] == ":", k == n - 1 || chars[k + 1] == " " else { return }
            // Everything up to the colon, trimmed on the right.
            var end = k
            while end > start, chars[end - 1] == " " { end -= 1 }
            guard end > start else { return }
            add(0, start, .plain)
            add(start, end, .property)
            i = end
        }

        // MARK: Markdown

        mutating func markdown() {
            let trimmed = text(0, n).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                state = state == .fence ? .none : .fence
                add(0, n, .comment)
                return
            }
            if state == .fence {
                add(0, n, .string)
                return
            }
            if trimmed.hasPrefix("#") {
                add(0, n, .keyword)
                return
            }
            if trimmed.hasPrefix(">") {
                add(0, n, .comment)
                return
            }
            var k = 0
            while k < n, chars[k] == " " { k += 1 }
            // List markers.
            if k + 1 < n, "-*+".contains(chars[k]), chars[k + 1] == " " {
                add(0, k + 1, .keyword)
                i = k + 1
            } else {
                var d = k
                while d < n, chars[d].isNumber { d += 1 }
                if d > k, d + 1 < n, chars[d] == ".", chars[d + 1] == " " {
                    add(0, d + 1, .keyword)
                    i = d + 1
                }
            }
            while i < n {
                let c = chars[i]
                if c == "`", let end = find("`", from: i + 1) {
                    add(i, end + 1, .string)
                    i = end + 1
                } else if c == "[", let close = find("](", from: i + 1), let end = find(")", from: close) {
                    add(i, close + 1, .function)
                    add(close + 1, end + 1, .comment)
                    i = end + 1
                } else if c == "*" || c == "_", i + 1 < n, chars[i + 1] == c, let end = find(String([c, c]), from: i + 2) {
                    add(i, end + 2, .type)
                    i = end + 2
                } else {
                    add(i, i + 1, .plain)
                    i += 1
                }
            }
        }

        // MARK: HTML / XML

        mutating func html() {
            if state == .htmlComment {
                if let end = find("-->", from: 0) {
                    add(0, end + 3, .comment)
                    i = end + 3
                    state = .none
                } else {
                    add(0, n, .comment)
                    return
                }
            }
            while i < n {
                let c = chars[i]
                if starts("<!--", at: i) {
                    if let end = find("-->", from: i + 4) {
                        add(i, end + 3, .comment)
                        i = end + 3
                    } else {
                        add(i, n, .comment)
                        state = .htmlComment
                        i = n
                    }
                } else if c == "<", i + 1 < n, chars[i + 1].isLetter || chars[i + 1] == "/" || chars[i + 1] == "!" || chars[i + 1] == "?" {
                    var j = i + 1
                    while j < n, chars[j].isLetter || chars[j].isNumber || "/!?-:_.".contains(chars[j]) { j += 1 }
                    add(i, j, .tag)
                    i = j
                    tagBody()
                } else {
                    add(i, i + 1, .plain)
                    i += 1
                }
            }
        }

        /// Attributes and the closing `>` of a tag (the tag may continue on the next line: that is
        /// left plain, which is fine for diffs).
        mutating func tagBody() {
            while i < n {
                let c = chars[i]
                if c == ">" {
                    add(i, i + 1, .tag)
                    i += 1
                    return
                }
                if c == "/", i + 1 < n, chars[i + 1] == ">" {
                    add(i, i + 2, .tag)
                    i += 2
                    return
                }
                if c == "\"" || c == "'" {
                    var j = i + 1
                    while j < n, chars[j] != c { j += 1 }
                    j = min(n, j + 1)
                    add(i, j, .string)
                    i = j
                } else if c.isLetter {
                    var j = i
                    while j < n, chars[j].isLetter || chars[j].isNumber || "-:_@.".contains(chars[j]) { j += 1 }
                    add(i, j, .property)
                    i = j
                } else {
                    add(i, i + 1, .plain)
                    i += 1
                }
            }
        }
    }
}

extension OCSyntaxHighlighter {
    /// Highlights a unified diff's lines. Added and context lines form the new file, removed and
    /// context lines the old one; each stream is scanned in order so multi-line constructs carry.
    nonisolated static func highlight(diffLines: [(text: String, isRemoved: Bool, isAdded: Bool)], language: OCSyntaxLanguage) -> [[OCSyntaxSegment]] {
        guard language != .plain else { return diffLines.map { [OCSyntaxSegment(text: $0.text, kind: .plain)] } }
        var result = [[OCSyntaxSegment]](repeating: [], count: diffLines.count)
        var newState = State.none
        var oldState = State.none
        for (index, line) in diffLines.enumerated() {
            if index % 200 == 0, Task.isCancelled {
                for rest in index..<diffLines.count { result[rest] = [OCSyntaxSegment(text: diffLines[rest].text, kind: .plain)] }
                break
            }
            if line.isRemoved {
                let (segments, next) = highlight(line: line.text, language: language, state: oldState)
                result[index] = segments
                oldState = next
            } else {
                let (segments, next) = highlight(line: line.text, language: language, state: newState)
                result[index] = segments
                newState = next
                if !line.isAdded { oldState = next }
            }
        }
        return result
    }
}
