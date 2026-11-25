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
    @AppStorage(OCDiffSettings.wrapKey) private var wraps = true
    @State private var availability: OCChangesAvailability?
    @State private var mode: OCChangesMode?
    @State private var state: LoadState = .loading
    @State private var expanded: Set<String> = []
    @State private var reloadToken = 0
    /// The web's select popover, as a small panel under the header.
    @State private var showsModes = false
    /// "Create Git repository" in the no-git state: running, and the failure to show.
    @State private var creatingGit = false
    @State private var gitError: String?
    /// The selected diff lines, and the comment being written for them.
    @State private var selection: OCDiffSelection?
    @State private var draft = ""
    private let comments = OCDiffCommentStore.shared

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
                            selection = nil
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
                Rectangle().fill(Color.appSeparator).frame(height: 1)
                // The web keeps "Wrap lines" in Settings; on the phone it sits with the diff's other choices.
                Button {
                    wraps.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(wraps ? 1 : 0)
                        Text(AppText.ocWrapLines).font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.appPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("oc.changes.wrap")
                .accessibilityLabel(AppText.ocWrapLines)
                .accessibilityValue(wraps ? "on" : "off")
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
                OCGuardedDiff(
                    file: file,
                    selection: $selection,
                    commentedLines: comments.comments(sessionID: session.id, file: commentPath(file)).map { $0.startLine...$0.endLine }
                )
                commentArea(for: file)
            }
        }
    }

    /// The path a comment carries: relative to the session folder, like the web's file paths.
    private func commentPath(_ file: ReviewFileChange) -> String {
        OCFileSupport.relative(file.path, to: session.directory)
    }

    // MARK: Line comments

    @ViewBuilder
    private func commentArea(for file: ReviewFileChange) -> some View {
        let path = commentPath(file)
        let saved = comments.comments(sessionID: session.id, file: path)
        let editing = selection?.file == file.path
        VStack(alignment: .leading, spacing: 8) {
            ForEach(saved) { comment in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(comment.text)
                            .font(.system(size: 14)).foregroundStyle(Color.appPrimary)
                        Text(AppText.ocLineCommentSaved(start: comment.startLine, end: comment.endLine))
                            .font(.system(size: 12)).foregroundStyle(Color.appSecondary)
                    }
                    Spacer(minLength: 0)
                    Button { comments.remove(comment.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("oc.changes.comment.remove")
                    .accessibilityLabel(AppText.ocLineCommentRemove)
                }
                .padding(10)
                .background(Color.appTertiary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.appSeparator, lineWidth: 1))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("oc.changes.comment")
            }
            // The web opens the editor as soon as lines are selected.
            if editing, let current = selection {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(AppText.ocLineCommentPlaceholder, text: $draft, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(2...6)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.appAccent, lineWidth: 1))
                        .accessibilityIdentifier("oc.changes.comment.field")
                    Text(AppText.ocLineCommentEditing(start: current.startLine, end: current.endLine))
                        .font(.system(size: 12)).foregroundStyle(Color.appSecondary)
                    HStack(spacing: 8) {
                        Button { selection = nil; draft = "" } label: {
                            Text(AppText.ocLineCommentCancel)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.appPrimary)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.appSeparator, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("oc.changes.comment.cancel")
                        let canSubmit = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button {
                            if comments.add(sessionID: session.id, file: path, selection: current, text: draft) != nil {
                                draft = ""
                                selection = nil
                            }
                        } label: {
                            Text(AppText.ocLineCommentSubmit)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(canSubmit ? Color.appBackground : Color.appSecondary)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(canSubmit ? Color.appPrimary : Color.appTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("oc.changes.comment.submit")
                    }
                }
                .padding(12)
                .background(Color.appTertiary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.appSeparator, lineWidth: 1))
            }
        }
        .padding(.horizontal, saved.isEmpty && !editing ? 0 : 16)
        .padding(.vertical, saved.isEmpty && !editing ? 0 : 10)
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
                Button {
                    Task { await createGit() }
                } label: {
                    HStack(spacing: 6) {
                        if creatingGit { ProgressView().controlSize(.small) }
                        Text(creatingGit ? AppText.ocCreatingGit : AppText.ocCreateGit)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color.appPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(creatingGit)
                .accessibilityIdentifier("oc.changes.createGit")
                if let gitError {
                    Text(gitError)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appDanger)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("oc.changes.createGit.error")
                }
            }
            // A marker, not an identifier on the stack (that one would replace the button's).
            .overlay(alignment: .topLeading) {
                Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.placeholder")
            }
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

    // MARK: Create Git repository

    /// The web's "Create a Git repository": one request for the session's folder; a second tap
    /// while it runs does nothing. On success the tab starts over and reads the repository.
    private func createGit() async {
        guard !creatingGit else { return }
        creatingGit = true
        gitError = nil
        // Stays busy until the reload after the init has settled (`load` clears it).
        do {
            try await reviewService.initGitRepository(directory: availability?.directory ?? session.directory)
            availability = nil
            mode = nil
            expanded = []
            state = .loading
            reloadToken += 1
        } catch {
            creatingGit = false
            guard !(error is CancellationError) else { return }
            gitError = OCGitInitMessage.text(for: error)
        }
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
                    creatingGit = false
                    // A request started before this tab was re-mounted is still running: join it.
                    if reviewService.isInitializingGit(directory: found.directory ?? session.directory) {
                        Task { await createGit() }
                    }
                    return
                }
                creatingGit = false
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
            let files = try await reviewService.loadChanges(sessionID: session.id, mode: mode, directory: availability?.directory)
            guard !Task.isCancelled else { return }
            state = .loaded(files)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            creatingGit = false
            state = .failed(error.localizedDescription)
        }
    }
}
