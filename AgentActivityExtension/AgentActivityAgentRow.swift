import SwiftUI

struct AgentActivityAgentRow: View {
    let row: AgentActivityAttributes.AgentRow

    var body: some View {
        HStack(spacing: 12) {
            Text(row.initials)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 40, height: 40)
                .background(.primary.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.name) working…")
                    .font(.headline)
                    .lineLimit(1)
                Text(row.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AgentActivityWorkingIndicator()
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name) is working in \(row.context)")
        .accessibilityHint("Opens this conversation in Hive")
    }
}
