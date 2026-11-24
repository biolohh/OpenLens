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
                OCFileTree(directory: directory) { path in
                    if !openPaths.contains(path) { openPaths.append(path) }
                    activePath = path
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("oc.files")
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
    let onOpen: (String) -> Void

    @Environment(\.workspaceService) private var workspaceService
    @State private var children: [String: [RepositoryEntry]] = [:]
    @State private var expanded: Set<String> = []
    @State private var failed: String?
    @State private var loadingRoot = true
    @State private var filter = ""
    @State private var results: [RepositoryEntry]?

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
            filterField
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
        } else if !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
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
                rows += visibleRows(of: entry.path, depth: depth + 1)
            }
            return rows
        }
    }

    private func row(_ entry: RepositoryEntry, depth: Int, showsPath: Bool) -> some View {
        let open = expanded.contains(entry.path)
        return Button {
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
            .padding(.leading, 12 + CGFloat(depth) * 16)
            .padding(.trailing, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.files.row")
        .accessibilityLabel(entry.path)
        .accessibilityValue(entry.isDirectory ? (open ? "expanded" : "collapsed") : "")
    }

    private func loadRoot() async {
        guard let directory else {
            failed = AppText.ocFileNotText
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
        children[path] = (try? await workspaceService.loadRepositoryEntries(at: path, in: directory, includesHidden: true)) ?? []
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
        results = (try? await workspaceService.searchRepositoryFiles(matching: query, in: directory)) ?? []
    }
}

/// One file as read-only line-numbered monospace text (JetBrains Mono through `openLensMono`).
private struct OCFileTextView: View {
    private enum LoadState {
        case loading
        case text([String])
        case failed(String)
    }

    private static let maximumLines = 5000

    let directory: String?
    let path: String

    @Environment(\.workspaceService) private var workspaceService
    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().tint(Color.appSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let lines):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 0) {
                                Text("\(index + 1)")
                                    .font(.openLensMono(size: 12))
                                    .foregroundStyle(Color.appSecondary)
                                    .frame(width: 44, alignment: .trailing)
                                Text(lines[index].isEmpty ? " " : lines[index])
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
                .accessibilityIdentifier("oc.file.content")
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let directory else {
            state = .failed(AppText.ocFileNotText)
            return
        }
        state = .loading
        do {
            let text = try await workspaceService.readRepositoryFile(at: path, in: directory)
            guard !Task.isCancelled else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            state = .text(Array(lines.prefix(Self.maximumLines)))
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
