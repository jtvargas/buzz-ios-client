import SwiftUI

/// The conversation's heading, as the navigation bar's own leading item: an optional glyph,
/// the name in bold, and one quiet line under it — a channel's member count, or the parent
/// channel a thread hangs off.
///
/// # Why the system bar draws this and the app does not
///
/// The heading has been in three places. It began as a `ToolbarItem` that came out "a little
/// bubble", which was read as a 44pt navigation bar compressing a two-line item; it moved to
/// its own row under an empty system bar, which cost a second band of chrome; and then to a
/// row of capsules the app drew itself with the system bar hidden, which cost the real back
/// button and the interactive drag-back with it.
///
/// The diagnosis behind all three was wrong. A leading toolbar item holds two lines at the
/// default text size perfectly well — what did not fit was the *old* pill, which carried its
/// own `glassEffect` capsule and 6pt of vertical padding inside the item, so it asked the bar
/// for ~46pt where its text needed ~34pt. Handing the capsule back to the bar — a plain
/// `Button` label, glass drawn by iOS 26 — fits, and everything the hand-drawn row had to
/// reproduce (the back button, the material, the metrics, capping type growth in the bar)
/// comes from the system for free and cannot drift out of proportion with itself.
///
/// # The one thing the bar does that has to be defended against
///
/// A toolbar item that does not fit is not truncated — it is **moved into the `…` overflow
/// menu**, so the entire heading disappears rather than the name shortening. A long channel
/// name does exactly that. The defence is to bound the text column so the item's *ideal*
/// width stays inside what the bar has: ``labelWidth``. Measured on the iOS 26 simulator with
/// a 66-character channel name, the item survives up to about a 245pt column on a 402pt-wide
/// iPhone 17 Pro (250 collapses, 240 does not) and past 220 on a 375pt iPhone SE — the
/// reserve is ~155pt and does not scale with the screen, because it is the back button, the
/// bar's margins, the glyph, and the capsule's own padding.
///
/// So the bound is the surface's width less ``reservedChrome`` (180pt — the measured reserve
/// with about 25pt in hand), and it was verified at 375pt, 402pt, and 440pt, and at the
/// largest accessibility size, by screenshot rather than by arithmetic. The bar caps its own
/// type growth, so an accessibility reader gets a legible heading and messages that still
/// scale without limit.
struct ConversationTitleBar: ViewModifier {
    /// The glyph before the name, when the conversation's kind has one to show.
    var symbol: String?
    /// The conversation's name — a channel's, a DM peer's, or the literal `Thread`.
    let title: String
    /// The line beneath it, absent when there is nothing true to put there.
    var subtitle: String?
    /// What tapping the heading does, when it does anything. A thread's heading has no
    /// action, and so is not a control.
    var action: (() -> Void)?
    /// What VoiceOver says the tap does. Ignored without an ``action``.
    var actionHint: String?

    /// The bound on the text column, kept in step with the surface's width so the pill can
    /// be as wide as the bar allows in landscape without risking the overflow menu in
    /// portrait. Seeded at the floor rather than left unbounded: an unbounded first frame is
    /// the one case that *would* collapse into the `…` menu, and a heading that flashes away
    /// and comes back is worse than one that starts narrow and grows.
    @State private var labelWidth: CGFloat = ConversationTitleBar.minimumLabelWidth

    /// What the bar spends on everything that is not the name: the back button, the bar's
    /// leading and trailing margins, the glyph, and the capsule's own padding. Measured, and
    /// deliberately ~25pt above the observed cliff. See the type comment.
    private static let reservedChrome: CGFloat = 180
    /// The narrowest column the heading is ever given — also the seed, so it is a width that
    /// is safe on the narrowest iPhone that runs iOS 26 rather than a placeholder.
    private static let minimumLabelWidth: CGFloat = 190

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                labelWidth = max(Self.minimumLabelWidth, width - Self.reservedChrome)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    heading
                }
                // Keeps the heading a capsule of its own at the leading edge rather than
                // letting the bar centre or stretch it, and is the seam anything added at
                // the trailing edge later would sit the other side of.
                ToolbarSpacer(.flexible, placement: .topBarLeading)
            }
    }

    @ViewBuilder
    private var heading: some View {
        if let action {
            Button(action: action) { label }
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(actionHint ?? "")
        } else {
            // `fixedSize` only on this branch, and it is not cosmetic: a bare label in a
            // toolbar item is squeezed to its minimum — a thread's heading came out as
            // `Th…` over `#gen…` beside a full-width back button — where a `Button`'s label
            // is sized to its ideal. Fixing the horizontal size asks for the ideal width
            // instead, and ``labelWidth`` still bounds it, so a long parent channel name
            // truncates rather than growing the item. Both were screenshotted; neither was
            // reasoned about.
            label
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    /// Deliberately without a `glassEffect` or vertical padding of its own: both belong to
    /// the bar in iOS 26, and adding them here is what made this item too tall to fit the
    /// first time. See the type comment.
    private var label: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    // Sized against both lines rather than either one, which is what makes
                    // it read as the conversation's mark instead of part of the name.
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
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
            // The bound the whole file exists for. `alignment: .leading` so a short name
            // keeps a short capsule instead of sitting in the middle of a wide one — the
            // frame caps the column, it does not claim it.
            .frame(maxWidth: labelWidth, alignment: .leading)
        }
    }

    /// One label for both lines, so VoiceOver reads "general, 5 members" rather than
    /// stopping at the name — the count is the part a screen reader cannot see.
    private var accessibilityLabel: String {
        guard let subtitle else { return title }
        return "\(title), \(subtitle)"
    }

    /// `12 members` for a channel's second line, or nothing while the roster is still
    /// arriving.
    ///
    /// Pure, so the boundaries are tested rather than eyeballed. Zero returns `nil` rather
    /// than `0 members`: the directory read is scoped to `channel_member ∪ agent_directory`,
    /// so a channel whose roster event has not landed yet answers with an empty set — and a
    /// header that stated a channel had no members would report a loading state as a fact.
    static func memberCount(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 member" : "\(count) members"
    }

    /// The glyph for a conversation of `kind`, or `nil` for the kinds whose name stands on
    /// its own.
    ///
    /// Pure and tested rather than branched at each call site, because "which kinds get a
    /// mark" is a product rule and there are three surfaces that could each answer it
    /// differently. A `#` in front of a person's name would be a category error.
    static func symbol(for kind: ConversationIdentity.Kind) -> String? {
        switch kind {
        case .channel: "number"
        case .direct, .agent: nil
        }
    }

    /// The text column a surface `width` points wide gets. Exposed so the rule that keeps
    /// the heading out of the overflow menu is tested rather than only screenshotted.
    static func labelWidth(forSurfaceWidth width: CGFloat) -> CGFloat {
        max(minimumLabelWidth, width - reservedChrome)
    }
}

extension View {
    /// Puts the conversation's heading in the navigation bar's leading slot. See
    /// ``ConversationTitleBar``.
    func conversationTitle(
        symbol: String? = nil,
        title: String,
        subtitle: String? = nil,
        actionHint: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(ConversationTitleBar(
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            action: action,
            actionHint: actionHint
        ))
    }
}
