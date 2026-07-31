import BuzzKit
import SwiftUI

/// The reactions offered without opening the full picker, in the owner's order.
///
/// One list, read by both places that offer a shortcut — the actions sheet a long press
/// opens, and the add-reaction pill at the end of a message's chips — so the five a reader
/// learns in one are the five they find in the other.
///
/// 👍🏻 carries its skin tone deliberately. A reaction groups on the exact emoji string, so
/// this palette and the chip it raises have to be the same characters or a message collects
/// two thumbs that do not add up.
enum ReactionPalette {
    static let common = ["🤔", "👀", "👍🏻", "❤️", "✅"]

    /// What choosing `emoji` on a message already carrying `groups` means.
    ///
    /// The palette and the picker both go through this rather than each reaching for
    /// `react`, and the reason is the second press: an emoji the reader has already sent is
    /// theirs to *withdraw*, and calling `react` again would queue a second identical kind-7
    /// that the relay is entitled to keep. The chips under a message have always toggled;
    /// this is the same rule, applied where the emoji is chosen from a list instead of
    /// pressed as an existing chip.
    static func choice(for emoji: String, in groups: [ReactionGroup]) -> Choice {
        guard let group = groups.first(where: { $0.emoji == emoji }) else { return .add(emoji) }
        return .toggle(group)
    }

    /// The two things a chosen emoji can mean.
    enum Choice: Equatable {
        /// Nobody has sent this emoji on this message yet.
        case add(String)
        /// It is already here — `toggleReaction` adds the reader to it, or takes them off.
        case toggle(ReactionGroup)
    }
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
    /// Raised as the palette is opened, before any emoji has been chosen — the hook an
    /// enclosing row uses to claim the tap that opened it. Defaults to nothing, for a
    /// surface with no competing gesture to arbitrate against.
    var onOpenPalette: () -> Void = {}

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(groups) { group in
                ReactionChip(group: group, height: Self.chipHeight) { onTap(group) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            AddReactionButton(height: Self.chipHeight, onReact: onReact, onOpen: onOpenPalette)
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
        Button {
            // At the chip, which is where the finger is. What the tap turns into — a fresh
            // reaction or an own one withdrawn — is decided several hops away, and both are
            // the same event to a reader: the reaction under this message changed.
            HiveHaptics.play(.reaction)
            action()
        } label: {
            HStack(spacing: 4) {
                Text(group.emoji)
                Text("\(group.count)")
                    .font(.hive(.caption2, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(
                Capsule().fill(
                    group.reactedBySelf ? Color.hiveAccent.opacity(0.18) : Color.secondary.opacity(0.12)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    group.reactedBySelf ? Color.hiveAccent.opacity(0.6) : Color.secondary.opacity(0.25),
                    lineWidth: 1
                )
            )
            .contentShape(.capsule)
        }
        // A chip is the one control here a reader presses repeatedly, and until now a press
        // answered with nothing at all. In a capsule, because that is the outline it draws:
        // a rounded-rectangle wash under a pill shows at both of its ends.
        .buttonStyle(.hivePress(.control, in: .capsule))
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
/// reaction row so a message can always be reacted to without opening the actions sheet.
///
/// # Why the tap is observed with a gesture
///
/// A `Menu` exposes no "about to open" callback: the only closure it offers is each item's
/// action, which runs after an emoji has been chosen and never at all if the palette is
/// dismissed. So the tap that opens the palette is invisible to the enclosing row, which
/// reads that same tap as "open the thread" — the palette opened *and* the thread pushed.
///
/// `simultaneousGesture` is the fix because it adds a recogniser alongside the ones the
/// menu defines rather than in front of them: the tap is still delivered to the menu, and
/// `onOpen` runs on the same touch-up the row's own tap gesture completes on, which is
/// precisely the moment the row is deciding. A `TapGesture` and not a zero-distance drag,
/// because a drag recogniser here would compete with the message list's scrolling.
private struct AddReactionButton: View {
    let height: CGFloat
    let onReact: (String) -> Void
    /// Raised as the palette opens, so an enclosing row can claim this tap.
    let onOpen: () -> Void

    var body: some View {
        Menu {
            ControlGroup {
                ForEach(ReactionPalette.common, id: \.self) { emoji in
                    Button(emoji) {
                        HiveHaptics.play(.reaction)
                        onReact(emoji)
                    }
                }
            }
        } label: {
            HStack(spacing: 1) {
                Image(systemName: "face.smiling")
                Image(systemName: "plus")
                    .font(.hiveSymbol(fixedSize: 8, weight: .bold))
            }
            .font(.hiveSymbol(.caption))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
            .contentShape(.capsule)
        }
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
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
