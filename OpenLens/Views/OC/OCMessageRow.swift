import SwiftUI
import UIKit

/// The web's user message: bubble right, tap shows rewind + "..." (date, copy) under it.
struct OCUserMessageRow: View {
    @Bindable var chatClient: ChatClient
    let message: ChatMessage

    @State private var showsActions = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            MessageBubbleView(
                message: message,
                submissionState: chatClient.promptSubmissionState(forMessageID: message.id)
            )
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { showsActions.toggle() } }

            if showsActions {
                HStack(spacing: 6) {
                    Button {
                        Task { await chatClient.undo(message) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward").frame(width: 20, height: 20)
                    }
                    .disabled(!chatClient.canUndo(message))
                    .accessibilityLabel(AppText.ocRewind)
                    .accessibilityIdentifier("oc.rewind")

                    Menu {
                        Text(Self.dateText(message.createdAt))
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label(AppText.copyMessage, systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 20, height: 20)
                    }
                    .accessibilityLabel(AppText.ocMoreActions)
                    .accessibilityIdentifier("oc.moreActions")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.appSecondary)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }
}

/// Copy icon + turn duration under the last text of a finished turn.
struct OCAssistantFooter: View {
    let info: OCAssistantFooterInfo

    private static func text(of message: ChatMessage) -> String {
        let texts = message.assistantSegments.compactMap { segment -> String? in
            if case .text(let text) = segment.kind { return text }
            return nil
        }
        return texts.isEmpty ? message.content : texts.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                UIPasteboard.general.string = Self.text(of: info.message)
            } label: {
                Image(systemName: "doc.on.doc").frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppText.ocCopyResponse)
            .accessibilityIdentifier("oc.copyResponse")
            if let duration = info.duration {
                Text(OCTimelineGrouping.durationText(duration))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.appSecondary)
        .padding(.top, 2)
    }
}
