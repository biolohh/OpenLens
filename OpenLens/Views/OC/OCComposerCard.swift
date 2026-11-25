import SwiftUI

/// The web composer on mobile: one bordered card with the prompt field on top and a control row
/// below: `+` (attachments), agent, "provider / model", variant, and the square send/stop button
/// at the trailing edge. ChatView supplies the field, attach menu and action button (so the
/// slash/skill chips, send, stop, queue and steer logic stay in one place); this view only lays
/// them out and owns the agent / model / variant controls.
struct OCComposerCard<Field: View, Attach: View, Action: View>: View {
    @Bindable var chatClient: ChatClient
    @Environment(\.colorScheme) private var colorScheme
    /// Selectable agents (`GET /api/agent`, primary/all, not hidden); empty hides the agent control.
    let agents: [WorkspaceAgentItem]
    let showsAttach: Bool
    let openModelPicker: () -> Void
    @ViewBuilder let field: () -> Field
    @ViewBuilder let attach: () -> Attach
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field()
                .padding(.horizontal, 12)
                .padding(.top, 10)
            controlRow
        }
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("oc.composer")
    }

    /// Same raised-field fill as OCHomeView's search field: web #252525 in dark, surface in light.
    private var cardFill: Color { colorScheme == .dark ? Color.appTertiary : Color.appSurface }

    private var controlRow: some View {
        HStack(spacing: 2) {
            if showsAttach {
                attach()
                    .accessibilityIdentifier("oc.composer.attach")
            }
            if !agents.isEmpty { agentMenu }
            modelChip
            if chatClient.showsThinkingEffortPicker { variantMenu }
            Spacer(minLength: 4)
            action()
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        .frame(minHeight: 36)
    }

    private func chipLabel(_ text: String, muted: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(muted ? Color.appSecondary : Color.appPrimary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.appSecondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .contentShape(Rectangle())
    }

    // MARK: Agent

    private var currentAgent: String? { chatClient.currentSession?.agent }

    /// The session's agent, or "Default" when it has none (the server picks), never a guess.
    private var agentTitle: String {
        guard let currentAgent else { return AppText.thinkingDefault }
        return agents.first(where: { $0.id == currentAgent })?.title ?? currentAgent
    }

    private var agentMenu: some View {
        Menu {
            Section(AppText.ocComposerAgent) {
                ForEach(agents) { agent in
                    Button {
                        chatClient.selectAgent(agent.id)
                    } label: {
                        if agent.id == currentAgent {
                            Label(agent.title, systemImage: "checkmark")
                        } else {
                            Text(agent.title)
                        }
                    }
                }
            }
        } label: {
            chipLabel(agentTitle)
        }
        .accessibilityIdentifier("oc.composer.agent")
        .accessibilityLabel(AppText.ocComposerAgent)
        .accessibilityValue(agentTitle)
    }

    // MARK: Model

    private var modelChip: some View {
        Button(action: openModelPicker) {
            // The web shows "provider / model" and drops the provider first when the row is tight.
            ViewThatFits(in: .horizontal) {
                modelChipLabel(showsProvider: true)
                modelChipLabel(showsProvider: false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.composer.model")
        .accessibilityLabel(AppText.ocComposerModel)
        .accessibilityValue(modelAccessibilityValue)
    }

    private var modelAccessibilityValue: String {
        if let provider = chatClient.selectedModel?.providerName, !provider.isEmpty {
            return "\(provider), \(chatClient.selectedModelDisplayName)"
        }
        return chatClient.selectedModelDisplayName
    }

    private func modelChipLabel(showsProvider: Bool) -> some View {
        HStack(spacing: 3) {
            if showsProvider, let provider = chatClient.selectedModel?.providerName, !provider.isEmpty {
                Text(provider)
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Text("/").foregroundStyle(Color.appSecondary)
            }
            Text(chatClient.selectedModelDisplayName)
                .foregroundStyle(Color.appPrimary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.appSecondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    // MARK: Variant

    private var variantMenu: some View {
        Menu {
            Section(AppText.reasoning) {
                Button {
                    chatClient.selectVariant(nil)
                } label: {
                    if chatClient.selectedVariant == nil {
                        Label(AppText.thinkingDefault, systemImage: "checkmark")
                    } else {
                        Text(AppText.thinkingDefault)
                    }
                }
                ForEach(chatClient.availableReasoningVariants) { variant in
                    Button {
                        chatClient.selectVariant(variant.id)
                    } label: {
                        if chatClient.selectedVariant == variant.id {
                            Label(variant.displayName, systemImage: "checkmark")
                        } else {
                            Text(variant.displayName)
                        }
                    }
                }
            }
        } label: {
            chipLabel(chatClient.selectedVariantDisplayName, muted: true)
        }
        .accessibilityIdentifier("oc.composer.variant")
        .accessibilityLabel(AppText.ocComposerVariant)
        .accessibilityValue(chatClient.selectedVariantDisplayName)
    }
}

/// Square send / stop button of the web composer (28pt, radius 6).
struct OCComposerSendLabel: View {
    enum Kind { case send, queue, stop, stopping, submitting }
    let kind: Kind
    let enabled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(kind == .stop || kind == .stopping ? Color.appPrimary : Color.appSendAction.opacity(enabled ? 1 : 0.35))
            switch kind {
            case .stopping, .submitting:
                ProgressView().controlSize(.small).tint(Color.appOnSendAction)
            case .stop:
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appBackground)
            case .queue:
                Image(systemName: "arrow.uturn.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appOnSendAction)
            case .send:
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appOnSendAction)
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
}

/// Line comments from the Changes tab, waiting in the composer as chips (the web's comment
/// chip): file name and lines, the comment text, and a button to drop it. They are folded into
/// the next prompt as the web's "The user made the following comment regarding …" sentences.
struct OCComposerCommentChips: View {
    let sessionID: String?
    private let store = OCDiffCommentStore.shared

    var body: some View {
        let items = store.comments(sessionID: sessionID)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { comment in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appAccent)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\((comment.file as NSString).lastPathComponent) · \(AppText.ocLineCommentLabel(start: comment.startLine, end: comment.endLine))")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.appSecondary)
                                .lineLimit(1)
                            Text(comment.text)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.appPrimary)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                        Button { store.remove(comment.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.appSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("oc.composer.comment.remove")
                        .accessibilityLabel(AppText.ocLineCommentRemove)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.appTertiary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("oc.composer.comment")
                }
            }
        }
    }
}
