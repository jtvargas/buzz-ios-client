import SwiftUI

/// Where a jump asks the scroll view to land.
enum ConversationJumpTarget: Equatable {
    /// The newest message: `↓ Latest`, and an own send that would otherwise arrive out
    /// of sight.
    case bottom
    /// One particular message, by id — the *first* arrival the reader has not seen.
    case message(String)
}

/// Which control a conversation is offering above its composer, if any.
enum ConversationJumpControl: Equatable {
    /// Arrivals are waiting behind the frozen tail: `N new messages`.
    case unread(Int)
    /// Nothing new, but the newest message is a long way below: `↓ Latest`.
    case latest
}

/// The jump controls' state, held apart from the rows a conversation renders.
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
    /// Whether the newest message is far enough below to be worth a control of its own.
    /// A wider band than the one that freezes the tail — see ``ConversationScaffold``.
    var isFarFromBottom = false

    /// The one control to show, or none.
    ///
    /// The unread pill wins every tie: it is the specific answer to "what happened while
    /// I was reading", where `↓ Latest` is only the general one. Two floating controls
    /// stacked over a conversation is the state this enum exists to make unrepresentable.
    var control: ConversationJumpControl? {
        if unreadCount > 0 { return .unread(unreadCount) }
        return isFarFromBottom ? .latest : nil
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

/// What floats above the composer while the reader is not at the bottom: `N new
/// messages` when arrivals are waiting behind the freeze, `↓ Latest` when there is
/// simply a long way to fall, and nothing otherwise.
///
/// One view for both, and the only view that reads ``ConversationJumpState`` — which is
/// what keeps a change of count away from the message list.
struct ConversationJumpControls: View {
    let state: ConversationJumpState
    /// Land on the first arrival the reader has not seen.
    let onJumpToNew: () -> Void
    /// Land on the newest message.
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
        // Scoped to which control is showing, never to the list's content: an ambient
        // animation here would animate row insertion in a bottom-anchored list.
        .animation(.smooth(duration: 0.2), value: state.control)
    }
}

/// The "N new messages" affordance: shown when the reader has scrolled up and the
/// conversation is holding new arrivals back, so nothing moves under them until they
/// ask.
///
/// Prominent, because it reports something that happened rather than offering a way to
/// travel — and because it must read as the one control when it replaces ``LatestPill``.
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
        .buttonStyle(.glassProminent)
        .clipShape(.capsule)
        .accessibilityLabel(label)
        .accessibilityHint("Double tap to jump to the first new message")
    }
}

/// The `↓ Latest` affordance: shown when the newest message is far below and nothing is
/// waiting behind the freeze, so the only thing to offer is the way back.
///
/// Plain glass rather than prominent: it is always available while the reader is up in
/// history, and a tinted capsule sitting over a conversation for as long as someone
/// reads it is louder than what it does.
struct LatestPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            JumpPillLabel(text: "Latest")
        }
        .buttonStyle(.glass)
        .clipShape(.capsule)
        .accessibilityLabel("Latest")
        .accessibilityHint("Double tap to jump to the newest message")
    }
}

/// The arrow and the words inside either pill, so the two cannot drift apart in metrics
/// while swapping places in the same spot on screen.
private struct JumpPillLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
                // The count changes under a still pill; without this the whole label
                // reflows by a fraction of a point as the digits change width.
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
    }
}
