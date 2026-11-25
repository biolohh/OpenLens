import SwiftUI

/// What the compact shell offers the open-session screen: the web header's open-tab count and the
/// "Tabs" sheet. Injected by `ConnectedRootView`; the default does nothing (previews, iPad sidebar).
struct OCShell {
    var openCount: Int = 0
    var openMenu: () -> Void = {}
}

private struct OCShellKey: EnvironmentKey {
    static let defaultValue: OCShell? = nil
}

private struct OCPanelBackgroundKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// Present only in the compact (iPhone) shell; nil on iPad, which keeps its normal navigation bar.
    var ocShell: OCShell? {
        get { self[OCShellKey.self] }
        set { self[OCShellKey.self] = newValue }
    }

    /// Fill of the session panel (the web's #161616 card in dark); ChatView paints it behind the transcript.
    var ocPanelBackground: Color? {
        get { self[OCPanelBackgroundKey.self] }
        set { self[OCPanelBackgroundKey.self] = newValue }
    }
}

/// The web's mobile session screen: header (monogram, title, open count), tab row
/// Session | Changes | More..., project chip, then the tab content. The Session tab is the
/// existing `ChatView` (streaming, permissions, questions, forms, queue, undo all unchanged);
/// it stays mounted under the other tabs so its state and recovery hooks keep running.
struct OCSessionView: View {
    enum Tab: Hashable { case session, changes, files, terminal }

    @Bindable var chatClient: ChatClient
    let session: OCSession
    let isReady: Bool

    @Environment(\.ocShell) private var shell
    @Environment(\.connection) private var connection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppRouter.self) private var router: AppRouter?
    @State private var tab: Tab = .session
    @State private var showMore = false
    @State private var showDetails = false
    /// Files tab: open file tabs and the shown one (nil = the "All files" tree).
    @State private var filesOpen: [String] = []
    @State private var filesActive: String?
    /// Chosen in the More sheet; run once the sheet has finished dismissing.
    @State private var pendingMoreAction: (() -> Void)?
    /// Terminal tab: the session's terminals and live attachment, kept across tab switches.
    @State private var terminal: OCTerminalStore?

    /// The session as the server last reported it (title edits), else the pushed snapshot.
    private var current: OCSession {
        chatClient.currentSession?.id == session.id ? (chatClient.currentSession ?? session) : session
    }

    private var projectName: String { OCHomeGrouping.projectName(for: current) }

    /// Same rule as OCHomeView: dark = base page with a raised panel, light = grey page, white panel.
    private var pageBackground: Color { colorScheme == .dark ? Color.appBackground : Color.appTertiary }
    private var panelBackground: Color { colorScheme == .dark ? Color.appSurface : Color.appBackground }

    var body: some View {
        Group {
            if let shell {
                compact(shell)
            } else {
                // iPad / no shell: the plain chat with its normal navigation bar.
                chat
            }
        }
        .environment(\.ocSessionDirectory, current.directory)
    }

    private func compact(_ shell: OCShell) -> some View {
        VStack(spacing: 0) {
            header(shell)
            VStack(spacing: 0) {
                tabRow
                if tab == .session { projectChip }
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.appSeparator, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .environment(\.ocPanelBackground, panelBackground)
        .background(pageBackground.ignoresSafeArea())
        // The nav bar is hidden, so the system edge-swipe is gone: a leading-edge drag on this
        // screen only pops the chat (same as the back chevron / Tabs > Home).
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard value.startLocation.x < 20,
                          value.translation.width > 80,
                          abs(value.translation.height) < 60,
                          let router, !router.chatPath.isEmpty else { return }
                    withAnimation { router.chatPath.removeLast() }
                }
        )
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showMore, onDismiss: {
            let action = pendingMoreAction
            pendingMoreAction = nil
            action?()
        }) {
            OCSessionMoreSheet(
                chatClient: chatClient,
                files: { tab = .files },
                terminal: {
                    // Created on first use; a new session gets a new store (see onChange(of: session.id)).
                    if terminal?.sessionID != current.id {
                        terminal = OCTerminalStore(sessionID: current.id, directory: current.directory)
                    }
                    tab = .terminal
                },
                usage: { router?.navigate(to: .sessionInsights(sessionID: session.id)) },
                details: { showDetails = true },
                choose: { pendingMoreAction = $0 }
            )
        }
        .sheet(isPresented: $showDetails) {
            SessionSummarySheet(chatClient: chatClient)
        }
        // A deep link, Live Activity or Shortcut into a session lands on its Session tab.
        .onChange(of: router?.chatPath) { _, _ in tab = .session }
        .onChange(of: session.id) { _, _ in
            tab = .session
            filesOpen = []
            filesActive = nil
            // Detach only: the terminals keep running on the server, as on the web.
            terminal?.disconnect()
            terminal = nil
        }
        .onDisappear { terminal?.disconnect() }
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.session")
        }
