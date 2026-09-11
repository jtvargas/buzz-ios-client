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
                        label: label, showsDisclosure: true, isDisclosed: isShowingAgents,
                        expandsToFillWidth: false, isInteractive: true
                    ) {
                        TypingDots()
                    }
                    // The platform minimum for the hit area, and the reason the press cannot
                    // be drawn by a button style here: this frame is 16pt taller than the
                    // pill, and ``PressFeedbackButtonStyle`` washes the whole label frame —
                    // which put an 8pt oval above and below a 28pt capsule. The pill's own
                    // interactive glass answers the finger in its own bounds instead, which
                    // is the same call already made for the home toolbar's capsule.
                    .frame(minHeight: 44)
                }
                .buttonStyle(.hiveNoPress)
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
