import ActivityKit
import SwiftUI
import WidgetKit

struct AgentActivityCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let context: ActivityViewContext<AgentActivityAttributes>

    private var visibleRows: [AgentActivityAttributes.AgentRow] {
        Array(context.state.rows.prefix(dynamicTypeSize.isAccessibilitySize ? 1 : 3))
    }

    private var paused: Bool {
        context.isStale || context.state.status == .paused || context.state.status == .ended
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("Hive")
                    .fontWeight(.semibold)
                Text(context.attributes.communityName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(paused ? "Paused" : "\(context.state.agentCount) working")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.yellow.opacity(0.15), in: Capsule())
                    .foregroundStyle(.yellow)
            }
            .font(.caption)

            if paused {
                Label("Monitoring paused · Open Hive to resume", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if context.state.status != .working {
                Text(context.state.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(visibleRows) { row in
                    if let url = AgentActivityAttributes.link(communityID: context.attributes.communityID, row: row) {
                        Link(destination: url) { agentRow(row) }
                    }
                }
            }

            HStack(spacing: 3) {
                if !paused, context.state.isForegroundOnly == true {
                    Text("Foreground only ·")
                }
                Text("Updated")
                Text(context.state.updatedAt, style: .relative)
                Spacer(minLength: 0)
                if !paused, context.state.agentCount > visibleRows.count,
                   let url = AgentActivityAttributes.link(communityID: context.attributes.communityID) {
                    Link("+\(context.state.agentCount - visibleRows.count) more", destination: url)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
    }

    private func agentRow(_ row: AgentActivityAttributes.AgentRow) -> some View {
        HStack(spacing: 8) {
            Text(row.initials)
                .font(.caption2.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(row.name) is working…")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(row.context)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
