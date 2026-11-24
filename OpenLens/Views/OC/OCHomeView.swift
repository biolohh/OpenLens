import SwiftUI

// MARK: - Grouping (pure, unit-testable)

/// Web v2 home groups: local calendar day of `time.updated` -> Today / Yesterday / Older.
/// When only older sessions exist the single group is titled "Recent sessions"
/// (packages/app/src/home/sessions/controller.tsx `groupSessions`).
struct OCHomeGroup: Identifiable, Equatable {
    enum Kind: String { case today, yesterday, older }
    let kind: Kind
    let title: String
    let sessions: [OCSession]
    var id: String { kind.rawValue }
}

enum OCHomeGrouping {
    static func groups(
        for sessions: [OCSession],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [OCHomeGroup] {
        let sorted = sessions.sorted { a, b in
            a.time.updated != b.time.updated ? a.time.updated > b.time.updated : a.id < b.id
        }
        func day(_ s: OCSession) -> Date {
            calendar.startOfDay(for: Date(timeIntervalSince1970: s.time.updated / 1000))
        }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let todays = sorted.filter { day($0) == today }
        let yesterdays = sorted.filter { day($0) == yesterday }
        let olders = sorted.filter { day($0) != today && day($0) != yesterday }
        let olderTitle = todays.isEmpty && yesterdays.isEmpty ? AppText.ocRecentSessions : AppText.ocOlder
        return [
            OCHomeGroup(kind: .today, title: AppText.ocToday, sessions: todays),
            OCHomeGroup(kind: .yesterday, title: AppText.ocYesterday, sessions: yesterdays),
            OCHomeGroup(kind: .older, title: olderTitle, sessions: olders),
        ].filter { !$0.sessions.isEmpty }
    }

    /// Project display name: last path component of the session directory.
    static func projectName(for session: OCSession) -> String {
        let directory = session.directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !directory.isEmpty {
            let last = URL(fileURLWithPath: directory).lastPathComponent
            if !last.isEmpty { return last }
        }
        if let id = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        return AppText.projectFallback
    }

    /// Project identity (directory, else project id) used by the picker filter.
    static func projectKey(for session: OCSession) -> String {
        if let d = session.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return "d:\(d)" }
        if let p = session.projectID, !p.isEmpty { return "p:\(p)" }
        return "unknown"
    }

