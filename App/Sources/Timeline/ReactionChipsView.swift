import BuzzKit
import SwiftUI

/// The quick-reaction palette offered in a message's long-press menu.
enum ReactionPalette {
    static let common = ["👍", "❤️", "😂", "🎉", "🙏", "🔥"]
}

/// The reaction row under a message: the surviving reactions as Slack-style capsule
/// pills — emoji and count, hairline border, subtle fill, the local identity's own
/// reaction tinted — followed by a compact "add reaction" pill that opens the quick
/// palette. Tapping a chip toggles that reaction (add, or withdraw an own one);
/// chips scale-and-fade in and out so a reaction never snaps the layout.
struct ReactionChipsView: View {
    private static let chipHeight: CGFloat = 28

    let groups: [ReactionGroup]
    /// Toggle an existing chip: add that emoji, or withdraw an own reaction.
    let onTap: (ReactionGroup) -> Void
    /// Add a fresh reaction with the chosen emoji from the add-reaction palette.
    let onReact: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(groups) { group in
                ReactionChip(group: group, height: Self.chipHeight) { onTap(group) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            AddReactionButton(height: Self.chipHeight, onReact: onReact)
        }
        // A gentle spring on the chip set: additions and withdrawals ease in place
        // rather than jumping, and the add pill slides as chips reflow around it.
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: groups)
    }
}

/// One reaction chip. Highlighted when the local identity is among the reactors.
private struct ReactionChip: View {
    let group: ReactionGroup
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(group.emoji)
                Text("\(group.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(
                Capsule().fill(
                    group.reactedBySelf ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    group.reactedBySelf ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25),
                    lineWidth: 1
                )
            )
            .contentShape(.capsule)
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

/// The compact "add reaction" pill: a capsule the size of a chip, a smiley with a
/// small plus, opening the quick-reaction palette on tap. Sits at the end of the
/// reaction row so a message can always be reacted to without the long-press menu.
private struct AddReactionButton: View {
    let height: CGFloat
    let onReact: (String) -> Void

    var body: some View {
        Menu {
            ControlGroup {
                ForEach(ReactionPalette.common, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji) }
                }
            }
        } label: {
            HStack(spacing: 1) {
                Image(systemName: "face.smiling")
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
            .contentShape(.capsule)
        }
        .accessibilityLabel("Add reaction")
        .accessibilityHint("Double tap to choose an emoji")
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
