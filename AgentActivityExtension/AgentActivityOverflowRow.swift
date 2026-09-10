import SwiftUI

struct AgentActivityOverflowRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.primary.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) more \(count == 1 ? "agent" : "agents") working")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("View all agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 20)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