    static func monogram(_ name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: - Home

/// OpenCode web v2 mobile home: header, project picker, search, day-grouped rows.
struct OCHomeView: View {
    private struct NewSessionRequest: Identifiable { let id = UUID() }

    private struct ProjectOption: Identifiable, Hashable {
        let key: String
        let name: String
        var id: String { key }
    }

    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.colorScheme) private var colorScheme

    @State private var sessions: [OCSession]
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var selectedProjectKey: String?
    @State private var showProjectPicker = false
    @State private var query = ""
    @State private var newSessionRequest: NewSessionRequest?
    @State private var sessionToDelete: OCSession?
    @FocusState private var searchFocused: Bool

    let openCount: Int
    let onSelect: (OCSession) -> Void
    let onDelete: (OCSession) -> Void
    let newSessionModel: @MainActor () async -> OCV2ModelRef?
    let onOpenMenu: () -> Void

    init(
        initialState: SessionsListView.InitialState,
        openCount: Int,
        onSelect: @escaping (OCSession) -> Void,
        onDelete: @escaping (OCSession) -> Void,
        newSessionModel: @escaping @MainActor () async -> OCV2ModelRef?,
        onOpenMenu: @escaping () -> Void
    ) {
        self.openCount = openCount
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.newSessionModel = newSessionModel
        self.onOpenMenu = onOpenMenu
        switch initialState {
        case .loaded(let sessions):
            _sessions = State(initialValue: sessions)
            _loadError = State(initialValue: nil)
        case .error(let message):
            _sessions = State(initialValue: [])
            _loadError = State(initialValue: message)
        }
    }

    // MARK: Derived

    private var rootSessions: [OCSession] { sessions.filter { $0.parentID == nil } }

    private var projects: [ProjectOption] {
        var seen = Set<String>()
        var result: [ProjectOption] = []
        for s in rootSessions {
            let key = OCHomeGrouping.projectKey(for: s)
            if seen.insert(key).inserted {
                result.append(ProjectOption(key: key, name: OCHomeGrouping.projectName(for: s)))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var scopedSessions: [OCSession] {
        guard let key = selectedProjectKey else { return rootSessions }
        return rootSessions.filter { OCHomeGrouping.projectKey(for: $0) == key }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchResults: [OCSession] {
        let q = trimmedQuery
        guard !q.isEmpty else { return [] }
        return OCHomeGrouping.groups(for: scopedSessions).flatMap(\.sessions).filter {
            $0.title.localizedCaseInsensitiveContains(q)
        }
    }

    private var groups: [OCHomeGroup] { OCHomeGrouping.groups(for: scopedSessions) }

    private var selectedProjectName: String {
        projects.first { $0.key == selectedProjectKey }?.name ?? AppText.ocAllProjects
    }

    /// The web page sits on a grey ground with a white bordered panel; dark is near black.
    private var pageBackground: Color { colorScheme == .dark ? .black : Color.appSurface }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            panel
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .background(pageBackground.ignoresSafeArea())
        // A marker element, not an identifier on the container: SwiftUI would push the
        // container's identifier down onto every child and hide their own identifiers.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("oc.home")
        }
        .sheet(item: $newSessionRequest) { _ in
            NewSessionSheet(newSessionModel: newSessionModel) { session in
                sessions.insert(session, at: 0)
                onSelect(session)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
        }
        .confirmationDialog(
            AppText.deleteSession,
            isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }),
            presenting: sessionToDelete
        ) { session in
            Button("\(AppText.delete) \"\(session.title)\"", role: .destructive) { delete(session) }
            Button(AppText.cancel, role: .cancel) {}
        } message: { _ in
            Text(AppText.deleteSessionMessage)
        }
        .task { await load(silent: true) }
    }

    // MARK: Header

    private var header: some View {
        Button(action: onOpenMenu) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(AppText.ocHome)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appSecondary)
                        .accessibilityIdentifier("oc.openCount")
                }
            }
            .foregroundStyle(Color.appPrimary)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.menu")
        .accessibilityLabel(AppText.ocMenuTitle)
    }

    // MARK: Panel

    private var panel: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                projectButton
                searchField
                content
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if showProjectPicker {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showProjectPicker = false }
                projectPopover
                    .padding(.horizontal, 12)
                    .padding(.top, 12 + 40 + 6)
            } else if !trimmedQuery.isEmpty {
                resultsPanel
                    .padding(.horizontal, 12)
                    .padding(.top, 12 + 40 + 8 + 36 + 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appSeparator, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var projectButton: some View {
        Button {
            searchFocused = false
            showProjectPicker.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(selectedProjectName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
            }
            .foregroundStyle(Color.appPrimary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.projectPicker")
        .accessibilityLabel(selectedProjectName)
    }

    private var projectPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            popoverRow(
                icon: "folder", title: AppText.ocAllProjects,
                selected: selectedProjectKey == nil, id: "oc.project.all"
            ) { selectProject(nil) }
            ForEach(projects) { project in
                popoverRow(
                    monogram: OCHomeGrouping.monogram(project.name), title: project.name,
                    selected: selectedProjectKey == project.key, id: "oc.project.\(project.name)"
                ) { selectProject(project.key) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.appSeparator, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func popoverRow(
        icon: String? = nil, monogram: String? = nil, title: String,
        selected: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13)).frame(width: 16)
                } else if let monogram {
                    OCMonogram(letter: monogram)
                }
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.appPrimary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? Color.appTertiary : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func selectProject(_ key: String?) {
        selectedProjectKey = key
        showProjectPicker = false
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
            TextField(AppText.ocSearchSessions, text: $query)
                .font(.system(size: 13))
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("oc.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppText.dismiss)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppText.ocSessionsResults)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if searchResults.isEmpty {
                Text(AppText.ocNoResults)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchResults) { session in
                            Button {
                                query = ""
                                searchFocused = false
                                onSelect(session)
                            } label: { OCSessionRow(session: session) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("oc.result.\(session.id)")
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.appSeparator, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if isLoading && sessions.isEmpty {
            ProgressView().tint(Color.appSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, sessions.isEmpty {
            errorState(loadError)
        } else if groups.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    groupHeader(group, showsNew: index == 0)
                    ForEach(group.sessions) { session in
                        Button { onSelect(session) } label: { OCSessionRow(session: session) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("oc.row.\(session.id)")
                            .contextMenu {
                                Button(role: .destructive) { sessionToDelete = session } label: {
                                    Label(AppText.delete, systemImage: "trash")
                                }
                            }
                    }
                    Spacer().frame(height: index == groups.count - 1 ? 8 : 24)
                }
            }
            .padding(.top, 4)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await load(silent: false) }
    }

    private func groupHeader(_ group: OCHomeGroup, showsNew: Bool) -> some View {
        HStack {
            Text(group.title)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
            Spacer()
            if showsNew { newSessionButton }
        }
        .frame(height: 28)
        .padding(.horizontal, 6)
    }

    private var newSessionButton: some View {
        Button { newSessionRequest = NewSessionRequest() } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
                Text(AppText.ocNewSession).font(.system(size: 13))
            }
            .foregroundStyle(Color.appSecondary)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.newSession")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text(AppText.emptySessionsTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
            Text(AppText.emptySessionsSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .multilineTextAlignment(.center)
            newSessionButton
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label(AppText.sessionsLoadErrorTitle, systemImage: "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .multilineTextAlignment(.center)
            Button(AppText.tryAgain) { Task { await load(silent: false) } }
                .buttonStyle(.bordered)
                .tint(Color.appPrimary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Side effects

    /// `silent` keeps the current rows on screen while reloading (appearing again after Settings etc.).
    private func load(silent: Bool) async {
        guard !isLoading else { return }
        if !silent || sessions.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let result = try await sessionsService.listAllSessions()
            guard !Task.isCancelled else { return }
            sessions = sessionsService.applyingConfirmedViewedMarkers(to: result)
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    private func delete(_ session: OCSession) {
        Task {
            do {
                try await sessionsService.deleteSession(session)
                sessions.removeAll { $0.id == session.id }
                onDelete(session)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

// MARK: - Pieces

/// Small rounded-square project monogram (16 pt tile, 4 pt radius, white letter).
struct OCMonogram: View {
    let letter: String
    var size: CGFloat = 16

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.69, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Color(white: 0.36),
                in: RoundedRectangle(cornerRadius: OpenLensDesignSystem.currentTheme.radius.iconTile, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// 48 pt row: monogram, bold title, grey project name.
struct OCSessionRow: View {
    let session: OCSession

    var body: some View {
        let project = OCHomeGrouping.projectName(for: session)
        let title = session.title.isEmpty ? AppText.ocNewSession : session.title
        HStack(spacing: 8) {
            OCMonogram(letter: OCHomeGrouping.monogram(project))
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(1)
                Text(project)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(project)")
    }
}
