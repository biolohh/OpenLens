import SwiftUI
import UIKit

/// The web's user message: bubble right, tap shows rewind + "..." (date, copy) under it.
struct OCUserMessageRow: View {
    @Bindable var chatClient: ChatClient
    let message: ChatMessage

    @State private var showsActions = false
    @State private var confirmsRewind = false

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
                        confirmsRewind = true
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
        .confirmationDialog(AppText.ocRewind, isPresented: $confirmsRewind, titleVisibility: .visible) {
            Button(AppText.ocRewindConfirm, role: .destructive) {
                Task { await chatClient.undo(message) }
            }
            Button(AppText.cancel, role: .cancel) {}
        } message: {
            Text(AppText.ocRewindMessage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: AppText.ocRewind) {
            if chatClient.canUndo(message) { confirmsRewind = true }
        }
        .accessibilityAction(named: AppText.copyMessage) {
            UIPasteboard.general.string = message.content
        }
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }
}

/// Copy icon + turn duration under the last text of a finished turn.
struct OCAssistantFooter: View {
    let info: OCAssistantFooterInfo

    var body: some View {
        HStack(spacing: 6) {
            Button {
                UIPasteboard.general.string = OCTimelineGrouping.responseText(info.messages)
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
