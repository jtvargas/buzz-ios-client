import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HiveAgentActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityCard(context: context)
                .widgetURL(AgentActivityAttributes.link(communityID: context.attributes.communityID))
        } dynamicIsland: { context in
            let paused = context.isStale || context.state.status == .paused || context.state.status == .ended
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    AgentActivityCard(context: context, isExpandedIsland: true)
                        .environment(\.colorScheme, .dark)
                }
            } compactLeading: {
                Image(systemName: paused ? "pause.fill" : "person.2.fill")
                    .foregroundStyle(.white)
                    .accessibilityLabel(paused ? "Monitoring paused" : "Hive agent activity")
            } compactTrailing: {
                Text(paused ? "—" : "\(context.state.agentCount)")
                    .monospacedDigit()
                    .accessibilityLabel(
                        paused ? "Monitoring paused" : "\(context.state.agentCount) agents working"
                    )
            } minimal: {
                Image(systemName: paused ? "pause.fill" : "person.2.fill")
                    .foregroundStyle(.white)
                    .accessibilityLabel(paused ? "Monitoring paused" : "Hive agent activity")
            }
            .widgetURL(AgentActivityAttributes.link(communityID: context.attributes.communityID))
            .keylineTint(.white.opacity(0.2))
        }
    }
}
