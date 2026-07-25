import BuzzKit
import SwiftUI

/// The quick-reaction palette offered in a message's long-press menu.
enum ReactionPalette {
    static let common = ["👍", "❤️", "😂", "🎉", "🙏", "🔥"]
}

/// The reaction chips under a message: one capsule per emoji with its reactor
/// count, the local identity's own reaction tinted and outlined. Tapping a chip
/// toggles that reaction (add, or withdraw an own one).
struct ReactionChipsView: View {
    let groups: [ReactionGroup]
    let onTap: (ReactionGroup) -> Void

    var body: some View {
        if !groups.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(groups) { group in
                    ReactionChip(group: group) { onTap(group) }
                }
            }
            .animation(.default, value: groups)
        }
    }
}

/// One reaction chip. Highlighted when the local identity is among the reactors.
private struct ReactionChip: View {
    let group: ReactionGroup
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(group.emoji)
                if group.count > 1 {
                    Text("\(group.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    group.reactedBySelf ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    group.reactedBySelf ? Color.accentColor.opacity(0.6) : .clear,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(group.reactedBySelf ? [.isSelected] : [])
        .accessibilityHint("Double tap to toggle your reaction")
    }

    private var accessibilityLabel: String {
        let base = "\(group.emoji), \(group.count)"
        return group.reactedBySelf ? "\(base), you reacted" : base
    }
}

/// A minimal wrapping layout: places subviews left to right, wrapping to a new line
/// when the next would overflow the proposed width. Reaction chips are few, so the
/// two unspecified-size passes are cheap; a wrapping row keeps them readable when a
/// message collects many distinct emoji.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + size.width > maxWidth {
                cursorX = 0
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            cursorX += size.width + spacing
            widest = max(widest, cursorX - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth == .infinity ? widest : min(maxWidth, widest)
        return CGSize(width: width, height: cursorY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: cursorX, y: cursorY), anchor: .topLeading, proposal: ProposedViewSize(size))
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
