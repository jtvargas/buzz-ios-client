import SwiftUI

/// A native popover anchored to the work indicator. Its roster and label use the same
/// live model, so opening the popover never freezes a list of agents that have stopped.
struct AgentWorkingIndicatorView: View {
    let model: ChannelTypingModel

    @Environment(\.entityNames) private var names
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingAgents = false

    private var agents: [String] { model.workingAgents(isAgent: names.isAgent) }

    private var label: String? {
        model.indicator(nameFor: names.name(for:), isAgent: names.isAgent, activity: .working)
    }

    var body: some View {
        Group {
            // Retain the presentation anchor until dismissal completes when the last
            // heartbeat expires while the popover is open.
            if let label = label ?? (isShowingAgents ? "No agents working" : nil) {
                Button(action: showAgents) {
                    ConversationAccessoryCapsule(
                        label: label, showsDisclosure: true, expandsToFillWidth: false
                    ) {
                        TypingDots()
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.hivePress(.control, in: Capsule()))
                .accessibilityLabel(label)
                .accessibilityHint("Shows the agents working in this conversation")
                .popover(isPresented: $isShowingAgents, arrowEdge: .bottom) {
                    WorkingAgentsPopover(model: model)
                        .presentationCompactAdaptation(.popover)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity)
                .onChange(of: agents.isEmpty) { _, isEmpty in
                    if isEmpty { isShowingAgents = false }
                }
                .onDisappear { isShowingAgents = false }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: agents)
    }

    private func showAgents() {
        guard !agents.isEmpty else { return }
        HiveHaptics.play(.disclosureToggled)
        isShowingAgents = true
    }
}
