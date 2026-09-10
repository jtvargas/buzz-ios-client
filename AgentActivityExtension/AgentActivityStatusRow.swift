import SwiftUI

struct AgentActivityStatusRow: View {
    let status: AgentActivityAttributes.Status

    private var title: String {
        switch status {
        case .paused: "Monitoring paused"
        case .ended: "Monitoring ended"
        case .reconnecting: "Reconnecting"
        case .waiting, .working: "Waiting for activity"
        }
    }

    private var detail: String {
        switch status {
        case .paused: "Open Hive to resume"
        case .ended: "View agent activity in Hive"
        case .reconnecting: "Checking agent activity"
        case .waiting, .working: "Agent updates will appear here"
        }
    }

    private var symbol: String {
        switch status {
        case .paused: "pause.fill"
        case .ended: "stop.fill"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .waiting, .working: "ellipsis"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.primary.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status == .reconnecting {
                AgentActivityWorkingIndicator()
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
