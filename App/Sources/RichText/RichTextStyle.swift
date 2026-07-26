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
    /// A web/email/internal link: medium, matching a plain mention.
    static let linkWeight: Font.Weight = .medium

    /// The horizontal indent applied per nested-list level.
    static let nestedIndent: CGFloat = 16

    /// Vertical spacing between a message's blocks.
    static let blockSpacing: CGFloat = 6

    /// How far the pill is grown beyond the glyphs it sits behind. Horizontal is the
    /// "comfortable padding"; vertical is deliberately small, because a taller pill
    /// starts colliding with the line above in a wrapped paragraph.
    static let pillPadding = CGSize(width: 4, height: 1.5)

    /// The pill's corner radius, on the small side so a one-word mention does not
    /// read as a capsule button.
    static let pillCornerRadius: CGFloat = 6

    /// The pill fill: the accent at low alpha, lifted in dark mode where the same
    /// alpha over a near-black background is close to invisible. Alpha rather than a
    /// second colour asset so it tints with whatever accent the app is built with.
    static func pillFill(dark: Bool, pressed: Bool) -> Color {
        let alpha: Double = switch (dark, pressed) {
        case (false, false): 0.13
        case (false, true): 0.30
        case (true, false): 0.22
        case (true, true): 0.42
        }
        return tint.opacity(alpha)
    }

    /// Produces the presentation `AttributedString` for one inline: every resolved
    /// mention/channel run gains the accent colour and the right weight *relative to
    /// `base`* (so it still scales with Dynamic Type), while plain runs inherit the
    /// view's environment font and colour untouched.
    ///
    /// `interactive` is what separates a message being read from a one-line preview
    /// of one. When it is set, an entity run also gains the `link` that carries its
    /// target (see ``RichTextTarget``) — the only attribute a SwiftUI `Text` will let
    /// a reader press. When it is not, every link is *stripped* instead: a snippet in
    /// the sidebar sits inside a row that is itself a control, and a tappable range
    /// inside it would be a second, competing target for the same tap.
    ///
    /// Ranges are read from the input before any mutation and applied on a copy;
    /// attribute writes preserve indices, so every range stays valid.
    static func styled(
        _ attributed: AttributedString,
        base: Font,
        interactive: Bool = false
    ) -> AttributedString {
        var output = attributed
        let runs = output.runs.map { ($0.range, $0.mention, $0.channel, $0.link) }
        for (range, mention, channel, link) in runs {
            if let mention {
                output[range].foregroundColor = tint
                output[range].font = base.weight(mention.isSelf ? selfMentionWeight : mentionWeight)
                output[range].link = interactive
                    ? mention.pubkey.flatMap { RichTextTarget.user(pubkey: $0).url }
                    : nil
            } else if let channel {
                output[range].foregroundColor = tint
                output[range].font = base.weight(channelWeight)
                output[range].link = interactive
                    ? channel.channelID.flatMap { RichTextTarget.channel(id: $0).url }
                    : nil
            } else if link != nil {
                // A web, email, or internal link: the same treatment a mention gets,
                // so interactive text reads as one visual language rather than two.
                output[range].foregroundColor = tint
                output[range].font = base.weight(linkWeight)
                if !interactive { output[range].link = nil }
            }
        }
        return output
    }
}
