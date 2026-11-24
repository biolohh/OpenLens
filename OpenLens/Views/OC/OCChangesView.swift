import SwiftUI

/// The web's mobile Changes tab: a mode select, the total +/-, "Expand all", then one row per
/// changed file that opens to its unified diff. Data: the working tree or the newest turn
/// (`GET /api/session/{id}/diff`) through `ReviewService`.
struct OCChangesView: View {
    private enum LoadState {
        case loading
        case noGit
        case failed(String)
        case loaded([ReviewFileChange])
    }

    let session: OCSession
    /// Bumps when the session timeline changes; the open tab reloads (debounced).
    var refreshKey: UInt = 0
    /// "Open file": jumps to the Files tab with that path open.
    let openFile: (String) -> Void

    @Environment(\.reviewService) private var reviewService
    @Environment(\.colorScheme) private var colorScheme
    @State private var availability: OCChangesAvailability?
    @State private var mode: OCChangesMode?
    @State private var state: LoadState = .loading
    @State private var expanded: Set<String> = []
    @State private var reloadToken = 0
    /// The web's select popover, as a small panel under the header.
    @State private var showsModes = false

    private struct LoadKey: Hashable {
        let sessionID: String
        let mode: OCChangesMode?
        let reload: Int
        let refresh: UInt
    }

    var body: some View {
        VStack(spacing: 0) {
            switch state {
            case .loading:
                centered { Text(AppText.ocChangesLoading).font(.system(size: 14)).foregroundStyle(Color.appSecondary) }
            case .noGit:
                noGit
            case .failed(let message):
                failure(message)
            case .loaded(let files):
                header(files)
                if files.isEmpty {
                    centered {
                        Text((mode ?? .turn).emptyText)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appSecondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("oc.changes.empty")
                    }
                } else {
                    list(files)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) { modePanel }
        // A marker, not an identifier on the container (that one would replace the children's).
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.changes")
        }
        .task(id: LoadKey(sessionID: session.id, mode: mode, reload: reloadToken, refresh: refreshKey)) { await load() }
    }

    // MARK: Header

    private func header(_ files: [ReviewFileChange]) -> some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        let allOpen = !files.isEmpty && files.allSatisfy { expanded.contains($0.path) }
        return HStack(spacing: 12) {
            modeControl
            if !files.isEmpty {
                OCDiffCounts(additions: additions, deletions: deletions)
            }
            Spacer(minLength: 0)
            if !files.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        expanded = allOpen ? [] : Set(files.map(\.path))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text(allOpen ? AppText.ocChangesCollapseAll : AppText.ocChangesExpandAll)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color.appPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("oc.changes.expandAll")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.appSeparator).frame(height: 1) }
    }

    @ViewBuilder
    private var modeControl: some View {
        let current = mode ?? .turn
        let modes = availability?.modes ?? []
        if modes.count > 1 {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showsModes.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(current.title).font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                }
                .foregroundStyle(Color.appPrimary)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.changes.mode")
        } else {
            Text(current.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .accessibilityIdentifier("oc.changes.mode")
        }
    }

    @ViewBuilder
    private var modePanel: some View {
        if showsModes, let modes = availability?.modes, modes.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(modes, id: \.self) { option in
                    Button {
                        showsModes = false
                        if option != mode {
                            expanded = []
                            state = .loading
                            mode = option
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .opacity(option == mode ? 1 : 0)
                            Text(option.title).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Color.appPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("oc.changes.mode.\(option.rawValue)")
                }
            }
            .frame(width: 220)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.appSeparator, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.leading, 12)
            .padding(.top, 44)
            .transition(.opacity)
        }
    }

    // MARK: Files

    private func list(_ files: [ReviewFileChange]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    fileRow(file)
                    Rectangle().fill(Color.appSeparator).frame(height: 1)
                }
            }
        }
        .accessibilityIdentifier("oc.changes.list")
    }

    private func fileRow(_ file: ReviewFileChange) -> some View {
        let open = expanded.contains(file.path)
        let parts = OCFileSupport.split(path: file.path)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    if open { expanded.remove(file.path) } else { expanded.insert(file.path) }
                }
            } label: {
                HStack(spacing: 8) {
                    OCFileTypeIcon(name: parts.name)
                    OCPathLabel(path: file.path)
                    Spacer(minLength: 8)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.changes.file")
            .accessibilityLabel(file.path)
            .accessibilityValue("+\(file.additions) -\(file.deletions), \(open ? "expanded" : "collapsed")")

            if open {
                HStack(spacing: 8) {
                    Text(OCFileSupport.statusLabel(file.status))
                        .font(.system(size: 13))
                        .foregroundStyle(statusColor(file.status))
                    OCDiffCounts(additions: file.additions, deletions: file.deletions)
                    Spacer(minLength: 0)
                    if file.status.uppercased() != "D" {
                        Button {
                            openFile(OCFileSupport.relative(file.path, to: session.directory))
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.forward.square").font(.system(size: 12))
                                Text(AppText.ocOpenFile).font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(Color.appPrimary)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("oc.changes.openFile")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(colorScheme == .dark ? Color.appBackground : Color.appTertiary.opacity(0.5))
                OCGuardedDiff(file: file)
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "A": Color.appSuccess
        case "D": Color.appDanger
        default: Color.appSecondary
        }
    }

    // MARK: Empty and failure states

    private var noGit: some View {
        centered {
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.appSecondary)
                Text(AppText.ocNoChangesTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                Text(AppText.ocNoChangesSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityIdentifier("oc.placeholder")
        }
    }

    private func failure(_ message: String) -> some View {
        centered {
            VStack(spacing: 10) {
                Text(AppText.ocChangesFailed)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
                Button(AppText.tryAgain) {
                    state = .loading
                    reloadToken += 1
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("oc.changes.retry")
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loading

    private func load() async {
        do {
            if availability == nil {
                let found = try await reviewService.changesAvailability(
                    sessionID: session.id, directory: session.directory, projectID: session.projectID
                )
                guard !Task.isCancelled else { return }
                availability = found
                guard found.isGit, let first = found.modes.first else {
                    state = .noGit
                    return
                }
                // Setting the mode re-keys the task, which then loads the files.
                mode = first
                return
            }
            guard let mode else { return }
            // A reload caused by timeline changes waits for the burst to settle and keeps the list.
            if case .loaded = state {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
            }
            let files = try await reviewService.loadChanges(sessionID: session.id, mode: mode)
            guard !Task.isCancelled else { return }
            state = .loaded(files)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
