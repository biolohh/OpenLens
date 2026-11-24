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

    /// The web home shows at most 64 rows (home/sessions/index.ts HOME_SESSION_LIMIT).
    static let rowLimit = 64

    /// Case- and diacritic-insensitive title match.
    static func matches(_ session: OCSession, query: String) -> Bool {
        session.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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
    @Environment(\.connection) private var connection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var sessions: [OCSession]
    @State private var statuses: [String: OCSessionStatus] = [:]
    /// Bumped on every catalog change so a slower in-flight load cannot overwrite it.
    @State private var generation = 0
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var selectedProjectKey: String?
    @State private var showProjectPicker = false
    @State private var query = ""
    @State private var newSessionRequest: NewSessionRequest?
    @State private var sessionToDelete: OCSession?
    @FocusState private var searchFocused: Bool

    let openCount: Int
    /// True while a chat is pushed on top of the home; reload when it closes.
    let isChatOpen: Bool
    let onSelect: (OCSession) -> Void
    let onDelete: (OCSession) -> Void
    let newSessionModel: @MainActor () async -> OCV2ModelRef?
    let onOpenMenu: () -> Void

    init(
        initialState: SessionsListView.InitialState,
        openCount: Int,
        isChatOpen: Bool,
        onSelect: @escaping (OCSession) -> Void,
        onDelete: @escaping (OCSession) -> Void,
        newSessionModel: @escaping @MainActor () async -> OCV2ModelRef?,
        onOpenMenu: @escaping () -> Void
    ) {
        self.openCount = openCount
        self.isChatOpen = isChatOpen
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

    /// Everything the body needs, computed once per render.
    private struct Model {
        var projects: [ProjectOption]
        var groups: [OCHomeGroup]
        var results: [OCSession]
    }

    private func makeModel() -> Model {
        let roots = sessions.filter { $0.parentID == nil }
        var seen = Set<String>()
        var projects: [ProjectOption] = []
        for s in roots {
            let key = OCHomeGrouping.projectKey(for: s)
            if seen.insert(key).inserted {
                projects.append(ProjectOption(key: key, name: OCHomeGrouping.projectName(for: s)))
            }
        }
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let scoped = selectedProjectKey.map { key in roots.filter { OCHomeGrouping.projectKey(for: $0) == key } } ?? roots
        let ordered = OCHomeGrouping.groups(for: scoped)
        // Row cap: the first 64 rows in group order.
        var budget = OCHomeGrouping.rowLimit
        let capped: [OCHomeGroup] = ordered.compactMap { group in
            guard budget > 0 else { return nil }
            let rows = Array(group.sessions.prefix(budget))
            budget -= rows.count
            return OCHomeGroup(kind: group.kind, title: group.title, sessions: rows)
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = q.isEmpty ? [] : ordered.flatMap(\.sessions).filter { OCHomeGrouping.matches($0, query: q) }
        return Model(projects: projects, groups: capped, results: results)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Page ground and panel from the theme tokens: light = grey page, white panel;
    /// dark = base page, raised panel.
    private var pageBackground: Color { colorScheme == .dark ? Color.appBackground : Color.appTertiary }
    private var panelBackground: Color { colorScheme == .dark ? Color.appSurface : Color.appBackground }
    /// Search field / picker button fill: web #252525 in dark, current surface in light.
    private var fieldBackground: Color { colorScheme == .dark ? Color.appTertiary : Color.appSurface }

    // MARK: Body

    var body: some View {
        let model = makeModel()
        return VStack(spacing: 0) {
            header
            panel(model)
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
                generation &+= 1
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
        // Silent reload + status polling whenever the app is active.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await load(silent: true)
            await pollStatuses()
        }
        .onChange(of: isChatOpen) { _, open in
            if !open { Task { await load(silent: true) } }
        }
        // A project that disappears from the catalog must not leave an empty filtered list.
        .onChange(of: sessions) { _, _ in
            if let key = selectedProjectKey, !makeModel().projects.contains(where: { $0.key == key }) {
                selectedProjectKey = nil
            }
        }
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
                if connection.isReconnecting {
                    Circle()
                        .fill(Color.appWarning)
                        .frame(width: 7, height: 7)
                        .accessibilityIdentifier("oc.reconnecting")
                        .accessibilityLabel(AppText.ocReconnecting)
                }
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

    private func panel(_ model: Model) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                projectButton(model)
                searchField
                content(model)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if showProjectPicker {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showProjectPicker = false }
                projectPopover(model)
                    .padding(.horizontal, 12)
                    .padding(.top, 12 + 40 + 6)
            } else if !trimmedQuery.isEmpty {
                resultsPanel(model)
                    .padding(.horizontal, 12)
                    .padding(.top, 12 + 40 + 8 + 36 + 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appSeparator, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func projectButton(_ model: Model) -> some View {
        Button {
            searchFocused = false
            showProjectPicker.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(selectedProjectName(model))
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
            .background(fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.projectPicker")
        .accessibilityLabel(selectedProjectName(model))
    }

    private func selectedProjectName(_ model: Model) -> String {
        model.projects.first { $0.key == selectedProjectKey }?.name ?? AppText.ocAllProjects
    }

    private func projectPopover(_ model: Model) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            popoverRow(
                icon: "folder", title: AppText.ocAllProjects,
                selected: selectedProjectKey == nil, id: "oc.project.all"
            ) { selectProject(nil) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.projects) { project in
                        popoverRow(
                            monogram: OCHomeGrouping.monogram(project.name), title: project.name,
                            selected: selectedProjectKey == project.key, id: "oc.project.\(project.key)"
                        ) { selectProject(project.key) }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.appSeparator, lineWidth: 1))
        .surfaceShadow()
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
            .background(selected ? Color.appSelection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        .background(fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func resultsPanel(_ model: Model) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppText.ocSessionsResults)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if model.results.isEmpty {
                Text(AppText.ocNoResults)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.results) { session in
                            Button {
                                query = ""
                                searchFocused = false
                                onSelect(session)
                            } label: { OCSessionRow(session: session, isBusy: isBusy(session)) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.appSeparator, lineWidth: 1))
        .surfaceShadow()
    }

    // MARK: List

    @ViewBuilder
    private func content(_ model: Model) -> some View {
        if isLoading && sessions.isEmpty {
            ProgressView().tint(Color.appSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, sessions.isEmpty {
            errorState(loadError)
        } else if model.groups.isEmpty {
            emptyState
        } else {
            list(model.groups)
        }
    }

    private func list(_ groups: [OCHomeGroup]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    groupHeader(group, showsNew: index == 0)
                    ForEach(group.sessions) { session in
                        Button { onSelect(session) } label: {
                            OCSessionRow(session: session, isBusy: isBusy(session))
                        }
                            .buttonStyle(.plain)
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

    private func isBusy(_ session: OCSession) -> Bool {
        let type = statuses[session.id]?.type
        return type == .busy || type == .retry
    }

    /// `silent` keeps the current rows on screen while reloading (appearing again after Settings etc.).
    private func load(silent: Bool) async {
        guard !isLoading else { return }
        generation &+= 1
        let mine = generation
        if !silent || sessions.isEmpty { isLoading = true }
        defer { if mine == generation { isLoading = false } }
        do {
            let result = try await sessionsService.listAllSessions()
            guard !Task.isCancelled, mine == generation else { return }
            let snapshot = await sessionsService.refreshSessionOutcomes(
                in: result, previousStatuses: statuses, openedSessionIDs: [], refreshInactive: true
            )
            guard !Task.isCancelled, mine == generation else { return }
            sessions = sessionsService.applyingConfirmedViewedMarkers(to: snapshot.sessions)
            statuses = snapshot.statuses
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, mine == generation else { return }
            loadError = error.localizedDescription
        }
    }

    /// Poll busy/idle every 2 s (unread attention every 30 s) while the home is active, as the old list did.
    private func pollStatuses() async {
        guard connection.serverCapabilities?.protocolVersion == .v2 || ScreenshotFixtures.isEnabled else { return }
        var lastAttention = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !sessions.isEmpty, !isLoading else { continue }
            let mine = generation
            let snapshot = await sessionsService.refreshSessionOutcomes(
                in: sessions, previousStatuses: statuses, openedSessionIDs: [], refreshInactive: false
            )
            guard !Task.isCancelled, mine == generation else { continue }
            var updated = sessionsService.applyingConfirmedViewedMarkers(to: snapshot.sessions)
            statuses = snapshot.statuses
            if Date().timeIntervalSince(lastAttention) >= 30 {
                lastAttention = Date()
                let refreshed = await sessionsService.refreshUnreadResults(in: updated, statuses: snapshot.statuses)
                guard !Task.isCancelled, mine == generation else { continue }
                updated = sessionsService.applyingConfirmedViewedMarkers(to: refreshed)
            }
            sessions = updated
        }
    }

    private func delete(_ session: OCSession) {
        Task {
            do {
                try await sessionsService.deleteSession(session)
                generation &+= 1
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
            .foregroundStyle(Color.appBackground)
            .frame(width: size, height: size)
            .background(
                Color.appSecondary,
                in: RoundedRectangle(cornerRadius: OpenLensDesignSystem.currentTheme.radius.iconTile, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// 48 pt row: monogram, bold title, grey project name.
struct OCSessionRow: View {
    let session: OCSession
    var isBusy = false

    var body: some View {
        let project = OCHomeGrouping.projectName(for: session)
        let unread = !isBusy && session.hasUnreadResult
        let title = session.title.isEmpty ? AppText.ocNewSession : session.title
        HStack(spacing: 8) {
            OCMonogram(letter: OCHomeGrouping.monogram(project))
                .overlay(alignment: .topTrailing) {
                    if unread {
                        Circle().fill(Color.appAccent).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color.appBackground, lineWidth: 1))
                            .offset(x: 3, y: -3)
                    }
                }
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
            if isBusy {
                ProgressView().controlSize(.small).tint(Color.appSecondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unread ? "\(title), \(project), \(AppText.unreadResultAccessibility)" : "\(title), \(project)")
        .modifier(UnreadIdentifier(sessionID: session.id, unread: unread))
    }
}

/// Keeps the `session.unreadResult.<id>` identifier on unread rows only (an outer
/// identifier would be pushed onto every child, so rows carry no other identifier).
private struct UnreadIdentifier: ViewModifier {
    let sessionID: String
    let unread: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if unread {
            content.accessibilityIdentifier("session.unreadResult.\(sessionID)")
        } else {
            content
        }
    }
}
