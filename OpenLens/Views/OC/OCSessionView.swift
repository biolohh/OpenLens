import SwiftUI

/// What the compact shell offers the open-session screen: the web header's open-tab count and the
/// "Tabs" sheet. Injected by `ConnectedRootView`; the default does nothing (previews, iPad sidebar).
struct OCShell {
    var openCount: Int = 0
    var openMenu: () -> Void = {}
}

private struct OCShellKey: EnvironmentKey {
    static let defaultValue = OCShell()
}

extension EnvironmentValues {
    var ocShell: OCShell {
        get { self[OCShellKey.self] }
        set { self[OCShellKey.self] = newValue }
    }
}

/// The web's mobile session screen: header (monogram, title, open count), tab row
/// Session | Changes | More..., project chip, then the tab content. The Session tab is the
/// existing `ChatView` (streaming, permissions, questions, forms, queue, undo all unchanged).
struct OCSessionView: View {
    enum Tab: Hashable { case session, changes, files, terminal }

    @Bindable var chatClient: ChatClient
    let session: OCSession
    let isReady: Bool

    @Environment(\.ocShell) private var shell
    @Environment(AppRouter.self) private var router: AppRouter?
    @State private var tab: Tab = .session
    @State private var showMore = false
    @State private var showDetails = false

    /// The session as the server last reported it (title edits), else the pushed snapshot.
    private var current: OCSession {
        chatClient.currentSession?.id == session.id ? (chatClient.currentSession ?? session) : session
    }

    private var projectName: String { OCHomeGrouping.projectName(for: current) }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabRow
            projectChip
            content
        }
        .background(Color.appBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showMore) {
            OCSessionMoreSheet(
                onFiles: { tab = .files },
                onTerminal: { tab = .terminal },
                onUsage: { router?.navigate(to: .sessionInsights(sessionID: session.id)) },
                onDetails: { showDetails = true }
            )
        }
        .sheet(isPresented: $showDetails) {
            SessionSummarySheet(chatClient: chatClient)
        }
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityIdentifier("oc.session")
        }
    }

    // MARK: Header

    private var header: some View {
        Button(action: shell.openMenu) {
            HStack(spacing: 10) {
                OCMonogram(letter: OCHomeGrouping.monogram(projectName))
                Text(current.title.isEmpty ? AppText.ocNewSession : current.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if shell.openCount > 0 {
                    Text("\(shell.openCount)")
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
                        .fill(selected ? Color.appSelection : .clear)
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
    private var content: some View {
        switch tab {
        case .session:
            if isReady {
                ChatView(chatClient: chatClient, initialSession: session)
                    .id(session.id)
            } else {
                ProgressView()
                    .tint(Color.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .changes:
            OCPlaceholder(icon: "arrow.triangle.branch", title: AppText.ocNoChangesTitle, subtitle: AppText.ocNoChangesSubtitle)
        case .files:
            OCPlaceholder(icon: "folder", title: AppText.ocTabFiles, subtitle: AppText.ocComingSoon)
        case .terminal:
            OCPlaceholder(icon: "terminal", title: AppText.ocTabTerminal, subtitle: AppText.ocComingSoon)
        }
    }
}

/// Centered icon, title and hint, used until the Changes / Files / Terminal tabs exist.
private struct OCPlaceholder: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Color.appSecondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("oc.placeholder")
    }
}

/// The web's "More..." bottom sheet: Files, Terminal, Usage, Session details.
private struct OCSessionMoreSheet: View {
    let onFiles: () -> Void
    let onTerminal: () -> Void
    let onUsage: () -> Void
    let onDetails: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            row("folder", AppText.ocTabFiles, id: "oc.more.files", action: onFiles)
            row("terminal", AppText.ocTabTerminal, id: "oc.more.terminal", action: onTerminal)
            row("chart.bar.doc.horizontal", AppText.ocUsage, id: "oc.more.usage", action: onUsage)
            row("info.circle", AppText.ocSessionDetails, id: "oc.more.details", chevron: true, action: onDetails)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
    }

    private func row(_ icon: String, _ title: String, id: String, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
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
