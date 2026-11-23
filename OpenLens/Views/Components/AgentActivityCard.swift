import SwiftUI

/// Detail card shown when tapping the thinking shimmer.
/// Displays thinking text and a timeline of tool steps.
struct AgentActivityCard: View {
    let activity: AgentActivity
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !activity.thinkingText.isEmpty {
                        thinkingSection
                    }

                    if !activity.steps.isEmpty {
                        stepsSection
                    }

                    if activity.thinkingText.isEmpty && activity.steps.isEmpty {
                        Text(AppText.activityEmpty)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .navigationTitle(AppText.activityTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppText.done) { dismiss() }
                }
            }
        }
    }

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppText.activityThinking)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)

            Text(activity.thinkingText)
                .font(.openLensMono(size: 13))
                .foregroundStyle(Color.appSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppText.activitySteps(activity.steps.count))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)

            ForEach(activity.steps) { step in
                stepRow(step)
            }
        }
    }

    private func stepRow(_ step: ActivityStep) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("→ \(step.label)")
                .font(.openLensMono(size: 13, weight: .medium))
                .foregroundStyle(Color.appPrimary)

            if !step.detail.isEmpty && step.type == .toolCall {
                Text(step.detail)
                    .font(.openLensMono(size: 12))
                    .foregroundStyle(Color.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
