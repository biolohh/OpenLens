import SwiftUI

/// The web composer on mobile: one bordered card with the prompt field on top and a control row
/// below: `+` (attachments), agent, "provider / model", variant, and the square send/stop button
/// at the trailing edge. ChatView supplies the field, attach menu and action button (so the
/// slash/skill chips, send, stop, queue and steer logic stay in one place); this view only lays
/// them out and owns the agent / model / variant controls.
struct OCComposerCard<Field: View, Attach: View, Action: View>: View {
    @Bindable var chatClient: ChatClient
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
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appSeparator, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("oc.composer")
    }

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
            chipLabel(agents.first(where: { $0.id == currentAgent })?.title ?? currentAgent ?? agents.first?.title ?? AppText.ocComposerAgent)
        }
        .accessibilityIdentifier("oc.composer.agent")
        .accessibilityLabel(AppText.ocComposerAgent)
    }

    // MARK: Model

    private var modelChip: some View {
        Button(action: openModelPicker) {
            HStack(spacing: 3) {
                if let provider = chatClient.selectedModel?.providerName, !provider.isEmpty {
                    Text(provider)
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                    Text("/").foregroundStyle(Color.appSecondary)
                }
                Text(chatClient.selectedModelDisplayName)
                    .foregroundStyle(Color.appPrimary.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appSecondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oc.composer.model")
        .accessibilityLabel(chatClient.selectedModelDisplayName)
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
