import SwiftUI

/// The one place the entity tokens turn into pixels — Slack-mobile *tinted text*,
/// not a filled pill: accent-coloured, medium-weight inline text that stays a single
/// selectable, Dynamic-Type-correct `Text` per block. Self-mentions get a stronger
/// treatment (bolder). The AST carries only identity; this maps it to colour + weight
/// at draw time, so the styling lives in exactly one tweakable spot.
enum RichTextStyle {
    /// The token tint — the app's global accent (honey amber), the same colour that
    /// tints buttons and the unread pill.
    static let tint = Color.accentColor

    /// A plain (non-self) mention: medium weight, distinct from body text and links.
    static let mentionWeight: Font.Weight = .medium
    /// A self-mention: bolder, so a message *to you* reads at a glance.
    static let selfMentionWeight: Font.Weight = .semibold
    /// A `#`-channel reference: medium, matching a plain mention.
    static let channelWeight: Font.Weight = .medium

    /// The horizontal indent applied per nested-list level.
    static let nestedIndent: CGFloat = 16

    /// Vertical spacing between a message's blocks.
    static let blockSpacing: CGFloat = 6

    /// Produces the presentation `AttributedString` for one inline: every resolved
    /// mention/channel run gains the accent colour and the right weight *relative to
    /// `base`* (so it still scales with Dynamic Type), while plain runs inherit the
    /// view's environment font and colour untouched.
    ///
    /// Ranges are read from the input before any mutation and applied on a copy;
    /// attribute writes preserve indices, so every range stays valid.
    static func styled(_ attributed: AttributedString, base: Font) -> AttributedString {
        var output = attributed
        let runs = output.runs.map { ($0.range, $0.mention, $0.channel) }
        for (range, mention, channel) in runs {
            if let mention {
                output[range].foregroundColor = tint
                output[range].font = base.weight(mention.isSelf ? selfMentionWeight : mentionWeight)
            } else if channel != nil {
                output[range].foregroundColor = tint
                output[range].font = base.weight(channelWeight)
            }
        }
        return output
    }
}
