import SwiftUI

/// The heading above a conversation: a left-aligned Liquid Glass capsule carrying a
/// title and, under it, one quiet line of context — a channel's member count, or the
/// parent channel a thread hangs off.
///
/// # Why it is not a toolbar item
///
/// It was a `ToolbarItem(placement: .topBarLeading)`, and on a device that produced "a
/// little bubble, not an actual header": a navigation bar sizes an item to its ideal
/// width and then *compresses* it when the bar wants the space back, and a two-line pill
/// has nowhere to go — so the title was squeezed to a few characters rather than
/// truncated at a readable width. The assumption that compression would let
/// `lineLimit(1)` truncate was carried as an unverified note; it does not.
///
/// So the pill lives in the conversation's own chrome instead, attached by
/// ``ConversationScaffold`` to the top safe area, where it has the whole width of the
/// surface. The navigation bar keeps only what it is good at — the back chevron and the
/// swipe-back gesture it owns.
///
/// # What the width buys
///
/// Both lines, at every text size. The old pill dropped its subtitle above `.large` and
/// clamped its remaining line at `.accessibility1`, because two lines of Dynamic Type do
/// not fit a 44pt navigation bar. Out of the bar there is no 44pt ceiling, and the reason
/// to clamp went with it — measured in the harness, this pill is 46pt at `.large`, 61 at
/// `.xxxLarge`, 70 at AX1, 95 at AX3 and 124 at AX5, which is smaller than a single
/// two-line message row at the same size. Chrome that stays under one row's height is
/// proportionate to what the reader asked for, so nothing here is clamped and the member
/// count survives for the readers most likely to want it.
///
/// A pill this wide is also what makes `lineLimit(1)` honest: a long channel name is
/// truncated at the trailing end with its identifying leading characters intact — about
/// forty of them at `.large`, against the handful the navigation bar left room for.
///
/// # Why there is no fallback branch, and no arrow
///
/// The deployment target is iOS 26, where `glassEffect` is unconditionally available; an
/// `if #available` branch here would be code that can never run. And a chevron promises a
/// menu: the channel header opens a details *sheet* and the thread header does nothing at
/// all, so neither earns one. The channel's tap survives without it — the caller wraps
/// the pill in a button whose pressed dim says it is a control.
struct ConversationHeaderPill: View {
    /// The conversation's name — a channel's, a DM peer's, or the literal `Thread`.
    let title: String
    /// The line beneath it, absent when there is nothing true to put there (a roster
    /// that has not arrived yet, or a peer with no NIP-05 identifier).
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                // A 200-character channel name is somebody else's choice. Truncating is
                // not clipping: the leading characters — the part that identifies the
                // conversation — stay readable, and at this width that is most of the
                // name rather than the handful a navigation bar left room for.
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Wider than it is tall, because the shape is a capsule: with the horizontal
        // inset any narrower, a two-line title sits inside the end caps' curve.
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        // No `maxWidth`: the capsule is sized to its content and stops growing at the
        // width the header row gives it, so a short name keeps a short pill instead of
        // sitting in an over-wide one.
    }

    /// `12 members` for a channel's second line, or nothing while the roster is still
    /// arriving.
    ///
    /// Pure, so the boundaries are tested rather than eyeballed. Zero returns `nil`
    /// rather than `0 members`: the directory read is scoped to
    /// `channel_member ∪ agent_directory`, so a channel whose roster event has not
    /// landed yet answers with an empty set — and a header that stated a channel had no
    /// members would be reporting a loading state as a fact.
    static func memberCount(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 member" : "\(count) members"
    }
}
