import SwiftUI

/// Where a jump asks the scroll view to land.
enum ConversationJumpTarget: Equatable {
    /// The newest message: an own send that would otherwise arrive out of sight, and the
    /// fallback for a press that raced the reader back to the bottom.
    case bottom
    /// One particular message, by id — the *first* arrival the reader has not seen.
    case message(String)
}

/// Which control a conversation is offering above its composer, if any.
///
/// One case since `↓ Latest` was withdrawn, and still an enum rather than the bare `Int?`
/// it is now isomorphic to: everything downstream reads a named answer, and a second
/// affordance would be a case here instead of a re-typing of `control`, the animation's
/// `value:`, and the tests.
enum ConversationJumpControl: Equatable {
    /// Arrivals are waiting behind the frozen tail: `N new messages`.
    case unread(Int)
    /// The reader is far enough up that the way back is worth offering, and nothing is
    /// waiting behind the freeze: `↓ Latest`.
    ///
    /// Outranked by ``unread`` whenever both apply — the owner's call, and the right one:
    /// a pill that knows something you do not beats one that only offers a journey.
    case latest
}

/// The jump control's state, held apart from the rows a conversation renders.
///
/// # Why its own object rather than two more properties on the timeline model
///
/// Observation invalidates a view per *property that view read*. A count living beside
/// `items` on the model is a count read in the same `body` as the message list — so
/// every arrival while the reader is scrolled up, which is exactly when this state
/// changes, re-evaluated the whole timeline to move a number inside a pill. Held here
/// and read only by ``ConversationJumpControls``, a change reaches the pill and stops.
///
/// The models keep the freeze itself: this is what the freeze *shows*, not where it is
/// decided.
@MainActor
@Observable
final class ConversationJumpState {
    /// How many arrivals the frozen tail is holding back — `0` whenever nothing is held.
    private(set) var unreadCount = 0
    /// The oldest of those arrivals: where the pill lands the reader, rather than at the
    /// bottom past everything it just announced.
    private(set) var firstUnreadID: String?

    /// Whether the reader is far enough from the newest message for the way back to be
    /// worth offering. Written by the scaffold, which owns the distance.
    private(set) var isFarFromBottom = false

    /// The one control to show, or none.
    ///
    /// **Unread always wins.** The owner's ruling, and it matches what the two pills are:
    /// one reports that something happened while you were reading, the other offers a
    /// journey you could already make by scrolling. When both apply, the one carrying news
    /// is the one to show.
    ///
    /// # Why distance is trustworthy here again
    ///
    /// `↓ Latest` was withdrawn partly because its half-viewport band was arithmetic over
    /// `contentSize.height`, which a `LazyVStack` estimates — one more unreliable number in
    /// a scroll engine already full of them. **The inversion changed that.** In the flipped
    /// list the newest message sits at the origin, so distance-from-newest is
    /// `visibleRect.minY`: an offset from zero, not a difference between two estimates. It
    /// is the same exact quantity the freeze's own two bands already read.
    var control: ConversationJumpControl? {
        if unreadCount > 0 { return .unread(unreadCount) }
        return isFarFromBottom ? .latest : nil
    }

    /// Records how far the reader is from the newest message.
    ///
    /// Equal values are not written back, for ``hold(count:firstID:)``'s reason: this is
    /// fed by a band crossing, but a crossing can be reported repeatedly while a reader
    /// hovers on the edge of it, and each write would invalidate the pill.
    func setFarFromBottom(_ isFar: Bool) {
        if isFarFromBottom != isFar { isFarFromBottom = isFar }
    }

    /// Records what the tail is holding back: how many, and the oldest one's id.
    ///
    /// Counted by the caller rather than handed the rows, so nothing about what a
    /// message *is* reaches this state — it is what the pill draws and where the pill
    /// goes, and it stays testable and hostable without a store behind it.
    ///
    /// Equal values are not written back. An `@Observable` property notifies on every
    /// set, equal or not, so a rebuild that changed nothing — every commit the store
    /// raises for another channel, say — would still invalidate the pill.
    func hold(count: Int, firstID: String?) {
        if unreadCount != count { unreadCount = count }
        if firstUnreadID != firstID { firstUnreadID = firstID }
    }
}

