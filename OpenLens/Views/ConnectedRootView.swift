import SwiftUI

func shouldHideConnectedRootTabBar(selectedTab: AppTab, chatPath: [RouterDestination]) -> Bool {
    selectedTab == .chat && !chatPath.isEmpty
}

func shouldUseConnectedRootSidebarLayout(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
    horizontalSizeClass == .regular
}

struct ConnectedRootView: View {
    @Bindable var chatClient: ChatClient
    let initialSessions: SessionsListView.InitialState

    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var permissionSheetDetent = PermissionRequestSheet.defaultPresentationDetent
    @State private var showNavigationSheet = false
    /// Sessions opened during this run (the web's open "tabs"); shown in the menu sheet.
    @State private var openedSessions: [OCSession] = []

    var body: some View {
        @Bindable var router = router

        Group {
            if shouldUseConnectedRootSidebarLayout(horizontalSizeClass: horizontalSizeClass) {
                ConnectedSidebarLayout(
                    chatClient: chatClient,
                    initialSessions: initialSessions
                )
            } else {
                compactRoot
            }
        }
        .tint(Color.appPrimary)
        .sheet(item: permissionSheetBinding) { permission in
            PermissionRequestSheet(
                permission: permission,
                selectedDetent: $permissionSheetDetent,
                initiallyConfirmsAllowAll: ScreenshotFixtures.opensPermissionAllowAllConfirmation,
                supportsRejectionMessage: chatClient.supportsPermissionRejectionMessage
            ) { reply, message in
                await chatClient.respondToPermission(requestID: permission.id, reply: reply, message: message)
            }
            .id(permission.id)
            .presentationDetents(
                PermissionRequestSheet.presentationDetents(for: permission),
                selection: $permissionSheetDetent
            )
            .presentationBackground(Color.appBackground)
            .presentationContentInteraction(.resizes)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .onChange(of: chatClient.pendingPermission?.id) { _, _ in
            permissionSheetDetent = PermissionRequestSheet.defaultPresentationDetent
        }
        .task {
            await chatClient.recoverPendingPermission()
        }
        .task(id: chatClient.isLoading) {
            await recoverSessionStateWhileLoading()
        }
    }

    /// iPhone layout: no tab bar. Home (the chat tab root) stays mounted; the other
    /// destinations replace it and are reached from the Home header menu (web "Tabs" sheet).
    private var compactRoot: some View {
        ZStack {
            tabNavigationView(for: .chat)
                .opacity(router.selectedTab == .chat ? 1 : 0)
                .allowsHitTesting(router.selectedTab == .chat)
                .accessibilityHidden(router.selectedTab != .chat)
            if router.selectedTab != .chat {
                tabNavigationView(for: router.selectedTab)
            }
        }
        .sheet(isPresented: $showNavigationSheet) {
            OCNavigationSheet(
                selectedTab: router.selectedTab,
                openedSessions: openedSessions,
                onSelectTab: { tab in
                    showNavigationSheet = false
                    if tab == .chat { router.chatPath = [] }
                    router.selectedTab = tab
                },
                onOpenSession: { session in
                    showNavigationSheet = false
                    router.selectChatSession(session)
                },
                onCloseSession: { session in
                    openedSessions.removeAll { $0.id == session.id }
                    router.clearChatSession(ifMatching: session.id)
                    if openedSessions.isEmpty { showNavigationSheet = false }
                }
            )
        }
    }

    private var permissionSheetBinding: Binding<OCPermissionRequest?> {
        Binding(
            get: {
                chatClient.showPermissionAlert ? chatClient.pendingPermission : nil
            },
            set: { permission in
                chatClient.pendingPermission = permission
                chatClient.showPermissionAlert = permission != nil
            }
        )
    }

    private func recoverSessionStateWhileLoading() async {
        guard chatClient.isLoading else { return }

        while !Task.isCancelled, chatClient.isLoading {
            await chatClient.refreshCurrentSessionStatus()
            await chatClient.recoverPendingPermission()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func tabNavigationView(for tab: AppTab) -> some View {
        NavigationStack(path: pathBinding(for: tab)) {
            tabRootView(for: tab)
                .navigationDestination(for: RouterDestination.self) { destination in
                    ConnectedDestinationView(chatClient: chatClient, destination: destination)
                }
        }
    }

    private func pathBinding(for tab: AppTab) -> Binding<[RouterDestination]> {
        Binding(
            get: { router.path(for: tab) },
            set: { router.setPath($0, for: tab) }
        )
    }

    @ViewBuilder
    private func tabRootView(for tab: AppTab) -> some View {
        switch tab {
        case .chat:
            OCHomeView(
                initialState: initialSessions,
                openCount: openedSessions.count,
                onSelect: selectChatSession,
                onDelete: handleDeletedSession,
                newSessionModel: { await chatClient.newSessionModelPreference() },
                onOpenMenu: { showNavigationSheet = true }
            )
            .toolbar(.hidden, for: .navigationBar)
        case .micro:
            MicroRootView(chatClient: chatClient).toolbar { menuToolbarItem }
        case .review:
            ReviewRootView(chatClient: chatClient).toolbar { menuToolbarItem }
        case .workspace:
            WorkspaceRootView(chatClient: chatClient).toolbar { menuToolbarItem }
        case .settings:
            SettingsView().toolbar { menuToolbarItem }
        }
    }

    private var menuToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showNavigationSheet = true } label: {
                Image(systemName: "square.grid.2x2")
            }
            .accessibilityIdentifier("oc.menu")
            .accessibilityLabel(AppText.ocMenuTitle)
        }
    }

