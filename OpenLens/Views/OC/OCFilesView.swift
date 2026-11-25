import AVFoundation
import SwiftUI

/// The web's Files view (More... > Files): a row with "All files" and the open file tabs, then
/// either the project's expandable file tree with a filter field, or the open file as
/// line-numbered monospace text (read only). Browsing and reading go through `WorkspaceService`.
struct OCFilesView: View {
    let directory: String?
    @Binding var openPaths: [String]
    /// The shown file; nil = the "All files" tree.
    @Binding var activePath: String?

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            if let activePath, openPaths.contains(activePath) {
                OCFileTextView(directory: directory, path: activePath)
                    .id(activePath)
            } else {
                OCFileTree(directory: directory, openPaths: openPaths) { path in
                    if !openPaths.contains(path) { openPaths.append(path) }
                    activePath = path
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A marker, not an identifier on the container (that one would replace the children's).
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.files")
        }
        // Open tabs outlive the view for the rest of the app run (per session folder).
        .onAppear {
            if openPaths.isEmpty, let remembered = OCSessionMemory.shared.files(directory: directory) {
                openPaths = remembered.openPaths
                activePath = remembered.activePath
            }
        }
        .onChange(of: openPaths) { _, _ in
            OCSessionMemory.shared.setFiles(OCFilesMemory(openPaths: openPaths, activePath: activePath), directory: directory)
        }
        .onChange(of: activePath) { _, _ in
            OCSessionMemory.shared.setFiles(OCFilesMemory(openPaths: openPaths, activePath: activePath), directory: directory)
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tab(AppText.ocFilesAll, selected: activePath == nil, id: "oc.files.all") { activePath = nil }
                ForEach(openPaths, id: \.self) { path in
                    HStack(spacing: 8) {
                        tab(OCFileSupport.split(path: path).name, selected: activePath == path, id: "oc.files.tab") {
                            activePath = path
                        }
                        Button {
                            openPaths.removeAll { $0 == path }
                            if activePath == path { activePath = nil }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.appSecondary)
                                .frame(width: 20, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("oc.files.close")
                        .accessibilityLabel(AppText.ocFileCloseTab)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(activePath == path ? Color.appPrimary : .clear).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.appSeparator).frame(height: 1) }
    }

    private func tab(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.appPrimary : Color.appSecondary)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Expandable tree of the session's folder; children load when a folder is first opened.
private struct OCFileTree: View {
    let directory: String?
    /// Files already open as tabs; their rows carry the web's grey highlight.
    let openPaths: [String]
    let onOpen: (String) -> Void

    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.connection) private var connection
    @State private var children: [String: [RepositoryEntry]] = [:]
    /// Folders whose listing failed: shown as a retry row, never cached as empty.
    @State private var failedFolders: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var failed: String?
    @State private var loadingRoot = true
    @State private var filter = ""
    @State private var results: [RepositoryEntry]?

    /// Name search exists on v2 servers only.
    private var supportsFilter: Bool { connection.serverCapabilities?.protocolVersion == .v2 }

    private var rootName: String {
        let name = ((directory ?? "") as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(rootName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            if supportsFilter { filterField }
            content
        }
        .task(id: directory) { await loadRoot() }
        .task(id: filter) { await runFilter() }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.appSecondary)
            TextField(AppText.ocFilesFilter, text: $filter)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("oc.files.filter")
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.appSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let failed {
            VStack(spacing: 8) {
                Text(failed).font(.system(size: 13)).foregroundStyle(Color.appSecondary).multilineTextAlignment(.center)
                Button(AppText.tryAgain) { Task { await loadRoot() } }.buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if supportsFilter, !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results == nil {
                        ProgressView().tint(Color.appSecondary).frame(maxWidth: .infinity, minHeight: 48)
                            .accessibilityIdentifier("oc.files.searching")
                    }
                    if let results, results.isEmpty {
                        Text(AppText.ocFilesNoResults)
                            .font(.system(size: 13)).foregroundStyle(Color.appSecondary)
                            .padding(16)
                    }
                    ForEach(results ?? []) { entry in
                        row(entry, depth: 0, showsPath: true)
                    }
                }
            }
        } else if loadingRoot {
            ProgressView().tint(Color.appSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows(of: "", depth: 0), id: \.entry.id) { item in
                        row(item.entry, depth: item.depth, showsPath: false)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func visibleRows(of parent: String, depth: Int) -> [(entry: RepositoryEntry, depth: Int)] {
        (children[parent] ?? []).flatMap { entry -> [(entry: RepositoryEntry, depth: Int)] in
            var rows = [(entry: entry, depth: depth)]
            if entry.isDirectory, expanded.contains(entry.path) {
                if failedFolders.contains(entry.path) {
                    rows.append((entry: Self.failureRow(for: entry.path), depth: depth + 1))
                }
                rows += visibleRows(of: entry.path, depth: depth + 1)
            }
            return rows
        }
    }

    private static let failureMarker = "\u{0}failed:"

    private static func failureRow(for folder: String) -> RepositoryEntry {
        RepositoryEntry(path: failureMarker + folder, name: AppText.ocFolderLoadFailed, isDirectory: false)
    }

    private func row(_ entry: RepositoryEntry, depth: Int, showsPath: Bool) -> some View {
        if entry.path.hasPrefix(Self.failureMarker) {
            return AnyView(failureRowView(entry, depth: depth))
        }
        let open = expanded.contains(entry.path)
        return AnyView(Button {
            if entry.isDirectory {
                if open {
                    expanded.remove(entry.path)
                } else {
                    expanded.insert(entry.path)
                    Task { await loadChildren(of: entry.path) }
                }
            } else {
                onOpen(entry.path)
            }
        } label: {
            HStack(spacing: 8) {
                if entry.isDirectory {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                        .frame(width: 16)
                } else {
                    OCFileTypeIcon(name: entry.name)
                }
                if showsPath {
                    OCPathLabel(path: entry.path)
                } else {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(entry.isDirectory ? Color.appSecondary : Color.appPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8 + CGFloat(depth) * 16)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(
                openPaths.contains(entry.path) ? Color.appTertiary : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.files.row")
        .accessibilityLabel(entry.path)
        .accessibilityValue(entry.isDirectory ? (open ? "expanded" : "collapsed") : ""))
    }

    private func failureRowView(_ entry: RepositoryEntry, depth: Int) -> some View {
        let folder = String(entry.path.dropFirst(Self.failureMarker.count))
        return Button {
            Task { await loadChildren(of: folder) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Color.appDanger)
                Text("\(AppText.ocFolderLoadFailed) · \(AppText.tryAgain)")
                    .font(.system(size: 13)).foregroundStyle(Color.appSecondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8 + CGFloat(depth) * 16)
            .frame(height: 28)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.files.retry")
    }

    private func loadRoot() async {
        guard let directory else {
            failed = AppText.ocFolderMissing
            loadingRoot = false
            return
        }
        failed = nil
        loadingRoot = true
        do {
            children[""] = try await workspaceService.loadRepositoryEntries(at: "", in: directory, includesHidden: true)
        } catch {
            guard !(error is CancellationError) else { return }
            failed = error.localizedDescription
        }
        loadingRoot = false
    }

    private func loadChildren(of path: String) async {
        guard let directory, children[path] == nil else { return }
        do {
            children[path] = try await workspaceService.loadRepositoryEntries(at: path, in: directory, includesHidden: true)
            failedFolders.remove(path)
        } catch {
            guard !(error is CancellationError) else { return }
            failedFolders.insert(path)
        }
    }

    /// Server-side name search (debounced), the web's "Filter files".
    private func runFilter() async {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let directory else {
            results = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        results = (try? await workspaceService.searchRepositoryFiles(matching: query, in: directory, includesHidden: true)) ?? []
    }
}

/// One file in the Files view: coloured, line-numbered monospace text (read only); Markdown opens
/// as the rendered document with the web's source / preview switch; images show inline, audio
/// gets a play control; anything else reads "Binary file".
private struct OCFileTextView: View {
    private enum LoadState {
        case loading
        case text(lines: [AttributedString], markdown: String?)
        case image(UIImage)
        case audio(URL)
        case binary
        case failed(String)
    }

    private static let maximumLines = 5000

    let directory: String?
    let path: String

    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.reviewService) private var reviewService
    @State private var state: LoadState = .loading
    /// Markdown starts as the rendered preview, like the web.
    @State private var showsSource = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().tint(Color.appSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                centeredText(message)
            case .binary:
                centeredText(AppText.ocBinaryFile).accessibilityIdentifier("oc.file.binary")
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding(16)
                }
                .overlay(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.file.image")
                }
            case .audio(let url):
                OCAudioPreview(url: url)
            case .text(let lines, let markdown):
                VStack(spacing: 0) {
                    if markdown != nil { markdownHeader }
                    if let markdown, !showsSource {
                        ScrollView {
                            DeferredMarkdownTextView(text: markdown, foregroundColor: Color.appPrimary, usesRetroTypography: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                        .overlay(alignment: .topLeading) {
                            Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.file.markdown")
                        }
                    } else {
                        source(lines)
                    }
                }
            }
        }
        .task(id: path) { await load() }
    }

    private func centeredText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.appSecondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var markdownHeader: some View {
        HStack(spacing: 8) {
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { showsSource.toggle() } label: {
                Image(systemName: showsSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.file.toggle")
            .accessibilityLabel(showsSource ? "Preview" : "Source")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func source(_ lines: [AttributedString]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(index + 1)")
                            .font(.openLensMono(size: 12))
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(lines[index])
                            .font(.openLensMono(size: 12))
                            .foregroundStyle(Color.appPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 12)
                            .padding(.trailing, 8)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 6)
        }
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.file.content")
        }
    }

    private func load() async {
        guard let directory else {
            state = .failed(AppText.ocFolderMissing)
            return
        }
        state = .loading
        showsSource = false
        let kind = OCFileSupport.previewKind(path: path)
        do {
            switch kind {
            case .image, .audio:
                let (data, _) = try await reviewService.readFileData(path: path, directory: directory)
                guard !Task.isCancelled else { return }
                if kind == .image {
                    let image = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
                    guard !Task.isCancelled else { return }
                    state = image.map { .image($0) } ?? .binary
                } else {
                    let ext = (path as NSString).pathExtension
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-audio-\(UUID().uuidString).\(ext)")
                    try data.write(to: url)
                    state = .audio(url)
                }
            case .text, .markdown:
                let text = try await workspaceService.readRepositoryFile(at: path, in: directory)
                guard !Task.isCancelled else { return }
                let maximum = Self.maximumLines
                let language = OCSyntaxLanguage.detect(path: path)
                // Split and tokenised in one pass off the main actor, so block comments and multi-line
                // strings carry across lines.
                let lines = await Task.detached(priority: .userInitiated) {
                    OCSyntaxHighlighter.highlight(
                        lines: OCFileSupport.cappedLines(text, maximumLines: maximum), language: language
                    ).map(OCSyntaxTheme.attributed)
                }.value
                guard !Task.isCancelled else { return }
                state = .text(lines: lines, markdown: kind == .markdown ? text : nil)
            }
        } catch {
            guard !Task.isCancelled else { return }
            if case OpenCodeError.invalidPayload(let reason) = error, reason == AppText.repositoryFileNotText {
                state = .binary
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// A play / pause control for an audio file (the web's audio preview).
private struct OCAudioPreview: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            Button { toggle() } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.appPrimary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.file.audio.play")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Text(failed ? AppText.ocBinaryFile : url.lastPathComponent)
                .font(.system(size: 12)).foregroundStyle(Color.appSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            player?.stop()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func toggle() {
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: url)
            failed = player == nil
        }
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            isPlaying = player.play()
            // Back to the play icon when it ends.
            Task {
                while player.isPlaying { try? await Task.sleep(for: .milliseconds(300)) }
                isPlaying = false
            }
        }
    }
}
