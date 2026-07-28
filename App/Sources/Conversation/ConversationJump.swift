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

    /// The one control to show, or none.
    ///
    /// Distance no longer reaches this. `↓ Latest` was offered on a half-viewport band and
    /// answered a question the scroll view already answers — so it sat over the conversation
    /// for as long as someone read history, which is the whole time it had nothing to say.
    /// What is left appears only because something arrived, and leaves when it is read.
    ///
    /// That is also why the scaffold no longer projects a second distance band: this was its
    /// only reader.
    var control: ConversationJumpControl? {
        unreadCount > 0 ? .unread(unreadCount) : nil
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

    var body: some View {
        Group {
            if case let .unread(count) = state.control {
                NewMessagesPill(count: count, action: onJumpToNew)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
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
            // Inlined from a `JumpPillLabel` that existed so this pill and `↓ Latest` could
            // not drift apart in metrics. With one pill the shared type was a second place
            // to look for one set of numbers.
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.hiveSymbol(.caption2, weight: .semibold))
                Text(label)
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
        .buttonStyle(.glass)
        .controlSize(.small)
        .clipShape(.capsule)
        .accessibilityLabel(label)
        .accessibilityHint("Double tap to jump to the first new message")
    }
}
