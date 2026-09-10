import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HiveAgentActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityCard(context: context)
                .activityBackgroundTint(Color(red: 0.06, green: 0.06, blue: 0.08))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(AgentActivityAttributes.link(communityID: context.attributes.communityID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    AgentActivityCard(context: context)
                }
            } compactLeading: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Hive agent activity")
            } compactTrailing: {
                Text(context.isStale ? "—" : "\(context.state.agentCount)")
                    .monospacedDigit()
                    .accessibilityLabel(
                        context.isStale ? "Monitoring paused" : "\(context.state.agentCount) agents working"
                    )
            } minimal: {
                Image(systemName: context.isStale ? "pause.circle" : "sparkles")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(context.isStale ? "Monitoring paused" : "Hive agent activity")
            }
            .widgetURL(AgentActivityAttributes.link(communityID: context.attributes.communityID))
            .keylineTint(.yellow)
        }
    }
}
