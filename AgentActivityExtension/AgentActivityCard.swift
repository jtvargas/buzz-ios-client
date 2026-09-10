import ActivityKit
import SwiftUI
import WidgetKit

struct AgentActivityCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let context: ActivityViewContext<AgentActivityAttributes>
    var isExpandedIsland = false

    private var status: AgentActivityAttributes.Status {
        if context.state.status == .ended { return .ended }
        return context.isStale ? .paused : context.state.status
    }

    private var visibleRows: [AgentActivityAttributes.AgentRow] {
        let limit = isExpandedIsland || dynamicTypeSize > .xLarge || context.state.agentCount > 2 ? 1 : 2
        return Array(context.state.rows.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = AgentActivityAttributes.link(communityID: context.attributes.communityID) {
                Link(destination: url) {
                    AgentActivityHeader(
                        updatedAt: context.state.updatedAt,
                        agentCount: status == .working ? context.state.agentCount : 0
                    )
                }
                .accessibilityHint("Shows all agents and conversations")
            }

            if status == .working {
                ForEach(visibleRows) { row in
                    if let url = AgentActivityAttributes.link(communityID: context.attributes.communityID, row: row) {
                        Link(destination: url) { AgentActivityAgentRow(row: row) }
                    }
                }
                if !isExpandedIsland, dynamicTypeSize <= .xLarge,
                   context.state.agentCount > visibleRows.count,
                   let url = AgentActivityAttributes.link(communityID: context.attributes.communityID) {
                    Link(destination: url) {
                        AgentActivityOverflowRow(count: context.state.agentCount - visibleRows.count)
                    }
                }
            } else {
                AgentActivityStatusRow(status: status)
            }
        }
        .padding(.horizontal, isExpandedIsland ? 4 : 16)
        .padding(.vertical, isExpandedIsland ? 0 : 10)
        .foregroundStyle(.primary)
        .tint(.primary)
    }
}
