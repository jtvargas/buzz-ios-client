import SwiftUI

struct AgentActivityHeader: View {
    let updatedAt: Date
    let agentCount: Int

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text("Agents")
                    .font(.subheadline.weight(.semibold))
                if agentCount > 1 {
                    Text("\(agentCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                Text("Updated \(updatedAt, style: .relative) ago")
                    .fixedSize(horizontal: true, vertical: false)
                Text(updatedAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