/// What floats above the composer while arrivals are waiting behind the freeze, and
/// nothing at all otherwise.
///
/// The only view that reads ``ConversationJumpState``, which is what keeps a change of
/// count away from the message list.
struct ConversationJumpControls: View {
    let state: ConversationJumpState
    /// Land on the first arrival the reader has not seen.
    let onJumpToNew: () -> Void
    /// Land on the newest message. Already exists for an own send from deep in history —
    /// this control is a second caller, not new behaviour.
    let onJumpToLatest: () -> Void

    var body: some View {
        Group {
            switch state.control {
            case let .unread(count):
                NewMessagesPill(count: count, action: onJumpToNew)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .latest:
                LatestPill(action: onJumpToLatest)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case nil:
                EmptyView()
            }
        }
        // Scoped to whether the control is showing, never to the list's content: an
        // ambient animation here would animate row insertion in a bottom-anchored list.
        .animation(.smooth(duration: 0.2), value: state.control)
    }
}

/// The `N new messages` affordance: shown when the reader has scrolled up and the
/// conversation is holding new arrivals back, so nothing moves under them until they ask.
///
/// # Why plain glass, and why smaller
///
/// It was `.glassProminent`, which was an argument about rank: it had to read as *the* one
/// control in the spot `↓ Latest` otherwise occupied. Nothing shares the spot now, so the
/// tint buys no clarity and spends the surface's only accent on something a reader is free
/// to ignore — the amber capsule was the loudest thing on screen over a conversation it was
/// merely annotating.
///
/// The size comes from Slack's jump pill, the reference the owner supplied: a compact
/// capsule of caption-sized text rather than a button. `.controlSize(.small)` is part of
/// that and not decoration — a button style's own insets sit *outside* the label, so the
/// padding and the height floor below cannot reach them, and `.small` is the only lever
/// that does. Same pairing as ``ThreadActivityRow``'s reply button.
///
/// Unmeasured, deliberately: Liquid Glass rendering is on the owner's device pass rather
/// than in a test, as ADR-0004 records. If it still reads large, `.controlSize` is the line
/// to move.
struct NewMessagesPill: View {
    let count: Int
    let action: () -> Void

    /// What the pill says, and what a screen reader hears. Internal so the plural rule
    /// is tested where it is written rather than through a hosted view.
    static func label(count: Int) -> String {
        count == 1 ? "1 new message" : "\(count) new messages"
    }

    var body: some View {
        let label = Self.label(count: count)
        return Button(action: action) {
            JumpPillLabel(text: label)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .clipShape(.capsule)
        .accessibilityLabel(label)
        .accessibilityHint("Double tap to jump to the first new message")
    }
}

/// The `↓ Latest` affordance: the way back, offered once the reader is far enough up that
/// scrolling there by hand is a journey.
///
/// Shown only when nothing is waiting behind the freeze — ``ConversationJumpState/control``
/// gives the unread pill the slot whenever both apply.
struct LatestPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            JumpPillLabel(text: "Latest")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .clipShape(.capsule)
        .accessibilityLabel("Latest")
        .accessibilityHint("Double tap to jump to the newest message")
    }
}

/// The arrow and the words inside either pill.
///
/// Shared again, deliberately. It was inlined into ``NewMessagesPill`` when `↓ Latest` was
/// withdrawn — with one pill a shared type was a second place to look for one set of
/// numbers. With two pills swapping places in the same spot on screen, it is the thing that
/// stops them drifting apart by a point and making the swap visible as a jolt.
private struct JumpPillLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down")
                .font(.hiveSymbol(.caption2, weight: .semibold))
            Text(text)
                .font(.hive(.caption2, weight: .semibold))
                // The count changes under a still pill; without this the whole label
                // reflows by a fraction of a point as the digits change width.
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        // A floor rather than a height. The label keeps its intrinsic size wherever
        // that is taller, so an accessibility text size grows the capsule instead of
        // being clipped inside it — which a `.frame(height:)` here would do.
        .frame(minHeight: 28)
    }
}
