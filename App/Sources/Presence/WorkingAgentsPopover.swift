import SwiftUI

/// A bounded, live roster. Rows are informational; disappearing heartbeats remove the
/// corresponding row, and names/avatars follow the same directory as the conversation.
struct WorkingAgentsPopover: View {
    let model: ChannelTypingModel

    @Environment(\.entityNames) private var names
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 52

    private var agents: [String] {
        model.workingAgents(isAgent: names.isAgent).sorted { lhs, rhs in
            let order = names.name(for: lhs).localizedStandardCompare(names.name(for: rhs))
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentGlyphMark(side: 16)
                    .accessibilityHidden(true)
                Text("Working agents")
                    .font(.hive(.headline))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text(agents.count, format: .number)
                    .font(.hive(.subheadline))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(agents, id: \.self) { pubkey in
                        HStack(spacing: 10) {
                            AvatarView(
                                url: names.picture(for: pubkey), seed: pubkey,
                                monogram: names.initials(for: pubkey), size: 32
                            )
                            Text(names.name(for: pubkey))
                                .font(.hive(.body, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: rowHeight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(names.name(for: pubkey)) is working")
                        .transition(.opacity)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(agents.count) * rowHeight, 300))
        }
        .padding(12)
        .frame(width: 280)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: agents)
    }
}
