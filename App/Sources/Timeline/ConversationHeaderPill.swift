import SwiftUI

/// The heading above a conversation: a left-aligned Liquid Glass capsule carrying a
/// title and, under it, one quiet line of context — a channel's member count, or the
/// parent channel a thread hangs off.
///
/// # Why it is a leading toolbar item and not the navigation title
///
/// `.principal` centres its content and offers no way to pull it to the leading edge,
/// so §4's "left-aligned" cannot be expressed there. A `.topBarLeading` item lands
/// immediately after the back chevron, which is where a conversation's name sits in
/// every client this is measured against.
///
/// # Why there is no fallback branch
///
/// The deployment target is iOS 26, where `glassEffect` is unconditionally available.
/// A `if #available` branch with a translucent `Material` behind it would be code that
/// can never run, and the one thing worse than an untested fallback is an unreachable
/// one. If the floor ever drops below 26 this is the file that needs the branch.
///
/// # Why the arrow is gone
///
/// A chevron promises a menu. The channel header opens a details *sheet* and the thread
/// header does nothing at all, so neither earns one — §4's rule. The channel's tap
/// survives without it: the pill is a control, and the pressed dim says so.
struct ConversationHeaderPill: View {
    /// The conversation's name — a channel's, a DM peer's, or the literal `Thread`.
    let title: String
    /// The line beneath it, absent when there is nothing true to put there (a roster
    /// that has not arrived yet, or a peer with no NIP-05 identifier).
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                // A 200-character channel name is somebody else's choice. Truncating
                // is not clipping: the leading characters — the part that identifies
                // the conversation — stay readable at any width, and the pill keeps
                // its shape instead of growing until the bar drops it.
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
        // No explicit width cap: a toolbar item is sized to its content and compressed
        // when the bar runs out of room, and compression is what makes the `lineLimit`
        // above truncate. Pinning a `maxWidth` here instead left short names sitting in
        // an over-wide capsule.
        .padding(.horizontal, 12)
        // Four, not the eight the horizontal inset would suggest: a `.headline` line
        // (~22pt) over a `.caption2` one (~13pt) is already 35pt, and a navigation bar
        // is 44 — anything more generous and the pill is taller than the bar holding it.
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
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
