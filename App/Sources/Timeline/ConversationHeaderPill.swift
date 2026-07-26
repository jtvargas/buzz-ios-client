import SwiftUI

/// The conversation's name in a Liquid Glass capsule: an optional leading glyph, the name
/// in bold, and one quiet line under it — a channel's member count, or the parent channel a
/// thread hangs off.
///
/// # Why two lines fit here when they did not in a navigation bar
///
/// This pill was a `ToolbarItem(placement: .topBarLeading)` and produced "a little bubble,
/// not an actual header" on device: a navigation bar is 44pt, a two-line pill is taller than
/// that, and the bar resolves the conflict by compressing the *item* — compression shrinks
/// the item, it does not make the text inside it truncate. The pill now sits in
/// ``ConversationHeaderRow``, a row this app draws itself, so there is no 44pt ceiling to
/// fit and nothing to compress it. That is also what the reference client does: its header
/// is three floating capsules over the conversation, not a system bar.
///
/// # Why the type is small anyway
///
/// The reference's pill is about 41pt tall with two lines of text in it, and it gets there
/// by using small type rather than a tall bar: the name is a `.subheadline` and the line
/// under it a `.caption2`. Matching that keeps the header proportionate to the conversation
/// at the default text size — and because the row is ours, nothing here is clamped, so a
/// reader at an accessibility size gets a taller header rather than a truncated one.
///
/// # Why there is no fallback branch, and no arrow
///
/// The deployment target is iOS 26, where `glassEffect` is unconditionally available; an
/// `if #available` branch here would be code that can never run. And a chevron promises a
/// menu: the channel header opens a details *sheet* and the thread header does nothing at
/// all, so neither earns one. The channel's tap survives without it — the caller wraps the
/// pill in a button whose pressed dim says it is a control.
struct ConversationHeaderPill: View {
    /// The glyph before the name, when the conversation's kind has one to show. `#` marks a
    /// channel; a direct message and a thread have none, which is itself the distinction —
    /// a `#` in front of a person's name would be a category error.
    var symbol: String?
    /// The conversation's name — a channel's, a DM peer's, or the literal `Thread`.
    let title: String
    /// The line beneath it, absent when there is nothing true to put there (a roster
    /// that has not arrived yet, or a peer with no NIP-05 identifier).
    var subtitle: String?

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    // Sized against both lines rather than against either one, which is
                    // what makes it read as the pill's mark instead of as part of the name.
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    // A 200-character channel name is somebody else's choice. Truncating is
                    // not clipping: the leading characters — the part that identifies the
                    // conversation — stay readable, and the row gives them most of the
                    // screen's width rather than the handful a navigation bar left.
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // No `maxHeight`: this pill is what *sets* the row's height, and the capsules either
        // side take theirs from it. Expanding here instead made the header fill the height the
        // top bar was willing to propose — a 100pt lozenge.
        .glassEffect(.regular, in: .capsule)
        // No `maxWidth`: the capsule is sized to its content and stops growing at the width
        // the row gives it, so a short name keeps a short pill instead of sitting in an
        // over-wide one.
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

    /// The glyph for a conversation of `kind`, or `nil` for the kinds whose name stands on
    /// its own.
    ///
    /// Pure and tested rather than branched at each call site, because "which kinds get a
    /// mark" is a product rule and there are three surfaces that could each answer it
    /// differently.
    static func symbol(for kind: ConversationIdentity.Kind) -> String? {
        switch kind {
        case .channel: "number"
        case .direct, .agent: nil
        }
    }
}
