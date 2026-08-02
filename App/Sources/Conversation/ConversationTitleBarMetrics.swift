import SwiftUI

/// The heading's arithmetic: what marks a conversation, and how wide its name is allowed to
/// be before the navigation bar takes the whole item away.
///
/// Separate from the view because it is the part with tests. **A toolbar item that does not
/// fit is not truncated — it is moved into the `…` overflow menu**, so the heading disappears
/// rather than the name shortening, and the only defence is to keep the item's *ideal* width
/// inside what the bar has. Every number here was measured on a simulator, not derived.
extension ConversationTitleBar {
    /// What the bar spends on everything that is not the name when the mark is a glyph: the
    /// back button, the bar's leading and trailing margins, the glyph, and the capsule's own
    /// padding. Measured, and deliberately ~25pt above the observed cliff.
    private static let glyphChrome: CGFloat = 180
    /// The narrowest column the heading is ever given — also the seed, so it is a width that
    /// is safe on the narrowest iPhone that runs iOS 26 rather than a placeholder.
    ///
    /// On a phone this floor now *binds*: 440 − 180 − 96 is under it, so once both trailing
    /// buttons are charged every iPhone in portrait hands the name exactly 190 and the
    /// arithmetic below stops being able to answer the question it exists for. What answers
    /// it instead is `ConversationTitleBarTests`, which opens the real bar with a
    /// 76-character name and reads whether the heading survived.
    static let minimumLabelWidth: CGFloat = 190
    /// What one trailing glass button takes out of the bar: the 44pt tap target every
    /// toolbar control gets. Charged against the name rather than absorbed, for the reason
    /// the face is — see ``reservedChrome(for:)``.
    private static let trailingActionWidth: CGFloat = 44
    /// The seam between two trailing capsules — the `ToolbarSpacer` that keeps them from
    /// fusing into one piece of glass.
    private static let trailingSeamWidth: CGFloat = 8

    /// The mark for a conversation: a `#` for a channel, the peer's own face for a direct
    /// message, and how many people are in it for a group one.
    ///
    /// Pure and tested rather than branched at each call site, because "what marks a
    /// conversation" is a product rule and there are three surfaces that could each answer it
    /// differently. A `#` in front of a person's name would be a category error, and so would
    /// a face in front of a room's name — or in front of a list of four of them.
    static func mark(for conversation: ConversationIdentity) -> Mark {
        switch conversation.kind {
        case .channel:
            .symbol("number")
        case .group:
            .count(conversation.memberCount)
        case .direct, .agent:
            .avatar(
                url: conversation.picture,
                seed: conversation.avatarSeed,
                initials: conversation.initials
            )
        }
    }

    /// The text column a surface `width` points wide gets, for a heading carrying `mark`
    /// beside `trailingActions` buttons. Exposed so the rule that keeps the heading out of
    /// the overflow menu is tested rather than only screenshotted.
    static func labelWidth(
        forSurfaceWidth width: CGFloat,
        mark: Mark,
        trailingActions: Int = 0
    ) -> CGFloat {
        max(minimumLabelWidth, width - reservedChrome(for: mark) - trailingReserve(trailingActions))
    }

    /// What `count` trailing buttons and the seams between them take out of the bar.
    ///
    /// Zero for a surface with none, which is every surface this bar had before there was
    /// anything to put at the trailing edge — so the measured 402pt/245pt cliff the reserve
    /// was fitted to still describes those screens exactly.
    static func trailingReserve(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * trailingActionWidth + CGFloat(count - 1) * trailingSeamWidth
    }

    /// What the bar spends on everything that is not the name.
    ///
    /// A face is wider than a glyph and costs the name that difference — charged here rather
    /// than absorbed, because absorbing it is how a long agent name would take the whole
    /// heading into the `…` menu on a narrow screen.
    static func reservedChrome(for mark: Mark) -> CGFloat {
        switch mark {
        case .none, .symbol, .count:
            glyphChrome
        case .avatar, .community:
            // The face or community mark, less the glyph it stands in for: a `#` at `.title3`
            // measures ~14pt wide on the iOS 26 simulator.
            glyphChrome + (avatarSize - 14)
        }
    }
}