    private func selectChatSession(_ session: OCSession) {
        if !openedSessions.contains(where: { $0.id == session.id }) { openedSessions.append(session) }
        router.selectChatSession(session)
    }

    private func handleDeletedSession(_ session: OCSession) {
        openedSessions.removeAll { $0.id == session.id }
        router.clearChatSession(ifMatching: session.id)
        chatClient.unloadSession(ifMatching: session.id)
    }
}

private struct ConnectedSidebarLayout: View {
    @Bindable var chatClient: ChatClient
    let initialSessions: SessionsListView.InitialState

    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)

            Rectangle()
                .fill(Color.appSeparator)
                .frame(width: 1)
                .ignoresSafeArea()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            Color.appBackground
                .ignoresSafeArea()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ConnectedSidebarNavigation(
                selectedTab: router.selectedTab,
                onSelect: { router.selectedTab = $0 }
            )

            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 1)
                .padding(.horizontal, 12)

            SessionsListView(
                initialState: initialSessions,
                presentationStyle: .sidebar,
                selectedSessionID: router.selectedChatSessionID,
                onSelect: selectChatSession,
                onDelete: handleDeletedSession,
                newSessionModel: { await chatClient.newSessionModelPreference() }
            )
        }
        .background {
            Color.appSurface
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selectedTab {
        case .chat:
            sidebarNavigationStack(for: .chat) {
                ChatDetailPlaceholderView()
            }
        case .micro:
            sidebarNavigationStack(for: .micro) {
                MicroRootView(chatClient: chatClient)
            }
        case .review:
            sidebarNavigationStack(for: .review) {
                ReviewRootView(chatClient: chatClient)
            }
        case .workspace:
            sidebarNavigationStack(for: .workspace) {
                WorkspaceRootView(chatClient: chatClient)
            }
        case .settings:
            sidebarNavigationStack(for: .settings) {
                SettingsView()
            }
        }
    }

    private func sidebarNavigationStack<Root: View>(
        for tab: AppTab,
        @ViewBuilder root: () -> Root
    ) -> some View {
        NavigationStack(path: pathBinding(for: tab)) {
            root()
                .navigationDestination(for: RouterDestination.self) { destination in
                    ConnectedDestinationView(chatClient: chatClient, destination: destination)
                }
        }
    }

    private func pathBinding(for tab: AppTab) -> Binding<[RouterDestination]> {
        Binding(
            get: { router.path(for: tab) },
            set: { router.setPath($0, for: tab) }
        )
    }

    private func selectChatSession(_ session: OCSession) {
        router.selectChatSession(session)
    }

    private func handleDeletedSession(_ session: OCSession) {
        router.clearChatSession(ifMatching: session.id)
        chatClient.unloadSession(ifMatching: session.id)
    }
}

private struct ConnectedSidebarNavigation: View {
    let selectedTab: AppTab
    let onSelect: (AppTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("OpenLens", systemImage: "circle.hexagongrid.fill")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ForEach(AppTab.allCases) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    Label(sidebarTitle(for: tab), systemImage: tab.icon)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.appPrimary)
                        .symbolVariant(selectedTab == tab ? .fill : .none)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(
                            selectedTab == tab ? Color.appTertiary : Color.clear,
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func sidebarTitle(for tab: AppTab) -> String {
        tab == .chat ? "Chat" : tab.title
    }
}

private struct ConnectedDestinationView: View {
    @Bindable var chatClient: ChatClient
    let destination: RouterDestination

    @ViewBuilder
    var body: some View {
        switch destination {
        case .chatSession(let session):
            SessionChatDestinationView(chatClient: chatClient, session: session)
        case .sessionInsights(let sessionID):
            InsightsRootView(chatClient: chatClient, sessionID: sessionID)
        case .reviewMessage, .reviewFile, .workspacePath:
            EmptyView()
        }
    }
}

private struct SessionChatDestinationView: View {
    @Bindable var chatClient: ChatClient
    let session: OCSession

    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                ChatView(chatClient: chatClient, initialSession: session)
                    .id(session.id)
            } else {
                ProgressView()
                    .tint(Color.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.appBackground)
        .toolbar(.visible, for: .navigationBar)
        .task(id: session.id) {
            isReady = false
            if chatClient.currentSession?.id != session.id {
                await chatClient.loadSession(session)
            } else {
                await chatClient.restoreProjectContext(for: session)
            }
            guard !Task.isCancelled, chatClient.currentSession?.id == session.id else { return }
            isReady = true
        }
    }
}

private struct ChatDetailPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 72, height: 72)
                .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 6) {
                Text(AppText.selectSessionTitle)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)

                Text(AppText.selectSessionSubtitle)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }
}
