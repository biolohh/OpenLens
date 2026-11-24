import SwiftUI

/// The web's mobile "Tabs" bottom sheet: sessions opened in this run, then the
/// app destinations (Home, Review, Workspace, Micro, Settings).
struct OCNavigationSheet: View {
    let selectedTab: AppTab
    let openedSessions: [OCSession]
    let onSelectTab: (AppTab) -> Void
    let onOpenSession: (OCSession) -> Void
    let onCloseSession: (OCSession) -> Void

    /// Home is the chat tab root; the rest keep their old tab screens.
    private static let destinations: [AppTab] = [.chat, .review, .workspace, .micro, .settings]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(openedSessions) { session in
                HStack(spacing: 0) {
                    Button { onOpenSession(session) } label: {
                        HStack(spacing: 8) {
                            OCMonogram(letter: OCHomeGrouping.monogram(OCHomeGrouping.projectName(for: session)))
                            Text(session.title.isEmpty ? AppText.titleUntitled : session.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.appPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { onCloseSession(session) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppText.ocCloseTab)
                }
            }
            if !openedSessions.isEmpty {
                Divider().padding(.vertical, 6)
            }
            ForEach(Self.destinations) { tab in
                Button { onSelectTab(tab) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: tab))
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(title(for: tab)).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selectedTab == tab ? Color.appPrimary : Color.appSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 36)
                    .background(
                        selectedTab == tab ? Color.appTertiary : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("oc.menu.\(tab.rawValue)")
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(CGFloat(openedSessions.isEmpty ? 0 : openedSessions.count * 44 + 13) + CGFloat(Self.destinations.count * 36) + 56)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
        .accessibilityIdentifier("oc.menuSheet")
    }

    private func title(for tab: AppTab) -> String {
        tab == .chat ? AppText.ocHome : tab.title
    }

    private func icon(for tab: AppTab) -> String {
        tab == .chat ? "square.grid.2x2" : tab.icon
    }
}