#if DEBUG
        // Smoke measurement: how many times the transcript scrolled itself to the bottom.
        .overlay(alignment: .bottomLeading) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("oc.debug.repins")
                    .accessibilityLabel("\(ChatStreamInstrumentation.scrollToBottomCount)")
            }
        }
#endif
    }

    // MARK: Header

    private func header(_ shell: OCShell) -> some View {
        HStack(spacing: 0) {
            if let router, router.chatPath.count > 1 {
                Button {
                    router.chatPath.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("oc.back")
                .accessibilityLabel(AppText.ocBack)
            }
            Button(action: shell.openMenu) {
                HStack(spacing: 10) {
                    OCMonogram(letter: OCHomeGrouping.monogram(projectName))
                    Text(current.title.isEmpty ? AppText.ocNewSession : current.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if connection.isReconnecting {
                        Circle()
                            .fill(Color.appWarning)
                            .frame(width: 7, height: 7)
                            .accessibilityIdentifier("oc.reconnecting")
                            .accessibilityLabel(AppText.ocReconnecting)
                    }
                    if shell.openCount > 0 {
                        Text("\(shell.openCount)")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appSecondary)
                            .accessibilityIdentifier("oc.openCount")
                    }
                }
                .foregroundStyle(Color.appPrimary)
                .padding(.leading, router.map { $0.chatPath.count > 1 } == true ? 4 : 16)
                .padding(.trailing, 16)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("oc.menu")
            .accessibilityLabel(AppText.ocMenuTitle)
        }
    }

    // MARK: Tabs

    private var tabRow: some View {
        HStack(spacing: 0) {
            tabButton(AppText.ocTabSession, selected: tab == .session, id: "oc.tab.session") { tab = .session }
            tabButton(AppText.ocTabChanges, selected: tab == .changes, id: "oc.tab.changes") { tab = .changes }
            tabButton(AppText.ocTabMore, selected: tab == .files || tab == .terminal, id: "oc.tab.more") { showMore = true }
        }
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appSeparator).frame(height: 1)
        }
    }

    private func tabButton(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.appPrimary : Color.appSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? (colorScheme == .dark ? Color.appSelection : Color.appPrimary) : .clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var projectChip: some View {
        HStack(spacing: 6) {
            OCMonogram(letter: OCHomeGrouping.monogram(projectName))
            Text(projectName)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
    }

    // MARK: Content

    @ViewBuilder
    private var chat: some View {
        if isReady {
            ChatView(chatClient: chatClient, initialSession: session)
                .id(session.id)
        } else {
            ProgressView()
                .tint(Color.appSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// ChatView stays mounted under every tab (scroll position, composer state, foreground recovery).
    private var content: some View {
        ZStack {
            chat
                .opacity(tab == .session ? 1 : 0)
                .allowsHitTesting(tab == .session)
                .accessibilityHidden(tab != .session)
            switch tab {
            case .session:
                EmptyView()
            case .changes:
                OCChangesView(session: current, refreshKey: chatClient.timelineVersion) { path in
                    if !filesOpen.contains(path) { filesOpen.append(path) }
                    filesActive = path
                    tab = .files
                }
            case .files:
                OCFilesView(directory: current.directory, openPaths: $filesOpen, activePath: $filesActive)
            case .terminal:
                if let terminal {
                    OCTerminalView(store: terminal)
                }
            }
        }
    }
}

/// The web's "More..." bottom sheet: Files, Terminal, Usage, Session details. The chosen action
/// runs after the sheet has dismissed (a sheet presented mid-dismiss can be dropped).
private struct OCSessionMoreSheet: View {
    @Bindable var chatClient: ChatClient
    let files: () -> Void
    let terminal: () -> Void
    let usage: () -> Void
    let details: () -> Void
    /// Hands the chosen action to the owner, which runs it in the sheet's onDismiss.
    let choose: (@escaping () -> Void) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            row("folder", AppText.ocTabFiles, id: "oc.more.files", action: files)
            row("terminal", AppText.ocTabTerminal, id: "oc.more.terminal", action: terminal)
            row("chart.bar.doc.horizontal", AppText.ocUsage, id: "oc.more.usage", action: usage)
            row("info.circle", AppText.ocSessionDetails, id: "oc.more.details", chevron: true, action: details)
#if DEBUG
            if chatClient.isRecordingStream || chatClient.supportsStreamRecording {
                row(chatClient.isRecordingStream ? "stop.circle" : "record.circle",
                    chatClient.isRecordingStream ? AppText.recordingStop : AppText.recordingStart,
                    id: "oc.more.recording") {
                    if chatClient.isRecordingStream { chatClient.stopStreamRecording() } else { chatClient.startStreamRecording() }
                }
            }
#endif
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .presentationDetents([.height(chatClient.supportsStreamRecording ? 310 : 260)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
    }

    private func row(_ icon: String, _ title: String, id: String, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            choose(action)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appSecondary)
                }
            }
            .foregroundStyle(Color.appPrimary)
            .padding(.horizontal, 10)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
